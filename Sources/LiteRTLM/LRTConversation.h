#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class LRTEngine;

/// Configuration for creating a conversation.
@interface LRTConversationConfig : NSObject

/// System prompt / preface text.
@property (nonatomic, copy, nullable) NSString *systemPrompt;

/// Tool definitions as a JSON array of tool objects.
/// Each tool should have "name", "description", "parameters" keys.
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *tools;

/// Whether to enable constrained decoding (for function calling / structured output).
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

/// Output channels for separating model output into named streams.
/// For example, a "thinking" channel with <thinking>...</thinking> delimiters.
@property (nonatomic, strong, nullable) NSArray<LRTChannel *> *channels;

/// Whether to filter channel content from the KV cache.
@property (nonatomic) BOOL filterChannelContentFromKvCache;

+ (instancetype)defaultConfig;

@end

/// Callback for streaming conversation responses.
/// @param token Next text fragment. nil when complete or on error.
/// @param error Non-nil if an error occurred.
typedef void (^LRTConversationStreamCallback)(NSString *_Nullable token, NSError *_Nullable error);

/// LRTConversation wraps the LiteRT-LM Conversation C++ class.
/// Provides a higher-level chat interface with prompt template handling,
/// conversation history, and optional tool use / constrained decoding.
@interface LRTConversation : NSObject

/// Create a conversation with default configuration.
+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                          error:(NSError **)error;

/// Create a conversation with custom configuration.
+ (nullable instancetype)conversationWithEngine:(LRTEngine *)engine
                                         config:(LRTConversationConfig *)config
                                          error:(NSError **)error;

// -- Messaging --------------------------------------------------------------

/// Send a text message and get the complete response (blocking).
- (nullable NSString *)sendMessage:(NSString *)message
                             error:(NSError **)error;

/// Send a text message with a constraint on the output format (blocking).
/// For example, pass [LRTConstraint jsonSchemaConstraint:schema] to get valid JSON.
- (nullable NSString *)sendMessage:(NSString *)message
                        constraint:(LRTConstraint *)constraint
                             error:(NSError **)error;

/// Send a text message with streaming response (non-blocking).
- (BOOL)sendMessageAsync:(NSString *)message
                callback:(LRTConversationStreamCallback)callback
                   error:(NSError **)error;

/// Send a text message with streaming and a constraint.
- (BOOL)sendMessageAsync:(NSString *)message
               constraint:(nullable LRTConstraint *)constraint
                 callback:(LRTConversationStreamCallback)callback
                    error:(NSError **)error;

// -- History & state --------------------------------------------------------

/// Get the conversation history as an array of JSON-compatible dictionaries.
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
