#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Backend used for LLM inference.
typedef NS_ENUM(NSInteger, LRTBackend) {
    LRTBackendCPU,
    LRTBackendGPU,
};

/// Benchmark timing information from an inference run.
@interface LRTBenchmarkInfo : NSObject
@property (nonatomic, readonly) double prefillTokensPerSecond;
@property (nonatomic, readonly) double decodeTokensPerSecond;
@property (nonatomic, readonly) double timeToFirstTokenMs;
@property (nonatomic, readonly) NSInteger prefillTokenCount;
@property (nonatomic, readonly) NSInteger decodeTokenCount;
@end

/// Configuration for creating an engine.
@interface LRTEngineConfig : NSObject
@property (nonatomic, copy) NSString *modelPath;
@property (nonatomic) LRTBackend backend;
@property (nonatomic) NSInteger maxTokens;
@property (nonatomic) NSInteger numCpuThreads;
@property (nonatomic, copy, nullable) NSString *cacheDir;

+ (instancetype)configWithModelPath:(NSString *)modelPath;
@end

/// Configuration for creating a session.
@interface LRTSessionConfig : NSObject
@property (nonatomic) float temperature;
@property (nonatomic) NSInteger topK;
@property (nonatomic) float topP;
@property (nonatomic) NSInteger maxOutputTokens;
@property (nonatomic, copy, nullable) NSString *systemPrompt;

+ (instancetype)defaultConfig;
@end

/// Response from the LLM.
@interface LRTResponse : NSObject
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, readonly) BOOL done;
@property (nonatomic, strong, readonly, nullable) LRTBenchmarkInfo *benchmarkInfo;
@end

NS_ASSUME_NONNULL_END
