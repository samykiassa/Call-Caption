#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioTapHelper : NSObject

+ (void)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block;

@end

NS_ASSUME_NONNULL_END
