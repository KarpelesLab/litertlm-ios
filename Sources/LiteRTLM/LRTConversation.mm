#import "LRTConversation.h"
#import "LRTEngine.h"
#import "LRTTypes+Internal.h"

#include "runtime/engine/engine.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/conversation/conversation.h"
#include "runtime/conversation/io_types.h"
#include "runtime/components/constrained_decoding/constraint_provider_config.h"

#include <memory>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"

static NSString *const LRTErrorDomain = @"com.litert-lm.ios";

static NSError *NSErrorFromAbslStatus(const absl::Status &status) {
    return [NSError errorWithDomain:LRTErrorDomain
                               code:(NSInteger)status.raw_code()
                           userInfo:@{
        NSLocalizedDescriptionKey: @(std::string(status.message()).c_str())
    }];
}

// ---------------------------------------------------------------------------
// JSON bridge helpers
// ---------------------------------------------------------------------------

static nlohmann::ordered_json NlohmannFromNSDictionary(NSDictionary *dict);
static nlohmann::ordered_json NlohmannFromNSArray(NSArray *array);

static nlohmann::ordered_json NlohmannFromNSObject(id obj) {
    if ([obj isKindOfClass:[NSString class]]) {
        return nlohmann::ordered_json(std::string([obj UTF8String]));
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = obj;
        // Check for boolean
        if (strcmp([num objCType], @encode(BOOL)) == 0 ||
            strcmp([num objCType], @encode(char)) == 0) {
            return nlohmann::ordered_json(num.boolValue);
        }
        if (strcmp([num objCType], @encode(double)) == 0 ||
            strcmp([num objCType], @encode(float)) == 0) {
            return nlohmann::ordered_json(num.doubleValue);
        }
        return nlohmann::ordered_json(num.longLongValue);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        return NlohmannFromNSDictionary(obj);
    } else if ([obj isKindOfClass:[NSArray class]]) {
        return NlohmannFromNSArray(obj);
    } else if ([obj isKindOfClass:[NSNull class]]) {
        return nlohmann::ordered_json(nullptr);
    }
    return nlohmann::ordered_json(std::string([[obj description] UTF8String]));
}

static nlohmann::ordered_json NlohmannFromNSDictionary(NSDictionary *dict) {
    nlohmann::ordered_json j = nlohmann::ordered_json::object();
    for (NSString *key in dict) {
        j[std::string([key UTF8String])] = NlohmannFromNSObject(dict[key]);
    }
    return j;
}

static nlohmann::ordered_json NlohmannFromNSArray(NSArray *array) {
    nlohmann::ordered_json j = nlohmann::ordered_json::array();
    for (id item in array) {
        j.push_back(NlohmannFromNSObject(item));
    }
    return j;
}

static NSDictionary *NSDictionaryFromNlohmann(const nlohmann::ordered_json &j) {
    if (!j.is_object()) return @{};
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (auto it = j.begin(); it != j.end(); ++it) {
        NSString *key = @(it.key().c_str());
        if (it.value().is_string()) {
            dict[key] = @(it.value().get<std::string>().c_str());
        } else if (it.value().is_number_integer()) {
            dict[key] = @(it.value().get<int64_t>());
        } else if (it.value().is_number_float()) {
            dict[key] = @(it.value().get<double>());
        } else if (it.value().is_boolean()) {
            dict[key] = @(it.value().get<bool>());
        } else if (it.value().is_null()) {
            dict[key] = [NSNull null];
        } else if (it.value().is_object()) {
            dict[key] = NSDictionaryFromNlohmann(it.value());
        } else if (it.value().is_array()) {
            NSMutableArray *arr = [NSMutableArray array];
            for (const auto &elem : it.value()) {
                if (elem.is_object()) {
                    [arr addObject:NSDictionaryFromNlohmann(elem)];
                } else if (elem.is_string()) {
                    [arr addObject:@(elem.get<std::string>().c_str())];
                } else {
                    [arr addObject:@(elem.dump().c_str())];
                }
            }
            dict[key] = arr;
        } else {
            dict[key] = @(it.value().dump().c_str());
        }
    }
    return dict;
}

// ---------------------------------------------------------------------------
// LRTConversationConfig
// ---------------------------------------------------------------------------

@implementation LRTConversationConfig

+ (instancetype)defaultConfig {
    LRTConversationConfig *c = [[LRTConversationConfig alloc] init];
    c.enableConstrainedDecoding = NO;
    c.prefillPrefaceOnInit = NO;
    c.maxOutputTokens = 0;
    c.enableVision = NO;
    c.enableAudio = NO;
    c.temperature = 0.8f;
    c.topK = 40;
    c.topP = 0.95f;
    return c;
}

@end

// ---------------------------------------------------------------------------
// Constraint helper
// ---------------------------------------------------------------------------

static litert::lm::LlgConstraintType LlgTypeFromObjC(LRTConstraintType type) {
    switch (type) {
        case LRTConstraintTypeRegex:      return litert::lm::LlgConstraintType::kRegex;
        case LRTConstraintTypeJsonSchema: return litert::lm::LlgConstraintType::kJsonSchema;
        case LRTConstraintTypeLark:       return litert::lm::LlgConstraintType::kLark;
    }
    return litert::lm::LlgConstraintType::kJsonSchema;
}

static litert::lm::OptionalArgs OptionalArgsWithConstraint(
    LRTConstraint *_Nullable constraint) {
    litert::lm::OptionalArgs args;
    if (constraint) {
        litert::lm::LlGuidanceConstraintArg constraintArg;
        constraintArg.constraint_type = LlgTypeFromObjC(constraint.type);
        constraintArg.constraint_string = std::string([constraint.definition UTF8String]);
        args.decoding_constraint = litert::lm::ConstraintArg(constraintArg);
    }
    return args;
}

// ---------------------------------------------------------------------------
// Internal: access C++ engine from LRTEngine
// ---------------------------------------------------------------------------

@interface LRTEngine ()
- (litert::lm::Engine *)cppEngine;
@end

// ---------------------------------------------------------------------------
// LRTConversation
// ---------------------------------------------------------------------------

@interface LRTConversation () {
    std::unique_ptr<litert::lm::Conversation> _conversation;
}
@end

@implementation LRTConversation

+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                          error:(NSError **)error {
    return [self conversationWithEngine:engine config:[LRTConversationConfig defaultConfig] error:error];
}

+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                         config:(LRTConversationConfig *)config
                                          error:(NSError **)error {
    litert::lm::Engine *cppEngine = [engine cppEngine];
    if (!cppEngine) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        return nil;
    }

    // Build ConversationConfig using the builder
    auto builder = litert::lm::ConversationConfig::Builder();

    // Session config
    auto sessionConfig = litert::lm::SessionConfig::CreateDefault();
    if (config.maxOutputTokens > 0) {
        sessionConfig.SetMaxOutputTokens((int)config.maxOutputTokens);
    }
    sessionConfig.SetVisionModalityEnabled(config.enableVision);
    sessionConfig.SetAudioModalityEnabled(config.enableAudio);

    auto &sampler = sessionConfig.GetMutableSamplerParams();
    sampler.set_temperature(config.temperature);
    sampler.set_k((int)config.topK);
    sampler.set_p(config.topP);

    builder.SetSessionConfig(sessionConfig);

    // Preface (system prompt + tools)
    if (config.systemPrompt || config.tools) {
        litert::lm::JsonPreface jsonPreface;

        if (config.systemPrompt) {
            nlohmann::ordered_json messages = nlohmann::ordered_json::array();
            nlohmann::ordered_json sysMsg = nlohmann::ordered_json::object();
            sysMsg["role"] = "system";
            sysMsg["content"] = std::string([config.systemPrompt UTF8String]);
            messages.push_back(sysMsg);
            jsonPreface.messages = messages;
        }

        if (config.tools) {
            jsonPreface.tools = NlohmannFromNSArray(config.tools);
        }

        builder.SetPreface(litert::lm::Preface(jsonPreface));
    }

    builder.SetEnableConstrainedDecoding(config.enableConstrainedDecoding);
    builder.SetPrefillPrefaceOnInit(config.prefillPrefaceOnInit);

    // Channels
    if (config.channels.count > 0) {
        std::vector<litert::lm::Channel> cppChannels;
        for (LRTChannel *ch in config.channels) {
            litert::lm::Channel c;
            c.channel_name = std::string([ch.name UTF8String]);
            c.start = std::string([ch.startDelimiter UTF8String]);
            c.end = std::string([ch.endDelimiter UTF8String]);
            cppChannels.push_back(std::move(c));
        }
        builder.SetChannels(cppChannels);
    }

    // Constrained decoding config (LlGuidance)
    if (config.enableConstrainedDecoding) {
        litert::lm::LlGuidanceConfig llgConfig;
        builder.SetConstraintProviderConfig(
            litert::lm::ConstraintProviderConfig(llgConfig));
    }

    auto convConfigResult = builder.Build(*cppEngine);
    if (!convConfigResult.ok()) {
        if (error) *error = NSErrorFromAbslStatus(convConfigResult.status());
        return nil;
    }

    auto conversation = litert::lm::Conversation::Create(*cppEngine, *convConfigResult);
    if (!conversation.ok()) {
        if (error) *error = NSErrorFromAbslStatus(conversation.status());
        return nil;
    }

    LRTConversation *obj = [[LRTConversation alloc] initPrivate];
    obj->_conversation = std::move(*conversation);
    return obj;
}

- (instancetype)initPrivate {
    return [super init];
}

// -- Messaging --------------------------------------------------------------

- (nullable NSString *)sendMessage:(NSString *)message error:(NSError **)error {
    return [self sendMessage:message constraint:nil error:error];
}

- (nullable NSString *)sendMessage:(NSString *)message
                        constraint:(LRTConstraint *)constraint
                             error:(NSError **)error {
    if (!_conversation) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Conversation not initialized"}];
        return nil;
    }

    nlohmann::ordered_json msgJson = nlohmann::ordered_json::object();
    msgJson["role"] = "user";
    msgJson["content"] = std::string([message UTF8String]);
    litert::lm::Message msg = litert::lm::JsonMessage(msgJson);

    auto optArgs = OptionalArgsWithConstraint(constraint);
    auto result = _conversation->SendMessage(msg, std::move(optArgs));
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    const auto &responseJson = std::get<litert::lm::JsonMessage>(*result);
    if (responseJson.contains("content") && responseJson["content"].is_string()) {
        return @(responseJson["content"].get<std::string>().c_str());
    }
    return @(responseJson.dump().c_str());
}

- (BOOL)sendMessageAsync:(NSString *)message
                callback:(LRTConversationStreamCallback)callback
                   error:(NSError **)error {
    return [self sendMessageAsync:message constraint:nil callback:callback error:error];
}

- (BOOL)sendMessageAsync:(NSString *)message
               constraint:(LRTConstraint *)constraint
                 callback:(LRTConversationStreamCallback)callback
                    error:(NSError **)error {
    if (!_conversation) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Conversation not initialized"}];
        return NO;
    }

    nlohmann::ordered_json msgJson = nlohmann::ordered_json::object();
    msgJson["role"] = "user";
    msgJson["content"] = std::string([message UTF8String]);
    litert::lm::Message msg = litert::lm::JsonMessage(msgJson);

    auto optArgs = OptionalArgsWithConstraint(constraint);
    LRTConversationStreamCallback callbackCopy = [callback copy];

    auto status = _conversation->SendMessageAsync(
        msg,
        [callbackCopy](absl::StatusOr<litert::lm::Message> result) {
            if (!result.ok()) {
                NSError *err = NSErrorFromAbslStatus(result.status());
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, err);
                });
                return;
            }

            const auto &responseJson = std::get<litert::lm::JsonMessage>(*result);
            std::string content;
            if (responseJson.contains("content") && responseJson["content"].is_string()) {
                content = responseJson["content"].get<std::string>();
            }

            if (content.empty()) {
                // Empty content signals completion
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(nil, nil);
                });
            } else {
                NSString *token = @(content.c_str());
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackCopy(token, nil);
                });
            }
        },
        std::move(optArgs));

    if (!status.ok()) {
        if (error) *error = NSErrorFromAbslStatus(status);
        return NO;
    }
    return YES;
}

// -- History ----------------------------------------------------------------

- (NSArray<NSDictionary *> *)history {
    if (!_conversation) return @[];

    auto historyVec = _conversation->GetHistory();
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:historyVec.size()];

    for (const auto &msg : historyVec) {
        const auto &jsonMsg = std::get<litert::lm::JsonMessage>(msg);
        [result addObject:NSDictionaryFromNlohmann(jsonMsg)];
    }

    return result;
}

// -- Clone / Cancel / Benchmark ---------------------------------------------

- (nullable LRTConversation *)cloneWithError:(NSError **)error {
    if (!_conversation) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Conversation not initialized"}];
        return nil;
    }

    auto result = _conversation->Clone();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    LRTConversation *clone = [[LRTConversation alloc] initPrivate];
    clone->_conversation = std::move(*result);
    return clone;
}

- (void)cancel {
    if (_conversation) {
        _conversation->CancelProcess();
    }
}

- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error {
    if (!_conversation) {
        if (error) *error = [NSError errorWithDomain:LRTErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Conversation not initialized"}];
        return nil;
    }

    auto result = _conversation->GetBenchmarkInfo();
    if (!result.ok()) {
        if (error) *error = NSErrorFromAbslStatus(result.status());
        return nil;
    }

    double ttft = result->GetTimeToFirstToken();

    NSMutableArray<NSNumber *> *prefillTPS = [NSMutableArray array];
    for (uint64_t i = 0; i < result->GetTotalPrefillTurns(); i++) {
        [prefillTPS addObject:@(result->GetPrefillTokensPerSec((int)i))];
    }

    NSMutableArray<NSNumber *> *decodeTPS = [NSMutableArray array];
    for (uint64_t i = 0; i < result->GetTotalDecodeTurns(); i++) {
        [decodeTPS addObject:@(result->GetDecodeTokensPerSec((int)i))];
    }

    return [[LRTBenchmarkInfo alloc] initWithTimeToFirstToken:ttft
                                              prefillTPSArray:prefillTPS
                                               decodeTPSArray:decodeTPS];
}

@end
