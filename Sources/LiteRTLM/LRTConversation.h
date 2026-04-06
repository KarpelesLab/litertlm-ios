#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class LRTEngine;

/// Configuration for creating a conversation.
/// Uses a builder pattern — set properties then call buildWithEngine:error:.
@interface LRTConversationConfig : NSObject

/// System prompt / preface text. Set before building.
@property (nonatomic, copy, nullable) NSString *systemPrompt;

/// Tool definitions as a JSON array of tool objects.
/// Each tool should have "name", "description", "parameters" keys.
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *tools;

/// Whether to enable constrained decoding (for function calling).
@property (nonatomic) BOOL enableConstrainedDecoding;

/// Prefill the system prompt on init (faster first response, slower init).
@property (nonatomic) BOOL prefillPrefaceOnInit;

/// Max output tokens per response. 0 = model default.
@property (nonatomic) NSInteger maxOutputTokens;

/// Enable vision modality for this conversation.
@property (nonatomic) BOOL enableVision;

/// Enable audio modality for this conversation.
@property (nonatomic) BOOL enableAudio;

/// Sampling temperature.
@property (nonatomic) float temperature;

/// Top-K sampling.
@property (nonatomic) NSInteger topK;

/// Top-P (nucleus) sampling.
@property (nonatomic) float topP;

+ (instancetype)defaultConfig;

@end

/// Callback for streaming conversation responses.
/// @param token Next text fragment. nil when complete or on error.
/// @param error Non-nil if an error occurred.
typedef void (^LRTConversationStreamCallback)(NSString *_Nullable token, NSError *_Nullable error);

/// LRTConversation wraps the LiteRT-LM Conversation C++ class.
/// Provides a higher-level chat interface with prompt template handling,
/// conversation history, and optional tool use.
@interface LRTConversation : NSObject

/// Create a conversation with default configuration.
+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                          error:(NSError **)error;

/// Create a conversation with custom configuration.
+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                         config:(LRTConversationConfig *)config
                                          error:(NSError **)error;

/// Send a text message and get the complete response (blocking).
- (nullable NSString *)sendMessage:(NSString *)message
                             error:(NSError **)error;

/// Send a text message with streaming response (non-blocking).
/// Callback receives tokens as they are generated.
- (BOOL)sendMessageAsync:(NSString *)message
                callback:(LRTConversationStreamCallback)callback
                   error:(NSError **)error;

/// Get the conversation history as an array of JSON-compatible dictionaries.
/// Each entry has "role" and "content" keys.
@property (nonatomic, readonly) NSArray<NSDictionary *> *history;

/// Clone this conversation. The clone has the same history and context.
- (nullable LRTConversation *)cloneWithError:(NSError **)error;

/// Cancel ongoing inference.
- (void)cancel;

/// Get benchmark info from the last inference run.
- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
