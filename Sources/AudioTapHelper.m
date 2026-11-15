#import "AudioTapHelper.h"

@implementation AudioTapHelper

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block
                   error:(NSError * _Nullable * _Nullable)error {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name ?: @"AVAudioNode installTapOnBus raised an Objective-C exception";
            *error = [NSError errorWithDomain:@"AudioTapHelper"
                                         code:-1004
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"NSExceptionName": exception.name ?: @"NSException"
                                     }];
        }
        return NO;
    }
#pragma clang diagnostic pop
}

@end
