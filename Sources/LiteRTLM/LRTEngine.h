#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class LRTSession;
@class LRTConversation;
@class LRTConversationConfig;

/// LRTEngine wraps the LiteRT-LM Engine C++ class.
/// It loads the model and creates sessions / conversations.
/// Create one engine per model; sessions are lightweight.
@interface LRTEngine : NSObject

/// Create an engine with the given configuration.
/// This loads the model into memory and prepares inference resources.
+ (nullable instancetype)engineWithConfig:(LRTEngineConfig *)config
                                    error:(NSError **)error;

// -- Session creation -------------------------------------------------------

/// Create a new session with custom configuration.
- (nullable LRTSession *)createSessionWithConfig:(LRTSessionConfig *)config
                                           error:(NSError **)error;

/// Create a session with default configuration.
- (nullable LRTSession *)createSessionWithError:(NSError **)error;

// -- Tokenizer access -------------------------------------------------------

/// Convert text to token IDs.
- (nullable NSArray<NSNumber *> *)tokenize:(NSString *)text
                                     error:(NSError **)error;

/// Convert token IDs back to text.
- (nullable NSString *)detokenize:(NSArray<NSNumber *> *)tokenIds
                            error:(NSError **)error;

// -- Executor properties ----------------------------------------------------

/// Get properties of the vision executor (if model supports vision).
- (nullable LRTVisionProperties *)visionPropertiesWithError:(NSError **)error;

/// Get properties of the audio executor (if model supports audio).
- (nullable LRTAudioProperties *)audioPropertiesWithError:(NSError **)error;

// -- Lifecycle --------------------------------------------------------------

/// Wait for all async tasks to complete, with a timeout in seconds.
/// Returns NO and sets error if the timeout is reached.
- (BOOL)waitUntilDone:(NSTimeInterval)timeoutSeconds
                error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
