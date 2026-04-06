#import <Foundation/Foundation.h>
#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class LRTSession;

/// LRTEngine wraps the LiteRT-LM Engine C++ class.
/// It is responsible for loading the model and creating sessions.
/// Create one engine per model; sessions are lightweight.
@interface LRTEngine : NSObject

/// Create an engine with the given configuration.
/// This loads the model into memory and prepares inference resources.
/// @param config Engine configuration (model path, backend, etc.)
/// @param error Set on failure.
/// @return A configured engine, or nil on error.
+ (nullable instancetype)engineWithConfig:(LRTEngineConfig *)config
                                    error:(NSError **)error;

/// Create a new session for conversation.
/// Sessions are lightweight and maintain their own conversation state.
/// @param config Session configuration (temperature, topK, etc.)
/// @param error Set on failure.
/// @return A session, or nil on error.
- (nullable LRTSession *)createSessionWithConfig:(LRTSessionConfig *)config
                                           error:(NSError **)error;

/// Create a session with default configuration.
- (nullable LRTSession *)createSessionWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
