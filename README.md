# LiteRT-LM for iOS

> **⚠️ Status: Shelved (April 2026)**
>
> This project is **frozen** and not actively maintained. It works (produces a
> functional `LiteRTLM.xcframework`) but LiteRT-LM on iOS has a structural
> limitation that makes it the wrong choice for production today: **Google's
> GPU accelerator for LiteRT-LM is not open-source.** We wrote a Metal adapter
> that bridges LiteRT-LM's accelerator plugin interface to the open-source
> TFLite Metal GPU delegate, but it's a workaround — not a first-class path.
>
> **For new iOS on-device LLM work, use one of these instead:**
>
> | Runtime | Strengths |
> |---------|-----------|
> | **[MLX Swift](https://github.com/ml-explore/mlx-swift)** | Apple's native ML framework. Metal-first. Qwen, Gemma, Llama, Phi out of the box. Fastest on Apple Silicon. |
> | **[SharpAI/SwiftLM](https://github.com/SharpAI/SwiftLM)** | MLX Swift + TurboQuant KV cache compression. Best memory efficiency. Runs on iPhone 13 Pro (6 GB). |
> | **[llama.cpp](https://github.com/ggml-org/llama.cpp)** | Most portable. GGUF format. Widest model/quantization support. |
> | **[MLC-LLM](https://llm.mlc.ai/docs/deploy/ios.html)** | TVM-based, cross-platform, has an iOS chat app. |
>
> This repo remains useful if:
> - Google eventually open-sources the real LiteRT-LM GPU accelerator (see
>   [upstream issue #1050](https://github.com/google-ai-edge/LiteRT-LM/issues/1050))
> - You need a specific Google feature (proprietary model compilations, etc.)
> - You're researching how to bridge TFLite delegates into LiteRT-LM
>
> The build infrastructure (Bazel iOS cross-compilation, apple_static_library
> injection, Metal delegate adapter, Rust CXX bridge stubs) may be useful as
> reference for similar integration problems.

---

Pre-built iOS framework for [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), Google's on-device LLM inference engine.

Download `LiteRTLM.xcframework` from the [latest CI run](../../actions/workflows/build-ios.yml) artifacts.

## Setup

1. Drag `LiteRTLM.xcframework` into your Xcode project's **Frameworks, Libraries, and Embedded Content**. Set to **Do Not Embed** (it's static).
2. Add these system frameworks in **Build Phases → Link Binary With Libraries**:
   - `Metal.framework`
   - `AVFoundation.framework`
   - `AudioToolbox.framework`
3. Add `-lc++` to **Other Linker Flags** (if not already present).
4. Import:

```objc
#import "LiteRTLM.h"
```

## Usage

### Text generation

```objc
LRTEngineConfig *config = [LRTEngineConfig configWithModelPath:modelPath];
NSError *error;
LRTEngine *engine = [LRTEngine engineWithConfig:config error:&error];

LRTSession *session = [engine createSessionWithError:&error];
NSString *response = [session generateResponseWithInput:@"What is the capital of France?"
                                                  error:&error];
```

### Streaming

```objc
[session generateStreamingResponseWithInput:@"Tell me a story"
                                   callback:^(NSString *token, NSError *error) {
    if (error) {
        NSLog(@"Error: %@", error);
    } else if (token) {
        [self appendText:token];  // append to UI
    } else {
        // done (token == nil, error == nil)
    }
} error:&error];
```

### Vision (multimodal)

```objc
LRTSessionConfig *sc = [LRTSessionConfig defaultConfig];
sc.enableVision = YES;
LRTSession *session = [engine createSessionWithConfig:sc error:&error];

NSData *imageData = [NSData dataWithContentsOfFile:@"photo.jpg"];
NSArray *contents = @[
    [LRTInputImage inputWithData:imageData],
    [LRTInputText inputWithText:@"What's in this image?"]
];
NSString *response = [session generateResponseWithContents:contents error:&error];
```

### Conversation with system prompt

```objc
LRTConversationConfig *config = [LRTConversationConfig defaultConfig];
config.systemPrompt = @"You are a helpful assistant.";
config.temperature = 0.7;

LRTConversation *conv = [LRTConversation conversationWithEngine:engine
                                                         config:config
                                                          error:&error];

NSString *reply1 = [conv sendMessage:@"Hello!" error:&error];
NSString *reply2 = [conv sendMessage:@"What did I just say?" error:&error];

// Full history as JSON-compatible dictionaries
NSArray<NSDictionary *> *history = conv.history;
```

### Constrained decoding (JSON output)

```objc
LRTConversationConfig *config = [LRTConversationConfig defaultConfig];
config.enableConstrainedDecoding = YES;

LRTConversation *conv = [LRTConversation conversationWithEngine:engine
                                                         config:config
                                                          error:&error];

LRTConstraint *schema = [LRTConstraint jsonSchemaConstraint:
    @"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}"];

// Output is guaranteed valid JSON matching the schema
NSString *json = [conv sendMessage:@"Generate a person profile"
                        constraint:schema
                             error:&error];
```

Other constraint types:
```objc
LRTConstraint *re = [LRTConstraint regexConstraint:@"(yes|no)"];
LRTConstraint *lark = [LRTConstraint larkConstraint:@"start: \"hello\" \" \" NAME\nNAME: /[a-z]+/"];
```

### Session cloning and checkpoints

```objc
LRTSession *clone = [session cloneWithError:&error];

[session saveCheckpoint:@"before_question" error:&error];
// ... generate ...
[session rewindToCheckpoint:@"before_question" error:&error];
```

### Tokenizer

```objc
NSArray<NSNumber *> *tokens = [engine tokenize:@"Hello world" error:&error];
NSString *text = [engine detokenize:tokens error:&error];
```

### Benchmarking

```objc
LRTEngineConfig *config = [LRTEngineConfig configWithModelPath:modelPath];
config.benchmark = YES;
// ... create engine, run inference ...
LRTBenchmarkInfo *bench = [session benchmarkInfoWithError:&error];
NSLog(@"Prefill: %.1f tok/s, Decode: %.1f tok/s, TTFT: %.1f ms",
      bench.prefillTokensPerSecond, bench.decodeTokensPerSecond, bench.timeToFirstTokenMs);
```

## API Reference

| Class | Purpose |
|-------|---------|
| **LRTEngine** | Load model, create sessions, tokenizer access |
| **LRTSession** | Low-level inference: generate, prefill/decode, clone, checkpoints |
| **LRTConversation** | High-level chat: message history, prompt templates, constrained decoding |
| **LRTEngineConfig** | Model path, backend (CPU/GPU), vision/audio backends, threads |
| **LRTSessionConfig** | Temperature, topK, topP, maxOutputTokens, vision/audio enable |
| **LRTConversationConfig** | System prompt, tools, constrained decoding, channels |
| **LRTDecodeConfig** | Per-call max tokens and constraint |
| **LRTConstraint** | JSON schema, regex, or Lark grammar constraint |
| **LRTInputText** / **LRTInputImage** / **LRTInputAudio** | Multimodal content inputs |
| **LRTChannel** | Named output channel with start/end delimiters |
| **LRTBenchmarkInfo** | Prefill/decode tokens per second, time to first token |

## Building from source

Requires macOS with Xcode and Bazel (via Bazelisk):

```bash
./scripts/build-litert-lm-ios.sh
# Output: build/output/LiteRTLM.xcframework
```

Set `LITERT_LM_VERSION` to build a different version (default: `v0.10.1`).

## What we learned (project post-mortem)

This project cross-compiled LiteRT-LM for iOS end-to-end, but discovered several
upstream issues that make it impractical for production use today:

1. **GPU accelerator is closed-source** — LiteRT-LM's `default_static_gpu_accelerator`
   target in the BUILD file has empty deps; the actual GPU implementation is Google-
   internal and stripped via copybara from public releases. Our Metal delegate
   adapter (`Sources/LiteRTLM/MetalGpuAccelerator.mm`) works as a bridge but is not
   optimized for LLM workloads the way Google's internal version presumably is.

2. **GemmaConstraintProvider prebuilts are broken** — `prebuilt/ios_arm64/` ships
   a dylib tagged with `platform 2` (macOS) and `minos 26.2` — it's actually a
   simulator binary, not a device binary. We dropped the Gemma-specific constraint
   provider entirely (the open-source llguidance path covers JSON/regex/grammar
   constraints anyway) and provided C stubs for the symbols.

3. **Generated header extraction is fragile** — Bazel's `apple_static_library`
   does platform transitions that scatter generated files into `_virtual_includes`
   symlinks. Some generated files (like `minijinja_template.rs.h`) only exist
   transiently during compilation. We worked around this with stubs.

4. **LiteRT-LM targets server-class inference** — the runtime is designed for
   Android/Linux/desktop first, with iOS support being experimental. The native
   iOS LLM runtimes (MLX, llama.cpp, MLC-LLM) are more mature and better optimized
   for Apple Silicon.

See [the Metal adapter](Sources/LiteRTLM/MetalGpuAccelerator.mm) for an example of
bridging TFLite delegates into LiteRT-LM's accelerator plugin system — this pattern
may be useful if you're integrating a custom backend.

## License

Wrapper code: MIT. LiteRT-LM and dependencies: Apache 2.0.
