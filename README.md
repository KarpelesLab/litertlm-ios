# LiteRT-LM for iOS

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

## License

Wrapper code: MIT. LiteRT-LM and dependencies: Apache 2.0.
