#import "LRTTypes.h"

@implementation LRTBenchmarkInfo {
    double _prefillTokensPerSecond;
    double _decodeTokensPerSecond;
    double _timeToFirstTokenMs;
    NSInteger _prefillTokenCount;
    NSInteger _decodeTokenCount;
}

- (instancetype)initWithPrefillTPS:(double)prefillTPS
                         decodeTPS:(double)decodeTPS
                    timeToFirstMs:(double)ttft
                    prefillTokens:(NSInteger)prefillTokens
                     decodeTokens:(NSInteger)decodeTokens {
    self = [super init];
    if (self) {
        _prefillTokensPerSecond = prefillTPS;
        _decodeTokensPerSecond = decodeTPS;
        _timeToFirstTokenMs = ttft;
        _prefillTokenCount = prefillTokens;
        _decodeTokenCount = decodeTokens;
    }
    return self;
}

@end

@implementation LRTEngineConfig

+ (instancetype)configWithModelPath:(NSString *)modelPath {
    LRTEngineConfig *config = [[LRTEngineConfig alloc] init];
    config.modelPath = modelPath;
    config.backend = LRTBackendCPU;
    config.maxTokens = 0;
    config.numCpuThreads = 0;
    return config;
}

@end

@implementation LRTSessionConfig

+ (instancetype)defaultConfig {
    LRTSessionConfig *config = [[LRTSessionConfig alloc] init];
    config.temperature = 0.8f;
    config.topK = 40;
    config.topP = 0.95f;
    config.maxOutputTokens = 1024;
    return config;
}

@end

@implementation LRTResponse {
    NSString *_text;
    BOOL _done;
    LRTBenchmarkInfo *_benchmarkInfo;
}

- (instancetype)initWithText:(NSString *)text
                        done:(BOOL)done
               benchmarkInfo:(LRTBenchmarkInfo *)benchmarkInfo {
    self = [super init];
    if (self) {
        _text = [text copy];
        _done = done;
        _benchmarkInfo = benchmarkInfo;
    }
    return self;
}

@end
