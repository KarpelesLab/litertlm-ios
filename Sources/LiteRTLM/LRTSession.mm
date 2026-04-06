#import "LRTSession.h"

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

- (nullable NSString *)generateResponseWithInput:(NSString *)input
                                           error:(NSError **)error {
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:LRTErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Session not initialized"}];
        }
        return nil;
    }

    std::string inputStr = [input UTF8String];
    std::vector<litert::lm::InputData> contents;
    contents.push_back(litert::lm::InputText(inputStr));

    auto result = _session->GenerateContent(contents);
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    // Extract text from responses
    std::string outputText;
    for (const auto &response : result->responses) {
        outputText += response.text;
    }

    return @(outputText.c_str());
}

- (BOOL)generateStreamingResponseWithInput:(NSString *)input
                                  callback:(LRTStreamCallback)callback
                                     error:(NSError **)error {
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:LRTErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Session not initialized"}];
        }
        return NO;
    }

    std::string inputStr = [input UTF8String];
    std::vector<litert::lm::InputData> contents;
    contents.push_back(litert::lm::InputText(inputStr));

    // Copy the callback block to ensure it stays alive
    LRTStreamCallback callbackCopy = [callback copy];

    auto status = _session->GenerateContentStream(
        contents,
        [callbackCopy](absl::StatusOr<litert::lm::Responses> result) {
            if (!result.ok()) {
                NSError *err = NSErrorFromAbslStatus(result.status());
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, err);
                });
                return;
            }

            // Empty responses signals completion
            if (result->responses.empty()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, nil);
                });
                return;
            }

            std::string text;
            for (const auto &response : result->responses) {
                text += response.text;
            }

            NSString *token = @(text.c_str());
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

- (void)cancel {
    if (_session) {
        _session->CancelProcess();
    }
}

- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error {
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:LRTErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Session not initialized"}];
        }
        return nil;
    }

    auto result = _session->GetBenchmarkInfo();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    return [[LRTBenchmarkInfo alloc]
        initWithPrefillTPS:result->prefill_tokens_per_second
                 decodeTPS:result->decode_tokens_per_second
            timeToFirstMs:result->time_to_first_token_ms
            prefillTokens:result->prefill_num_tokens
             decodeTokens:result->decode_num_tokens];
}

@end
