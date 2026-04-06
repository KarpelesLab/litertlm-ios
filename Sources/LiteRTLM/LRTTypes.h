#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Backend used for LLM inference.
typedef NS_ENUM(NSInteger, LRTBackend) {
    LRTBackendCPU,
    LRTBackendGPU,
};

/// State of an inference task.
typedef NS_ENUM(NSInteger, LRTTaskState) {
    LRTTaskStateUnknown,
    LRTTaskStateCreated,
    LRTTaskStateQueued,
    LRTTaskStateProcessing,
    LRTTaskStateDone,
    LRTTaskStateMaxTokensReached,
    LRTTaskStateFailed,
    LRTTaskStateCancelled,
};

// ---------------------------------------------------------------------------
// Input types (multimodal)
// ---------------------------------------------------------------------------

/// Wraps a text input for multimodal content arrays.
@interface LRTInputText : NSObject
@property (nonatomic, copy, readonly) NSString *text;
+ (instancetype)inputWithText:(NSString *)text;
@end

/// Wraps an image input. Pass raw image file bytes (JPEG, PNG, etc.).
@interface LRTInputImage : NSObject
@property (nonatomic, strong, readonly) NSData *imageData;
+ (instancetype)inputWithData:(NSData *)data;
@end

/// Wraps an audio input. Pass raw audio file bytes.
@interface LRTInputAudio : NSObject
@property (nonatomic, strong, readonly) NSData *audioData;
+ (instancetype)inputWithData:(NSData *)data;
@end

/// A single content item — text, image, or audio.
/// Use in arrays passed to multimodal generation methods.
typedef id LRTInputContent; // LRTInputText | LRTInputImage | LRTInputAudio

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration for creating an engine.
@interface LRTEngineConfig : NSObject
@property (nonatomic, copy) NSString *modelPath;
@property (nonatomic) LRTBackend backend;
@property (nonatomic) LRTBackend visionBackend;
@property (nonatomic) LRTBackend audioBackend;
@property (nonatomic) NSInteger maxTokens;
@property (nonatomic) NSInteger numCpuThreads;
@property (nonatomic, copy, nullable) NSString *cacheDir;
@property (nonatomic) BOOL benchmark;

+ (instancetype)configWithModelPath:(NSString *)modelPath;
@end

/// Configuration for creating a session.
@interface LRTSessionConfig : NSObject
@property (nonatomic) float temperature;
@property (nonatomic) NSInteger topK;
@property (nonatomic) float topP;
@property (nonatomic) NSInteger maxOutputTokens;
@property (nonatomic, copy, nullable) NSString *systemPrompt;
@property (nonatomic) BOOL enableVision;
@property (nonatomic) BOOL enableAudio;

+ (instancetype)defaultConfig;
@end

/// Per-call decode configuration.
@interface LRTDecodeConfig : NSObject
@property (nonatomic) NSInteger maxOutputTokens;

+ (instancetype)defaultConfig;
@end

// ---------------------------------------------------------------------------
// Output / info types
// ---------------------------------------------------------------------------

/// Properties of the vision executor.
@interface LRTVisionProperties : NSObject
@property (nonatomic, readonly) NSInteger numTokensPerImage;
@property (nonatomic, readonly) NSInteger patchNumShrinkFactor; // 0 = not set
@end

/// Properties of the audio executor.
@interface LRTAudioProperties : NSObject
@property (nonatomic, readonly) BOOL isStreamingModel;
@property (nonatomic, readonly) NSInteger streamingChunkSize;
@property (nonatomic, readonly) NSInteger streamingChunkOverlapSize;
@property (nonatomic, readonly) NSInteger audioShrinkFactor;
@end

/// Benchmark timing information from an inference run.
@interface LRTBenchmarkInfo : NSObject
@property (nonatomic, readonly) double timeToFirstTokenMs;

/// Per-turn prefill stats. Index = turn number.
@property (nonatomic, readonly) NSUInteger totalPrefillTurns;
- (double)prefillTokensPerSecondForTurn:(NSUInteger)turn;

/// Per-turn decode stats. Index = turn number.
@property (nonatomic, readonly) NSUInteger totalDecodeTurns;
- (double)decodeTokensPerSecondForTurn:(NSUInteger)turn;

/// Convenience: aggregate first-turn stats (most common use case).
@property (nonatomic, readonly) double prefillTokensPerSecond;
@property (nonatomic, readonly) double decodeTokensPerSecond;
@end

/// Response from the LLM.
@interface LRTResponse : NSObject
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, readonly) LRTTaskState taskState;
@property (nonatomic, strong, readonly, nullable) LRTBenchmarkInfo *benchmarkInfo;
/// Scores (for text scoring). One per candidate.
@property (nonatomic, strong, readonly, nullable) NSArray<NSNumber *> *scores;
@end

NS_ASSUME_NONNULL_END
