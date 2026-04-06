#import "LRTEngine.h"
#import "LRTSession.h"

// C++ headers
#include "runtime/engine/engine.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"

static NSString *const LRTErrorDomain = @"com.litert-lm.ios";

static NSError *NSErrorFromAbslStatus(const absl::Status &status) {
    return [NSError errorWithDomain:LRTErrorDomain
                               code:(NSInteger)status.raw_code()
                           userInfo:@{
        NSLocalizedDescriptionKey: @(std::string(status.message()).c_str())
    }];
}

static litert::lm::Backend BackendFromLRT(LRTBackend b) {
    switch (b) {
        case LRTBackendGPU: return litert::lm::Backend::GPU;
        case LRTBackendCPU:
        default:            return litert::lm::Backend::CPU;
    }
}

// ---------------------------------------------------------------------------
// LRTSession internal init
// ---------------------------------------------------------------------------

@interface LRTSession ()
- (instancetype)initWithSession:(std::unique_ptr<litert::lm::Engine::Session>)session;
@end

// ---------------------------------------------------------------------------
// LRTEngine
// ---------------------------------------------------------------------------

@interface LRTEngine () {
    std::unique_ptr<litert::lm::Engine> _engine;
}
@end

@implementation LRTEngine

+ (nullable instancetype)engineWithConfig:(LRTEngineConfig *)config
                                    error:(NSError **)error {
    LRTEngine *engine = [[LRTEngine alloc] initPrivate];
    if (![engine setupWithConfig:config error:error]) {
        return nil;
    }
    return engine;
}

- (instancetype)initPrivate {
    return [super init];
}

- (BOOL)setupWithConfig:(LRTEngineConfig *)config error:(NSError **)error {
    std::string modelPath = [config.modelPath UTF8String];

    auto modelAssets = litert::lm::ModelAssets::Create(modelPath);
    if (!modelAssets.ok()) {
        if (error) *error = NSErrorFromAbslStatus(modelAssets.status());
        return NO;
    }

    std::optional<litert::lm::Backend> visionBackend = std::nullopt;
    std::optional<litert::lm::Backend> audioBackend = std::nullopt;
    if (config.visionBackend != LRTBackendCPU || config.audioBackend != LRTBackendCPU) {
        // Only set if explicitly configured (non-default)
    }
    // Always pass them so the user can enable multimodal
    visionBackend = BackendFromLRT(config.visionBackend);
    audioBackend = BackendFromLRT(config.audioBackend);

    auto settings = litert::lm::EngineSettings::CreateDefault(
        *modelAssets,
        BackendFromLRT(config.backend),
        visionBackend,
        audioBackend);
    if (!settings.ok()) {
        if (error) *error = NSErrorFromAbslStatus(settings.status());
        return NO;
    }

    if (config.numCpuThreads > 0) {
        settings->GetMutableMainExecutorSettings().SetNumCpuThreads(config.numCpuThreads);
    }
    if (config.benchmark) {
        settings->GetMutableBenchmarkParams(); // enables benchmark
    }

    auto engineResult = litert::lm::EngineFactory::CreateDefault(std::move(*settings));
    if (!engineResult.ok()) {
        if (error) *error = NSErrorFromAbslStatus(engineResult.status());
        return NO;
    }

    _engine = std::move(*engineResult);
    return YES;
}

// -- Session creation -------------------------------------------------------

- (nullable LRTSession *)createSessionWithConfig:(LRTSessionConfig *)config
                                           error:(NSError **)error {
    if (!_engine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    auto sessionConfig = litert::lm::SessionConfig::CreateDefault();
    sessionConfig.SetMaxOutputTokens((int)config.maxOutputTokens);
    sessionConfig.SetVisionModalityEnabled(config.enableVision);
    sessionConfig.SetAudioModalityEnabled(config.enableAudio);

    // Sampler parameters
    auto &sampler = sessionConfig.GetMutableSamplerParams();
    sampler.set_temperature(config.temperature);
    sampler.set_top_k((int)config.topK);
    sampler.set_top_p(config.topP);

    auto session = _engine->CreateSession(sessionConfig);
    if (!session.ok()) {
        if (error) *error = NSErrorFromAbslStatus(session.status());
        return nil;
    }

    return [[LRTSession alloc] initWithSession:std::move(*session)];
}

- (nullable LRTSession *)createSessionWithError:(NSError **)error {
    return [self createSessionWithConfig:[LRTSessionConfig defaultConfig] error:error];
}

// -- Tokenizer access -------------------------------------------------------

- (nullable NSArray<NSNumber *> *)tokenize:(NSString *)text error:(NSError **)error {
    if (!_engine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    const auto &tokenizer = _engine->GetTokenizer();
    auto result = const_cast<litert::lm::Tokenizer &>(tokenizer).TextToTokenIds(
        absl::string_view([text UTF8String], [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]));
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:result->size()];
    for (int id : *result) {
        [ids addObject:@(id)];
    }
    return ids;
}

- (nullable NSString *)detokenize:(NSArray<NSNumber *> *)tokenIds error:(NSError **)error {
    if (!_engine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    std::vector<int> ids;
    ids.reserve(tokenIds.count);
    for (NSNumber *n in tokenIds) {
        ids.push_back(n.intValue);
    }

    const auto &tokenizer = _engine->GetTokenizer();
    auto result = const_cast<litert::lm::Tokenizer &>(tokenizer).TokenIdsToText(ids);
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return @(result->c_str());
}

// -- Executor properties ----------------------------------------------------

- (nullable LRTVisionProperties *)visionPropertiesWithError:(NSError **)error {
    if (!_engine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    auto result = _engine->GetVisionExecutorProperties();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    NSInteger patchShrink = result->patch_num_shrink_factor.value_or(0);
    return [[LRTVisionProperties alloc] initWithTokensPerImage:result->num_tokens_per_image
                                            patchShrinkFactor:patchShrink];
}

- (nullable LRTAudioProperties *)audioPropertiesWithError:(NSError **)error {
    if (!_engine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    auto result = _engine->GetAudioExecutorProperties();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return [[LRTAudioProperties alloc] initWithStreaming:result->is_streaming_model
                                              chunkSize:result->streaming_chunk_size
                                            overlapSize:result->streaming_chunk_overlap_size
                                           shrinkFactor:result->audio_shrink_factor];
}

// -- Lifecycle --------------------------------------------------------------

- (BOOL)waitUntilDone:(NSTimeInterval)timeoutSeconds error:(NSError **)error {
    if (!_engine) return YES;

    auto status = _engine->WaitUntilDone(absl::Seconds(timeoutSeconds));
    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

// -- Internal access for Conversation wrapper --------------------------------

- (litert::lm::Engine *)cppEngine {
    return _engine.get();
}

@end
