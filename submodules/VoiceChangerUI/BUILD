load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "VoiceChangerUI",
    module_name = "VoiceChangerUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/VoiceChangerCore",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
