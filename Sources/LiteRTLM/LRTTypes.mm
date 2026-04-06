#import "LRTTypes.h"

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

@implementation LRTInputText
+ (instancetype)inputWithText:(NSString *)text {
    LRTInputText *obj = [[LRTInputText alloc] init];
    obj->_text = [text copy];
    return obj;
}
@end

@implementation LRTInputImage
+ (instancetype)inputWithData:(NSData *)data {
    LRTInputImage *obj = [[LRTInputImage alloc] init];
    obj->_imageData = [data copy];
    return obj;
}
@end

@implementation LRTInputAudio
+ (instancetype)inputWithData:(NSData *)data {
    LRTInputAudio *obj = [[LRTInputAudio alloc] init];
    obj->_audioData = [data copy];
    return obj;
}
@end

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

@implementation LRTEngineConfig

+ (instancetype)configWithModelPath:(NSString *)modelPath {
    LRTEngineConfig *config = [[LRTEngineConfig alloc] init];
    config.modelPath = modelPath;
    config.backend = LRTBackendCPU;
    config.visionBackend = LRTBackendCPU;
    config.audioBackend = LRTBackendCPU;
    config.maxTokens = 0;
    config.numCpuThreads = 0;
    config.benchmark = NO;
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
    config.enableVision = NO;
    config.enableAudio = NO;
    return config;
}

@end

@implementation LRTConstraint

+ (instancetype)jsonSchemaConstraint:(NSString *)jsonSchema {
    LRTConstraint *c = [[LRTConstraint alloc] init];
    c->_type = LRTConstraintTypeJsonSchema;
    c->_definition = [jsonSchema copy];
    return c;
}

+ (instancetype)regexConstraint:(NSString *)pattern {
    LRTConstraint *c = [[LRTConstraint alloc] init];
    c->_type = LRTConstraintTypeRegex;
    c->_definition = [pattern copy];
    return c;
}

+ (instancetype)larkConstraint:(NSString *)grammar {
    LRTConstraint *c = [[LRTConstraint alloc] init];
    c->_type = LRTConstraintTypeLark;
    c->_definition = [grammar copy];
    return c;
}

@end

@implementation LRTDecodeConfig

+ (instancetype)defaultConfig {
    LRTDecodeConfig *config = [[LRTDecodeConfig alloc] init];
    config.maxOutputTokens = -1; // use session default
    return config;
}

@end

@implementation LRTChannel

+ (instancetype)channelWithName:(NSString *)name
                 startDelimiter:(NSString *)start
                   endDelimiter:(NSString *)end {
    LRTChannel *ch = [[LRTChannel alloc] init];
    ch->_name = [name copy];
    ch->_startDelimiter = [start copy];
    ch->_endDelimiter = [end copy];
    return ch;
}

@end

// ---------------------------------------------------------------------------
// Output / info types
// ---------------------------------------------------------------------------

@implementation LRTVisionProperties
- (instancetype)initWithTokensPerImage:(NSInteger)tokensPerImage
                    patchShrinkFactor:(NSInteger)patchShrink {
    self = [super init];
    if (self) {
        _numTokensPerImage = tokensPerImage;
        _patchNumShrinkFactor = patchShrink;
    }
    return self;
}
@end

@implementation LRTAudioProperties
- (instancetype)initWithStreaming:(BOOL)streaming
                       chunkSize:(NSInteger)chunkSize
                     overlapSize:(NSInteger)overlapSize
                    shrinkFactor:(NSInteger)shrinkFactor {
    self = [super init];
    if (self) {
        _isStreamingModel = streaming;
        _streamingChunkSize = chunkSize;
        _streamingChunkOverlapSize = overlapSize;
        _audioShrinkFactor = shrinkFactor;
    }
    return self;
}
@end

@implementation LRTBenchmarkInfo {
    double _timeToFirstTokenMs;
    NSUInteger _totalPrefillTurns;
    NSUInteger _totalDecodeTurns;
    // C++ BenchmarkInfo pointer stored opaquely; accessed via the .mm that creates this
    // We store the per-turn values as arrays for simplicity
    NSArray<NSNumber *> *_prefillTPS;
    NSArray<NSNumber *> *_decodeTPS;
}

- (instancetype)initWithTimeToFirstToken:(double)ttft
                          prefillTPSArray:(NSArray<NSNumber *> *)prefillTPS
                           decodeTPSArray:(NSArray<NSNumber *> *)decodeTPS {
    self = [super init];
    if (self) {
        _timeToFirstTokenMs = ttft;
        _prefillTPS = prefillTPS;
        _decodeTPS = decodeTPS;
        _totalPrefillTurns = prefillTPS.count;
        _totalDecodeTurns = decodeTPS.count;
    }
    return self;
}

- (double)prefillTokensPerSecondForTurn:(NSUInteger)turn {
    if (turn < _prefillTPS.count) return _prefillTPS[turn].doubleValue;
    return 0;
}

- (double)decodeTokensPerSecondForTurn:(NSUInteger)turn {
    if (turn < _decodeTPS.count) return _decodeTPS[turn].doubleValue;
    return 0;
}

- (double)prefillTokensPerSecond {
    return [self prefillTokensPerSecondForTurn:0];
}

- (double)decodeTokensPerSecond {
    return [self decodeTokensPerSecondForTurn:0];
}

@end

@implementation LRTResponse {
    NSString *_text;
    LRTTaskState _taskState;
    LRTBenchmarkInfo *_benchmarkInfo;
    NSArray<NSNumber *> *_scores;
}

- (instancetype)initWithText:(NSString *)text
                   taskState:(LRTTaskState)taskState
               benchmarkInfo:(nullable LRTBenchmarkInfo *)benchmarkInfo
                      scores:(nullable NSArray<NSNumber *> *)scores {
    self = [super init];
    if (self) {
        _text = [text copy];
        _taskState = taskState;
        _benchmarkInfo = benchmarkInfo;
        _scores = scores;
    }
    return self;
}

@end
