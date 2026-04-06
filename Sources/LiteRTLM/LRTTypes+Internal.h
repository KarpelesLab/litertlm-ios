// Internal init methods for LRTTypes. Not part of the public API.
// Used by LRTEngine.mm, LRTSession.mm, and LRTConversation.mm.

#import "LRTTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface LRTVisionProperties ()
- (instancetype)initWithTokensPerImage:(NSInteger)tokensPerImage
                    patchShrinkFactor:(NSInteger)patchShrink;
@end

@interface LRTAudioProperties ()
- (instancetype)initWithStreaming:(BOOL)streaming
                       chunkSize:(NSInteger)chunkSize
                     overlapSize:(NSInteger)overlapSize
                    shrinkFactor:(NSInteger)shrinkFactor;
@end

@interface LRTBenchmarkInfo ()
- (instancetype)initWithTimeToFirstToken:(double)ttft
                          prefillTPSArray:(NSArray<NSNumber *> *)prefillTPS
                           decodeTPSArray:(NSArray<NSNumber *> *)decodeTPS;
@end

@interface LRTResponse ()
- (instancetype)initWithText:(NSString *)text
                   taskState:(LRTTaskState)taskState
               benchmarkInfo:(nullable LRTBenchmarkInfo *)benchmarkInfo
                      scores:(nullable NSArray<NSNumber *> *)scores;
@end

NS_ASSUME_NONNULL_END
