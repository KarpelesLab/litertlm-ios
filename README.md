# LiteRT-LM for iOS

Build infrastructure for [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) (Google's on-device LLM inference framework) targeting iOS.

This repo provides:
- **GitHub Actions workflow** that builds LiteRT-LM from source for iOS arm64 (device) and arm64 simulator
- **Obj-C++ wrapper** (`LRTEngine`, `LRTSession`) bridging the C++ API for Swift consumption
- **xcframework** output containing the static library and headers

## How it works

The CI workflow:
1. Clones LiteRT-LM at a pinned version (currently `v0.10.1`)
2. Injects an `apple_static_library` Bazel target to bundle all transitive dependencies
3. Cross-compiles for `ios_arm64` (device) and `ios_sim_arm64` (simulator) using Bazel
4. Collects the static libraries and public/dependency headers
5. Packages everything into an xcframework
6. Uploads as a GitHub Actions artifact

## Artifacts

Built xcframeworks are available as artifacts on successful workflow runs. Download from the [Actions tab](../../actions).

## Wrapper API

The Obj-C++ wrapper in `Sources/LiteRTLM/` provides:

- **`LRTEngine`** - Load a model and create sessions
- **`LRTSession`** - Generate responses (blocking or streaming)
- **`LRTTypes`** - Configuration and response types

```objc
LRTEngineConfig *config = [LRTEngineConfig configWithModelPath:@"model.litertlm"];
config.backend = LRTBackendCPU;

NSError *error;
LRTEngine *engine = [LRTEngine engineWithConfig:config error:&error];
LRTSession *session = [engine createSessionWithError:&error];

NSString *response = [session generateResponseWithInput:@"Hello!" error:&error];
```

## Building locally

Requires macOS with Xcode and Bazel (via Bazelisk):

```bash
export WORK_DIR=$(pwd)/build
./scripts/build-litert-lm-ios.sh
# Output: build/output/LiteRTLM.xcframework
```

## Dependencies

All dependencies are built from source by Bazel:
- [Abseil C++](https://github.com/abseil/abseil-cpp)
- [FlatBuffers](https://github.com/google/flatbuffers)
- [XNNPACK](https://github.com/google/XNNPACK)
- [Sentencepiece](https://github.com/google/sentencepiece)
- [LiteRT](https://github.com/google-ai-edge/LiteRT) (core runtime)

## License

Wrapper code in this repo is available under the MIT license. LiteRT-LM and its dependencies are under the Apache 2.0 license.
