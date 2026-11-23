#ifndef VoiceChangerCore_h
#define VoiceChangerCore_h

#include <stdint.h>
#ifdef __APPLE__
#include <CoreMedia/CoreMedia.h>
#else
#define _Nonnull
#define _Nullable
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Voice effects. The numeric values are persisted (UserDefaults), never reorder them.
typedef enum {
    VCEffectNone = 0,
    VCEffectChipmunk = 1,
    VCEffectDeep = 2,
    VCEffectRobot = 3,
    VCEffectFemale = 4,
    VCEffectMale = 5,
    VCEffectAlien = 6,
    VCEffectEcho = 7,
    VCEffectRadio = 8,
    VCEffectMonster = 9,
    VCEffectChild = 10,
    VCEffectCave = 11,
    VCEffectCount = 12
} VCEffect;

/// The effect applied by every processor. Thread-safe, takes effect immediately
/// (also in the middle of a call or a recording).
void VCSetCurrentEffect(int32_t effect);
int32_t VCGetCurrentEffect(void);

typedef struct VCProcessor VCProcessor;

/// One processor per audio stream: it keeps the stream's filter and delay state.
/// A processor must be used from one thread at a time.
VCProcessor * _Nonnull VCProcessorCreate(void);
void VCProcessorDestroy(VCProcessor * _Nullable processor);

/// Processes interleaved 16-bit PCM in place with the current effect.
/// Does nothing (and costs nothing) while the current effect is VCEffectNone.
void VCProcessorProcessInt16(VCProcessor * _Nonnull processor, int16_t * _Nonnull samples, int32_t frameCount, int32_t channelCount, double sampleRate);

/// Processes interleaved 32-bit float PCM in place with the current effect.
void VCProcessorProcessFloat32(VCProcessor * _Nonnull processor, float * _Nonnull samples, int32_t frameCount, int32_t channelCount, double sampleRate);

/// Processes the linear PCM audio of a capture sample buffer in place
/// (16-bit integer or 32-bit float, interleaved). Other formats are left untouched.
#ifdef __APPLE__
void VCProcessorProcessSampleBuffer(VCProcessor * _Nonnull processor, CMSampleBufferRef _Nonnull sampleBuffer);
#endif

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__)
#import <Foundation/Foundation.h>

/// Objective-C owner of a VCProcessor, for Swift code that processes capture sample buffers
/// (round videos). The processor is freed when the object is released.
@interface VCAudioProcessor : NSObject

// Explicit name: Swift would otherwise prune the "SampleBuffer" suffix to `process(_:)`.
- (void)processSampleBuffer:(CMSampleBufferRef _Nonnull)sampleBuffer NS_SWIFT_NAME(processSampleBuffer(_:));

@end
#endif

#endif
