# LiteRT-LM for iOS

Pre-built iOS frameworks for [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), Google's on-device LLM inference engine.

## Frameworks

| Framework | Type | Purpose |
|-----------|------|---------|
| **LiteRTLM.xcframework** | Static | Core LLM engine + Obj-C wrapper. Required. |
| **GemmaConstraintProvider.xcframework** | Dynamic | Constrained decoding / tool calling for Gemma models. Optional. |

Download both from the [latest CI run](../../actions/workflows/build-ios.yml) artifacts.

## Setup

### Xcode

1. Drag `LiteRTLM.xcframework` into your project's **Frameworks, Libraries, and Embedded Content**. Set to **Do Not Embed** (it's static).
2. If using constrained decoding / tool calling: also add `GemmaConstraintProvider.xcframework` and set to **Embed & Sign**.
3. Add these system frameworks in **Build Phases → Link Binary With Libraries**:
   - `Metal.framework`
   - `AVFoundation.framework`
   - `AudioToolbox.framework`
4. Add `-lc++` to **Other Linker Flags** (if not already present).

### Import

```objc
#import <LiteRTLM/LiteRTLM.h>
```

## Usage

### Basic text generation

```objc
// Load model
LRTEngineConfig *config = [LRTEngineConfig configWithModelPath:modelPath];
config.backend = LRTBackendCPU;

NSError *error;
LRTEngine *engine = [LRTEngine engineWithConfig:config error:&error];

// Create session and generate
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
        // Append token to UI
        [self appendText:token];
    } else {
        // Generation complete (token == nil, error == nil)
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

// Get full history
NSArray<NSDictionary *> *history = conv.history;
```

### Constrained decoding (JSON output)

Requires `GemmaConstraintProvider.xcframework` to be linked.

```objc
LRTConversationConfig *config = [LRTConversationConfig defaultConfig];
config.enableConstrainedDecoding = YES;

LRTConversation *conv = [LRTConversation conversationWithEngine:engine
                                                         config:config
                                                          error:&error];

LRTConstraint *schema = [LRTConstraint jsonSchemaConstraint:
    @"{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}},\"required\":[\"name\",\"age\"]}"];

NSString *json = [conv sendMessage:@"Generate a person profile"
                        constraint:schema
                             error:&error];
// json is guaranteed valid JSON matching the schema
```

Other constraint types:
```objc
// Regex: output must match the pattern
LRTConstraint *re = [LRTConstraint regexConstraint:@"(yes|no)"];

// Lark grammar
LRTConstraint *lark = [LRTConstraint larkConstraint:@"start: \"hello\" \" \" NAME\nNAME: /[a-z]+/"];
```

### Session cloning and checkpoints

```objc
// Clone a session to branch the conversation
LRTSession *clone = [session cloneWithError:&error];

// Save/restore KV cache state
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

// After inference:
LRTBenchmarkInfo *bench = [session benchmarkInfoWithError:&error];
NSLog(@"Prefill: %.1f tok/s, Decode: %.1f tok/s, TTFT: %.1f ms",
      bench.prefillTokensPerSecond,
      bench.decodeTokensPerSecond,
      bench.timeToFirstTokenMs);
```

## API Reference

### Core Classes

| Class | Purpose |
|-------|---------|
| `LRTEngine` | Load model, create sessions, tokenizer access |
| `LRTSession` | Low-level inference: generate, prefill/decode, clone, checkpoints |
| `LRTConversation` | High-level chat: message history, prompt templates, tool calling |

### Configuration

| Class | Purpose |
|-------|---------|
| `LRTEngineConfig` | Model path, backend (CPU/GPU), vision/audio backends, threads |
| `LRTSessionConfig` | Temperature, topK, topP, maxOutputTokens, vision/audio enable |
| `LRTConversationConfig` | System prompt, tools, constrained decoding, channels |
| `LRTDecodeConfig` | Per-call max tokens and constraint |

### Types

| Class | Purpose |
|-------|---------|
| `LRTInputText` | Text input for multimodal content arrays |
| `LRTInputImage` | Image input (raw JPEG/PNG bytes) |
| `LRTInputAudio` | Audio input (raw audio bytes) |
| `LRTConstraint` | JSON schema, regex, or Lark grammar constraint |
| `LRTChannel` | Named output channel with start/end delimiters |
| `LRTBenchmarkInfo` | Prefill/decode tokens per second, time to first token |
| `LRTResponse` | Response text, task state, scores |

## Building from source

Requires macOS with Xcode and Bazel (via Bazelisk):

```bash
./scripts/build-litert-lm-ios.sh
# Output: build/output/LiteRTLM.xcframework
#         build/output/GemmaConstraintProvider.xcframework
```

Set `LITERT_LM_VERSION` to build a different version (default: `v0.10.1`).

## How it works

The CI workflow:
1. Clones LiteRT-LM at the pinned version
2. Injects an `apple_static_library` Bazel target bundling all C++ transitive deps
3. Cross-compiles for `ios_arm64` (device) and `ios_sim_arm64` (simulator)
4. Compiles the Obj-C++ wrapper against the built headers
5. Merges wrapper objects into the static library
6. Packages as xcframeworks with only the public Obj-C headers exposed
7. Verifies with a compile + link test

## License

Wrapper code in this repo: MIT. LiteRT-LM and its dependencies: Apache 2.0.
