load("@rules_cc//cc:objc_library.bzl", "objc_library")

# Real-time voice effects applied to the microphone before it is encoded:
# voice messages (ManagedAudioRecorder), round videos (CameraNeo / CameraLegacy)
# and calls (the shared call audio device in TgVoipWebrtc).
objc_library(
    name = "VoiceChangerCore",
    enable_modules = True,
    module_name = "VoiceChangerCore",
    srcs = glob([
        "Sources/*.c",
        "Sources/*.m",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = [
        "-O2",
    ],
    sdk_frameworks = [
        "Foundation",
        "CoreMedia",
        "AudioToolbox",
    ],
    visibility = [
        "//visibility:public",
    ],
)
