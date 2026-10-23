#import "AudioTapHelper.h"

@implementation AudioTapHelper

+ (void)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
#pragma clang diagnostic pop
}

@end
