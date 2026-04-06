#import "LRTEngine.h"
#import "LRTSession.h"

// C++ headers from LiteRT-LM
#include "runtime/engine/engine.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/conversation/conversation.h"

static NSString *const LRTErrorDomain = @"com.litert-lm.ios";

static NSError *NSErrorFromAbslStatus(const absl::Status &status) {
    return [NSError errorWithDomain:LRTErrorDomain
                               code:(NSInteger)status.raw_code()
                           userInfo:@{
        NSLocalizedDescriptionKey: @(std::string(status.message()).c_str())
    }];
}

@interface LRTSession ()
- (instancetype)initWithSession:(std::unique_ptr<litert::lm::Engine::Session>)session;
@end

@interface LRTEngine () {
    std::unique_ptr<litert::lm::Engine> _engine;
}
@end

@implementation LRTEngine

+ (nullable instancetype)engineWithConfig:(LRTEngineConfig *)config
                                    error:(NSError **)error {
    LRTEngine *engine = [[LRTEngine alloc] init];
    if (![engine setupWithConfig:config error:error]) {
        return nil;
    }
    return engine;
}

- (instancetype)initPrivate {
    return [super init];
}

- (BOOL)setupWithConfig:(LRTEngineConfig *)config error:(NSError **)error {
    // Build EngineSettings from the ObjC config
    std::string modelPath = [config.modelPath UTF8String];

    litert::lm::Backend backend;
    switch (config.backend) {
        case LRTBackendGPU:
            backend = litert::lm::Backend::GPU;
            break;
        case LRTBackendCPU:
        default:
            backend = litert::lm::Backend::CPU;
            break;
    }

    auto modelAssets = litert::lm::ModelAssets::Create(modelPath);
    if (!modelAssets.ok()) {
        if (error) *error = NSErrorFromAbslStatus(modelAssets.status());
        return NO;
    }

    auto settings = litert::lm::EngineSettings::CreateDefault(*modelAssets, backend);
    if (!settings.ok()) {
        if (error) *error = NSErrorFromAbslStatus(settings.status());
        return NO;
    }

    if (config.numCpuThreads > 0) {
        settings->SetNumCpuThreads(config.numCpuThreads);
    }
    if (config.cacheDir) {
        settings->SetCacheDir([config.cacheDir UTF8String]);
    }

    auto engineResult = litert::lm::Engine::CreateEngine(std::move(*settings));
    if (!engineResult.ok()) {
        if (error) *error = NSErrorFromAbslStatus(engineResult.status());
        return NO;
    }

    _engine = std::move(*engineResult);
    return YES;
}

- (nullable LRTSession *)createSessionWithConfig:(LRTSessionConfig *)config
                                           error:(NSError **)error {
    if (!_engine) {
        if (error) {
            *error = [NSError errorWithDomain:LRTErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        }
        return nil;
    }

    litert::lm::SessionConfig sessionConfig;
    sessionConfig.SetTemperature(config.temperature);
    sessionConfig.SetTopK(config.topK);
    sessionConfig.SetTopP(config.topP);
    if (config.maxOutputTokens > 0) {
        sessionConfig.SetMaxOutputTokens((int)config.maxOutputTokens);
    }

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

@end
