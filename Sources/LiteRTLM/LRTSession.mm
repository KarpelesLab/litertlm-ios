#import "LRTSession.h"
#import "LRTTypes+Internal.h"

#include "runtime/engine/engine.h"
#include "runtime/engine/io_types.h"

#include <memory>
#include <string>
#include <vector>

static NSString *const LRTErrorDomain = @"com.litert-lm.ios";

static NSError *NSErrorFromAbslStatus(const absl::Status &status) {
    return [NSError errorWithDomain:LRTErrorDomain
                               code:(NSInteger)status.raw_code()
                           userInfo:@{
        NSLocalizedDescriptionKey: @(std::string(status.message()).c_str())
    }];
}

static NSError *NotInitializedError() {
    return [NSError errorWithDomain:LRTErrorDomain code:-1
                           userInfo:@{NSLocalizedDescriptionKey: @"Session not initialized"}];
}

static LRTTaskState TaskStateFromCpp(litert::lm::TaskState s) {
    switch (s) {
        case litert::lm::TaskState::kCreated:    return LRTTaskStateCreated;
        case litert::lm::TaskState::kQueued:     return LRTTaskStateQueued;
        case litert::lm::TaskState::kProcessing: return LRTTaskStateProcessing;
        case litert::lm::TaskState::kDone:       return LRTTaskStateDone;
        case litert::lm::TaskState::kMaxNumTokensReached: return LRTTaskStateMaxTokensReached;
        case litert::lm::TaskState::kFailed:     return LRTTaskStateFailed;
        case litert::lm::TaskState::kCancelled:  return LRTTaskStateCancelled;
        default:                                  return LRTTaskStateUnknown;
    }
}

// ---------------------------------------------------------------------------
// Convert ObjC content array to C++ InputData vector
// ---------------------------------------------------------------------------

static std::vector<litert::lm::InputData> InputDataFromObjC(NSArray *contents) {
    std::vector<litert::lm::InputData> result;
    result.reserve(contents.count);
    for (id item in contents) {
        if ([item isKindOfClass:[LRTInputText class]]) {
            LRTInputText *t = item;
            result.push_back(litert::lm::InputText(std::string([t.text UTF8String])));
        } else if ([item isKindOfClass:[LRTInputImage class]]) {
            LRTInputImage *img = item;
            std::string bytes(static_cast<const char *>(img.imageData.bytes), img.imageData.length);
            result.push_back(litert::lm::InputImage(std::move(bytes)));
        } else if ([item isKindOfClass:[LRTInputAudio class]]) {
            LRTInputAudio *audio = item;
            std::string bytes(static_cast<const char *>(audio.audioData.bytes), audio.audioData.length);
            result.push_back(litert::lm::InputAudio(std::move(bytes)));
        }
    }
    return result;
}

static NSString *TextFromResponses(const litert::lm::Responses &responses) {
    std::string text;
    for (const auto &t : responses.GetTexts()) {
        text += t;
    }
    return @(text.c_str());
}

// ---------------------------------------------------------------------------
// Build LRTBenchmarkInfo from C++
// ---------------------------------------------------------------------------

static LRTBenchmarkInfo *BenchmarkInfoFromCpp(const litert::lm::BenchmarkInfo &info) {
    double ttft = info.GetTimeToFirstToken();

    NSMutableArray<NSNumber *> *prefillTPS = [NSMutableArray array];
    for (uint64_t i = 0; i < info.GetTotalPrefillTurns(); i++) {
        [prefillTPS addObject:@(info.GetPrefillTokensPerSec((int)i))];
    }

    NSMutableArray<NSNumber *> *decodeTPS = [NSMutableArray array];
    for (uint64_t i = 0; i < info.GetTotalDecodeTurns(); i++) {
        [decodeTPS addObject:@(info.GetDecodeTokensPerSec((int)i))];
    }

    return [[LRTBenchmarkInfo alloc] initWithTimeToFirstToken:ttft
                                              prefillTPSArray:prefillTPS
                                               decodeTPSArray:decodeTPS];
}

// ---------------------------------------------------------------------------
// LRTSession
// ---------------------------------------------------------------------------

@interface LRTSession () {
    std::unique_ptr<litert::lm::Engine::Session> _session;
}
@end

@implementation LRTSession

- (instancetype)initWithSession:(std::unique_ptr<litert::lm::Engine::Session>)session {
    self = [super init];
    if (self) {
        _session = std::move(session);
    }
    return self;
}

// -- Text generation (simple) -----------------------------------------------

- (nullable NSString *)generateResponseWithInput:(NSString *)input
                                           error:(NSError **)error {
    NSArray *contents = @[[LRTInputText inputWithText:input]];
    return [self generateResponseWithContents:contents error:error];
}

- (BOOL)generateStreamingResponseWithInput:(NSString *)input
                                  callback:(LRTStreamCallback)callback
                                     error:(NSError **)error {
    NSArray *contents = @[[LRTInputText inputWithText:input]];
    return [self generateStreamingResponseWithContents:contents callback:callback error:error];
}

// -- Multimodal generation --------------------------------------------------

- (nullable NSString *)generateResponseWithContents:(NSArray *)contents
                                              error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    auto inputData = InputDataFromObjC(contents);
    auto result = _session->GenerateContent(inputData);
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return TextFromResponses(*result);
}

- (BOOL)generateStreamingResponseWithContents:(NSArray *)contents
                                     callback:(LRTStreamCallback)callback
                                        error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return NO;
    }

    auto inputData = InputDataFromObjC(contents);
    LRTStreamCallback callbackCopy = [callback copy];

    auto status = _session->GenerateContentStream(
        inputData,
        [callbackCopy](absl::StatusOr<litert::lm::Responses> result) {
            if (!result.ok()) {
                NSError *err = NSErrorFromAbslStatus(result.status());
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, err);
                });
                return;
            }

            if (result->GetTexts().empty()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, nil);
                });
                return;
            }

            NSString *token = TextFromResponses(*result);
            dispatch_async(dispatch_get_main_queue(), ^{
                callbackCopy(token, nil);
            });
        });

    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

- (BOOL)generateStreamingResponseWithContents:(NSArray *)contents
                                 decodeConfig:(LRTDecodeConfig *)decodeConfig
                                     callback:(LRTStreamCallback)callback
                                        error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return NO;
    }

    auto inputData = InputDataFromObjC(contents);
    LRTStreamCallback callbackCopy = [callback copy];

    auto dc = litert::lm::DecodeConfig::CreateDefault();
    if (decodeConfig.maxOutputTokens > 0) {
        dc.SetMaxOutputTokens((int)decodeConfig.maxOutputTokens);
    }

    auto status = _session->GenerateContentStream(
        inputData,
        [callbackCopy](absl::StatusOr<litert::lm::Responses> result) {
            if (!result.ok()) {
                NSError *err = NSErrorFromAbslStatus(result.status());
                dispatch_async(dispatch_get_main_queue(), ^{ callbackCopy(nil, err); });
                return;
            }
            if (result->GetTexts().empty()) {
                dispatch_async(dispatch_get_main_queue(), ^{ callbackCopy(nil, nil); });
                return;
            }
            NSString *token = TextFromResponses(*result);
            dispatch_async(dispatch_get_main_queue(), ^{ callbackCopy(token, nil); });
        },
        dc);

    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

// -- Low-level prefill / decode ---------------------------------------------

- (BOOL)runPrefillWithContents:(NSArray *)contents error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return NO;
    }

    auto inputData = InputDataFromObjC(contents);
    auto status = _session->RunPrefill(inputData);
    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

- (nullable NSString *)runDecodeWithError:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    auto result = _session->RunDecode();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }
    return TextFromResponses(*result);
}

- (nullable NSString *)runDecodeWithConfig:(LRTDecodeConfig *)config error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    auto dc = litert::lm::DecodeConfig::CreateDefault();
    if (config.maxOutputTokens > 0) {
        dc.SetMaxOutputTokens((int)config.maxOutputTokens);
    }

    auto result = _session->RunDecode(dc);
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }
    return TextFromResponses(*result);
}

// -- Text scoring -----------------------------------------------------------

- (nullable NSArray<NSNumber *> *)scoreTexts:(NSArray<NSString *> *)texts
                                       error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    std::vector<absl::string_view> cppTexts;
    // Keep std::string alive for the duration of the call
    std::vector<std::string> storage;
    storage.reserve(texts.count);
    for (NSString *t in texts) {
        storage.emplace_back([t UTF8String]);
        cppTexts.push_back(storage.back());
    }

    auto result = _session->RunTextScoring(cppTexts, /*store_token_lengths=*/false);
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    NSMutableArray<NSNumber *> *scores = [NSMutableArray arrayWithCapacity:result->GetScores().size()];
    for (float s : result->GetScores()) {
        [scores addObject:@(s)];
    }
    return scores;
}

// -- Session cloning & checkpoints ------------------------------------------

- (nullable LRTSession *)cloneWithError:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    auto result = _session->Clone();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return [[LRTSession alloc] initWithSession:std::move(*result)];
}

- (BOOL)saveCheckpoint:(NSString *)label error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return NO;
    }

    auto status = _session->SaveCheckpoint(absl::string_view([label UTF8String]));
    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

- (BOOL)rewindToCheckpoint:(NSString *)label error:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return NO;
    }

    auto status = _session->RewindToCheckpoint(absl::string_view([label UTF8String]));
    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

- (NSInteger)currentStepWithError:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return -1;
    }

    auto result = _session->GetCurrentStep();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return -1;
    }
    return *result;
}

// -- Lifecycle --------------------------------------------------------------

- (void)cancel {
    if (_session) {
        _session->CancelProcess();
    }
}

- (BOOL)waitUntilDoneWithError:(NSError **)error {
    if (!_session) return YES;

    auto status = _session->WaitUntilDone();
    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error {
    if (!_session) {
        if (error) *error = NotInitializedError();
        return nil;
    }

    auto result = _session->GetBenchmarkInfo();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return BenchmarkInfoFromCpp(*result);
}

@end
