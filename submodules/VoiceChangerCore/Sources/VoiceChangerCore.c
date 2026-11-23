#include <VoiceChangerCore/VoiceChangerCore.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

// The effect shared by every processor. Relaxed atomics are enough: a processor only
// needs to see the new value eventually, within one audio buffer.
static int32_t gCurrentEffect = VCEffectNone;

void VCSetCurrentEffect(int32_t effect) {
    if (effect < 0 || effect >= VCEffectCount) {
        effect = VCEffectNone;
    }
    __atomic_store_n(&gCurrentEffect, effect, __ATOMIC_RELAXED);
}

int32_t VCGetCurrentEffect(void) {
    return __atomic_load_n(&gCurrentEffect, __ATOMIC_RELAXED);
}

// Buffer sizes cover sample rates up to 96 kHz, so nothing is ever allocated on the audio thread.
#define VC_PITCH_BUFFER_SIZE 16384
#define VC_PITCH_BUFFER_MASK (VC_PITCH_BUFFER_SIZE - 1)
#define VC_DELAY_BUFFER_SIZE 65536
#define VC_DELAY_BUFFER_MASK (VC_DELAY_BUFFER_SIZE - 1)
#define VC_MAX_SAMPLE_RATE 96000.0
#define VC_TWO_PI 6.28318530717958647692

typedef struct {
    float b0, b1, b2, a1, a2;
    float z1, z2;
} VCBiquad;

typedef struct {
    double ratio;
    double vibratoDepth;
    double vibratoRate;
    double ringFrequency;
    float ringMix;
    double delaySeconds;
    float delayFeedback;
    float delayMix;
    float drive;
    double highpassHz;
    double lowpassHz;
    double clarityDb;
    float outputGain;
} VCEffectParams;

struct VCProcessor {
    double sampleRate;
    int32_t effect;
    VCEffectParams params;

    float *pitchBuffer;
    uint32_t pitchWrite;
    double pitchPhase;
    double windowSamples;

    float *delayBuffer;
    uint32_t delayWrite;
    double delaySamples;

    double ringPhase;
    double vibratoPhase;

    VCBiquad highpass;
    VCBiquad lowpass;
    VCBiquad feedbackLowpass;
    VCBiquad clarity;
};

static void vcBiquadReset(VCBiquad *b) {
    b->b0 = 1.0f;
    b->b1 = 0.0f;
    b->b2 = 0.0f;
    b->a1 = 0.0f;
    b->a2 = 0.0f;
    b->z1 = 0.0f;
    b->z2 = 0.0f;
}

static void vcBiquadSet(VCBiquad *b, double sampleRate, double frequency, double q, int isHighpass) {
    vcBiquadReset(b);
    if (frequency <= 0.0 || frequency >= sampleRate * 0.45) {
        return;
    }
    double w0 = VC_TWO_PI * frequency / sampleRate;
    double cosw = cos(w0);
    double alpha = sin(w0) / (2.0 * q);
    double a0 = 1.0 + alpha;
    double b0, b1, b2;
    if (isHighpass) {
        b0 = (1.0 + cosw) / 2.0;
        b1 = -(1.0 + cosw);
        b2 = (1.0 + cosw) / 2.0;
    } else {
        b0 = (1.0 - cosw) / 2.0;
        b1 = 1.0 - cosw;
        b2 = (1.0 - cosw) / 2.0;
    }
    b->b0 = (float)(b0 / a0);
    b->b1 = (float)(b1 / a0);
    b->b2 = (float)(b2 / a0);
    b->a1 = (float)((-2.0 * cosw) / a0);
    b->a2 = (float)((1.0 - alpha) / a0);
}

// High-shelf (RBJ): lifts (or cuts) everything above `frequency` by `gainDb`. Used to put back
// the consonant energy that pitch shifting smears, which is what makes words hard to make out.
static void vcHighShelfSet(VCBiquad *b, double sampleRate, double frequency, double gainDb) {
    vcBiquadReset(b);
    if (gainDb == 0.0 || frequency <= 0.0 || frequency >= sampleRate * 0.45) {
        return;
    }
    double A = pow(10.0, gainDb / 40.0);
    double w0 = VC_TWO_PI * frequency / sampleRate;
    double cosw = cos(w0);
    double sinw = sin(w0);
    double S = 0.9; // shelf slope
    double alpha = sinw / 2.0 * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
    double twoSqrtAalpha = 2.0 * sqrt(A) * alpha;
    double a0 = (A + 1.0) - (A - 1.0) * cosw + twoSqrtAalpha;
    double b0 = A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAalpha);
    double b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw);
    double b2 = A * ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAalpha);
    double a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw);
    double a2 = (A + 1.0) - (A - 1.0) * cosw - twoSqrtAalpha;
    b->b0 = (float)(b0 / a0);
    b->b1 = (float)(b1 / a0);
    b->b2 = (float)(b2 / a0);
    b->a1 = (float)(a1 / a0);
    b->a2 = (float)(a2 / a0);
}

static inline float vcBiquadRun(VCBiquad *b, float x) {
    float y = b->b0 * x + b->z1;
    b->z1 = b->b1 * x - b->a1 * y + b->z2;
    b->z2 = b->b2 * x - b->a2 * y;
    return y;
}

static VCEffectParams vcParamsForEffect(int32_t effect) {
    VCEffectParams p;
    memset(&p, 0, sizeof(p));
    p.ratio = 1.0;
    p.outputGain = 1.0f;
    switch (effect) {
        case VCEffectChipmunk:
            p.ratio = 1.55;
            p.highpassHz = 110.0;
            p.clarityDb = 2.0;
            break;
        case VCEffectDeep:
            p.ratio = 0.78;
            p.lowpassHz = 6500.0;
            p.clarityDb = 4.0;
            p.outputGain = 1.12f;
            break;
        case VCEffectRobot:
            p.ringFrequency = 75.0;
            p.ringMix = 0.7f;
            p.delaySeconds = 1.0 / 160.0;
            p.delayFeedback = 0.45f;
            p.delayMix = 0.7f;
            p.clarityDb = 2.0;
            p.outputGain = 0.75f;
            break;
        case VCEffectFemale:
            p.ratio = 1.24;
            p.highpassHz = 150.0;
            p.clarityDb = 2.5;
            break;
        case VCEffectMale:
            p.ratio = 0.85;
            p.clarityDb = 3.5;
            p.outputGain = 1.08f;
            break;
        case VCEffectAlien:
            p.ratio = 1.15;
            p.vibratoDepth = 0.08;
            p.vibratoRate = 5.0;
            p.ringFrequency = 220.0;
            p.ringMix = 0.25f;
            p.clarityDb = 1.5;
            break;
        case VCEffectEcho:
            p.delaySeconds = 0.26;
            p.delayFeedback = 0.4f;
            p.delayMix = 0.5f;
            p.outputGain = 0.88f;
            break;
        case VCEffectRadio:
            p.highpassHz = 450.0;
            p.lowpassHz = 3200.0;
            p.drive = 2.4f;
            p.outputGain = 0.92f;
            break;
        case VCEffectMonster:
            p.ratio = 0.62;
            p.drive = 1.6f;
            p.lowpassHz = 3200.0;
            p.clarityDb = 4.5;
            p.outputGain = 1.08f;
            break;
        case VCEffectChild:
            p.ratio = 1.4;
            p.highpassHz = 200.0;
            p.clarityDb = 2.0;
            break;
        case VCEffectCave:
            p.delaySeconds = 0.1;
            p.delayFeedback = 0.55f;
            p.delayMix = 0.55f;
            p.outputGain = 0.82f;
            break;
        default:
            break;
    }
    return p;
}

VCProcessor *VCProcessorCreate(void) {
    VCProcessor *processor = (VCProcessor *)calloc(1, sizeof(VCProcessor));
    processor->pitchBuffer = (float *)calloc(VC_PITCH_BUFFER_SIZE, sizeof(float));
    processor->delayBuffer = (float *)calloc(VC_DELAY_BUFFER_SIZE, sizeof(float));
    processor->sampleRate = 0.0;
    processor->effect = -1;
    return processor;
}

void VCProcessorDestroy(VCProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    free(processor->pitchBuffer);
    free(processor->delayBuffer);
    free(processor);
}

static void vcConfigure(VCProcessor *p, double sampleRate, int32_t effect) {
    p->sampleRate = sampleRate;
    p->effect = effect;
    p->params = vcParamsForEffect(effect);

    memset(p->pitchBuffer, 0, VC_PITCH_BUFFER_SIZE * sizeof(float));
    memset(p->delayBuffer, 0, VC_DELAY_BUFFER_SIZE * sizeof(float));
    p->pitchWrite = 0;
    p->pitchPhase = 0.0;
    p->delayWrite = 0;
    p->ringPhase = 0.0;
    p->vibratoPhase = 0.0;

    // ~24 ms grains: shorter than the classic 35 ms so consonants and transients stay crisp
    // (less echo-like smearing), still long enough to avoid a low buzz.
    p->windowSamples = sampleRate * 0.024;
    double maxWindow = (double)(VC_PITCH_BUFFER_SIZE / 2 - 8);
    if (p->windowSamples > maxWindow) {
        p->windowSamples = maxWindow;
    }
    if (p->windowSamples < 64.0) {
        p->windowSamples = 64.0;
    }

    p->delaySamples = p->params.delaySeconds * sampleRate;
    if (p->delaySamples > (double)(VC_DELAY_BUFFER_SIZE - 4)) {
        p->delaySamples = (double)(VC_DELAY_BUFFER_SIZE - 4);
    }

    vcBiquadSet(&p->highpass, sampleRate, p->params.highpassHz, 0.8, 1);
    vcBiquadSet(&p->lowpass, sampleRate, p->params.lowpassHz, 0.8, 0);
    vcBiquadSet(&p->feedbackLowpass, sampleRate, 3000.0, 0.7, 0);
    vcHighShelfSet(&p->clarity, sampleRate, 2800.0, p->params.clarityDb);
}

static inline float vcReadPitch(const VCProcessor *p, double delay) {
    double position = (double)p->pitchWrite - delay;
    double base = floor(position);
    float frac = (float)(position - base);
    int64_t index = (int64_t)base;
    float a = p->pitchBuffer[(uint32_t)index & VC_PITCH_BUFFER_MASK];
    float b = p->pitchBuffer[(uint32_t)(index + 1) & VC_PITCH_BUFFER_MASK];
    return a + (b - a) * frac;
}

// Two crossfaded read taps sweeping through a short delay line: the classic real-time
// granular pitch shifter. A ratio > 1 raises the pitch, < 1 lowers it.
static inline float vcPitchShift(VCProcessor *p, float x, double ratio) {
    p->pitchBuffer[p->pitchWrite & VC_PITCH_BUFFER_MASK] = x;

    double window = p->windowSamples;
    p->pitchPhase += (1.0 - ratio) / window;
    p->pitchPhase -= floor(p->pitchPhase);

    double phase1 = p->pitchPhase;
    double phase2 = phase1 + 0.5;
    if (phase2 >= 1.0) {
        phase2 -= 1.0;
    }

    float s1 = vcReadPitch(p, phase1 * window + 2.0);
    float s2 = vcReadPitch(p, phase2 * window + 2.0);
    float g1 = (float)sin(M_PI * phase1);
    float g2 = (float)sin(M_PI * phase2);
    g1 *= g1;
    g2 *= g2;

    p->pitchWrite++;
    return s1 * g1 + s2 * g2;
}

static inline float vcReadDelay(const VCProcessor *p) {
    double position = (double)p->delayWrite - p->delaySamples;
    double base = floor(position);
    float frac = (float)(position - base);
    int64_t index = (int64_t)base;
    float a = p->delayBuffer[(uint32_t)index & VC_DELAY_BUFFER_MASK];
    float b = p->delayBuffer[(uint32_t)(index + 1) & VC_DELAY_BUFFER_MASK];
    return a + (b - a) * frac;
}

static inline float vcSoftClip(float x) {
    // Linear up to 0.7, then a tanh knee that approaches 1.0, so loud effects never crackle.
    float ax = fabsf(x);
    if (ax > 0.7f) {
        float shaped = 0.7f + 0.3f * tanhf((ax - 0.7f) / 0.3f);
        return x > 0.0f ? shaped : -shaped;
    }
    return x;
}

static inline float vcProcessSample(VCProcessor *p, float x) {
    const VCEffectParams *params = &p->params;
    double sampleRate = p->sampleRate;
    float y = x;

    if (params->ratio != 1.0 || params->vibratoDepth != 0.0) {
        double ratio = params->ratio;
        if (params->vibratoDepth != 0.0) {
            ratio += params->vibratoDepth * sin(p->vibratoPhase);
            p->vibratoPhase += VC_TWO_PI * params->vibratoRate / sampleRate;
            if (p->vibratoPhase > VC_TWO_PI) {
                p->vibratoPhase -= VC_TWO_PI;
            }
        }
        y = vcPitchShift(p, y, ratio);
    }

    if (params->clarityDb != 0.0) {
        y = vcBiquadRun(&p->clarity, y);
    }

    if (params->ringMix != 0.0f) {
        float carrier = (float)sin(p->ringPhase);
        p->ringPhase += VC_TWO_PI * params->ringFrequency / sampleRate;
        if (p->ringPhase > VC_TWO_PI) {
            p->ringPhase -= VC_TWO_PI;
        }
        y = y * (1.0f - params->ringMix) + y * carrier * params->ringMix * 1.6f;
    }

    if (params->delaySeconds > 0.0) {
        float delayed = vcReadDelay(p);
        float feedback = vcBiquadRun(&p->feedbackLowpass, delayed);
        p->delayBuffer[p->delayWrite & VC_DELAY_BUFFER_MASK] = y + feedback * params->delayFeedback;
        p->delayWrite++;
        y = y + delayed * params->delayMix;
    }

    if (params->highpassHz > 0.0) {
        y = vcBiquadRun(&p->highpass, y);
    }
    if (params->lowpassHz > 0.0) {
        y = vcBiquadRun(&p->lowpass, y);
    }

    if (params->drive > 0.0f) {
        y = tanhf(y * params->drive) / tanhf(params->drive);
    }

    return vcSoftClip(y * params->outputGain);
}

// Returns 0 when there is nothing to do.
static int vcPrepare(VCProcessor *processor, double sampleRate) {
    int32_t effect = VCGetCurrentEffect();
    if (effect == VCEffectNone) {
        processor->effect = VCEffectNone;
        return 0;
    }
    if (sampleRate < 4000.0 || sampleRate > VC_MAX_SAMPLE_RATE) {
        return 0;
    }
    if (processor->effect != effect || processor->sampleRate != sampleRate) {
        vcConfigure(processor, sampleRate, effect);
    }
    return 1;
}

void VCProcessorProcessInt16(VCProcessor *processor, int16_t *samples, int32_t frameCount, int32_t channelCount, double sampleRate) {
    if (processor == NULL || samples == NULL || frameCount <= 0 || channelCount <= 0) {
        return;
    }
    if (!vcPrepare(processor, sampleRate)) {
        return;
    }
    for (int32_t i = 0; i < frameCount; i++) {
        int16_t *frame = samples + (size_t)i * (size_t)channelCount;
        // The microphone is mono: process the first channel and copy it to the others.
        float x = (float)frame[0] * (1.0f / 32768.0f);
        float y = vcProcessSample(processor, x);
        int32_t value = (int32_t)lrintf(y * 32767.0f);
        if (value > 32767) {
            value = 32767;
        } else if (value < -32768) {
            value = -32768;
        }
        for (int32_t c = 0; c < channelCount; c++) {
            frame[c] = (int16_t)value;
        }
    }
}

void VCProcessorProcessFloat32(VCProcessor *processor, float *samples, int32_t frameCount, int32_t channelCount, double sampleRate) {
    if (processor == NULL || samples == NULL || frameCount <= 0 || channelCount <= 0) {
        return;
    }
    if (!vcPrepare(processor, sampleRate)) {
        return;
    }
    for (int32_t i = 0; i < frameCount; i++) {
        float *frame = samples + (size_t)i * (size_t)channelCount;
        float y = vcProcessSample(processor, frame[0]);
        for (int32_t c = 0; c < channelCount; c++) {
            frame[c] = y;
        }
    }
}
