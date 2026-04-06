#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Callback for streaming token output.
/// @param token The next token text. nil when generation is complete or on error.
/// @param error Non-nil if an error occurred.
typedef void (^LRTStreamCallback)(NSString *_Nullable token, NSError *_Nullable error);

/// LRTSession wraps the LiteRT-LM Session C++ class.
/// Each session maintains its own conversation context (KV cache).
@interface LRTSession : NSObject

/// Generate a complete response (blocking).
/// @param input The user prompt/query.
/// @param error Set on failure.
/// @return The full response text, or nil on error.
- (nullable NSString *)generateResponseWithInput:(NSString *)input
                                           error:(NSError **)error;

/// Generate a streaming response (non-blocking).
/// Calls the callback with each token as it is generated.
/// The final call has token=nil and error=nil to signal completion.
/// @param input The user prompt/query.
/// @param callback Called on each token.
/// @param error Set on failure to start.
/// @return YES if generation started successfully.
- (BOOL)generateStreamingResponseWithInput:(NSString *)input
                                  callback:(LRTStreamCallback)callback
                                     error:(NSError **)error;

/// Cancel ongoing inference.
- (void)cancel;

/// Get benchmark info from the last inference run.
/// @param error Set on failure.
/// @return Benchmark info, or nil if unavailable.
- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
