#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#include <VoiceChangerCore/VoiceChangerCore.h>

@implementation VCAudioProcessor {
    VCProcessor *_processor;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _processor = VCProcessorCreate();
    }
    return self;
}

- (void)dealloc {
    VCProcessorDestroy(_processor);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    VCProcessorProcessSampleBuffer(_processor, sampleBuffer);
}

@end

void VCProcessorProcessSampleBuffer(VCProcessor *processor, CMSampleBufferRef sampleBuffer) {
    if (processor == NULL || sampleBuffer == NULL) {
        return;
    }
    if (VCGetCurrentEffect() == VCEffectNone) {
        return;
    }
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (formatDescription == NULL || CMFormatDescriptionGetMediaType(formatDescription) != kCMMediaType_Audio) {
        return;
    }
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (asbd == NULL || asbd->mFormatID != kAudioFormatLinearPCM) {
        return;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 && asbd->mChannelsPerFrame > 1) {
        return;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return;
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (blockBuffer == NULL) {
        return;
    }
    size_t totalLength = CMBlockBufferGetDataLength(blockBuffer);
    if (totalLength == 0 || !CMBlockBufferIsRangeContiguous(blockBuffer, 0, totalLength)) {
        return;
    }
    char *data = NULL;
    size_t lengthAtOffset = 0;
    if (CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, NULL, &data) != kCMBlockBufferNoErr || data == NULL || lengthAtOffset < totalLength) {
        return;
    }

    int32_t channelCount = (int32_t)asbd->mChannelsPerFrame;
    if (channelCount <= 0) {
        return;
    }
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    if (isFloat && asbd->mBitsPerChannel == 32) {
        int32_t frameCount = (int32_t)(totalLength / (sizeof(float) * (size_t)channelCount));
        VCProcessorProcessFloat32(processor, (float *)data, frameCount, channelCount, asbd->mSampleRate);
    } else if (!isFloat && asbd->mBitsPerChannel == 16 && (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0) {
        int32_t frameCount = (int32_t)(totalLength / (sizeof(int16_t) * (size_t)channelCount));
        VCProcessorProcessInt16(processor, (int16_t *)data, frameCount, channelCount, asbd->mSampleRate);
    }
}
