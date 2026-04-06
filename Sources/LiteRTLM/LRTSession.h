#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Callback for streaming token output.
/// @param token The next token text fragment. nil when complete or on error.
/// @param error Non-nil if an error occurred.
typedef void (^LRTStreamCallback)(NSString *_Nullable token, NSError *_Nullable error);

/// LRTSession wraps the LiteRT-LM Session C++ class.
/// Each session maintains its own context (KV cache).
@interface LRTSession : NSObject

// -- Text generation (simple) -----------------------------------------------

/// Generate a complete response from a text prompt (blocking).
- (nullable NSString *)generateResponseWithInput:(NSString *)input
                                           error:(NSError **)error;

/// Generate a streaming response from a text prompt (non-blocking).
/// The final callback has token=nil, error=nil to signal completion.
- (BOOL)generateStreamingResponseWithInput:(NSString *)input
                                  callback:(LRTStreamCallback)callback
                                     error:(NSError **)error;

// -- Multimodal generation --------------------------------------------------

/// Generate a response from mixed content (text, images, audio). Blocking.
/// Pass an array of LRTInputText, LRTInputImage, and/or LRTInputAudio.
- (nullable NSString *)generateResponseWithContents:(NSArray<LRTInputContent> *)contents
                                              error:(NSError **)error;

/// Streaming multimodal generation.
- (BOOL)generateStreamingResponseWithContents:(NSArray<LRTInputContent> *)contents
                                     callback:(LRTStreamCallback)callback
                                        error:(NSError **)error;

/// Multimodal generation with custom decode configuration.
- (BOOL)generateStreamingResponseWithContents:(NSArray<LRTInputContent> *)contents
                                 decodeConfig:(LRTDecodeConfig *)decodeConfig
                                     callback:(LRTStreamCallback)callback
                                        error:(NSError **)error;

// -- Low-level prefill / decode ---------------------------------------------

/// Run prefill on the given contents (text/image/audio). Blocking.
/// Use this for fine-grained control over the inference pipeline.
- (BOOL)runPrefillWithContents:(NSArray<LRTInputContent> *)contents
                         error:(NSError **)error;

/// Run decode after prefill. Blocking. Returns the full response.
- (nullable NSString *)runDecodeWithError:(NSError **)error;

/// Run decode with custom decode config. Blocking.
- (nullable NSString *)runDecodeWithConfig:(LRTDecodeConfig *)config
                                     error:(NSError **)error;

// -- Text scoring -----------------------------------------------------------

/// Score target texts against the current context. Returns scores (lower = more likely).
/// The session should have been prefilled first.
- (nullable NSArray<NSNumber *> *)scoreTexts:(NSArray<NSString *> *)texts
                                       error:(NSError **)error;

// -- Session cloning & checkpoints ------------------------------------------

/// Clone this session. The clone shares the conversation context up to this point.
- (nullable LRTSession *)cloneWithError:(NSError **)error;

/// Save a named checkpoint of the current KV cache state.
- (BOOL)saveCheckpoint:(NSString *)label error:(NSError **)error;

/// Rewind to a previously saved checkpoint.
- (BOOL)rewindToCheckpoint:(NSString *)label error:(NSError **)error;

/// Get the current step number.
- (NSInteger)currentStepWithError:(NSError **)error;

// -- Lifecycle --------------------------------------------------------------

/// Cancel ongoing inference. The session remains usable afterwards.
- (void)cancel;

/// Wait for all async tasks on this session to complete.
- (BOOL)waitUntilDoneWithError:(NSError **)error;

/// Get benchmark info from the last inference run.
- (nullable LRTBenchmarkInfo *)benchmarkInfoWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
