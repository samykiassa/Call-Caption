#import "AudioTapHelper.h"
#import <os/lock.h>

@interface AudioHALListenerToken () {
    os_unfair_lock _lock;
    AudioObjectID _objectID;
    AudioObjectPropertyAddress _address;
    dispatch_queue_t _Nullable _queue;
    AudioObjectPropertyListenerBlock _Nullable _block;
}

- (instancetype)initWithObjectID:(AudioObjectID)objectID
                         address:(AudioObjectPropertyAddress)address
                           queue:(dispatch_queue_t _Nullable)queue
                           block:(AudioObjectPropertyListenerBlock)copiedBlock NS_DESIGNATED_INITIALIZER;

@end

@implementation AudioHALListenerToken

- (instancetype)initWithObjectID:(AudioObjectID)objectID
                         address:(AudioObjectPropertyAddress)address
                           queue:(dispatch_queue_t _Nullable)queue
                           block:(AudioObjectPropertyListenerBlock)copiedBlock {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _objectID = objectID;
        _address = address;
        _queue = queue;
        _block = copiedBlock;
    }
    return self;
}

- (AudioObjectID)objectID {
    return _objectID;
}

- (BOOL)isActive {
    os_unfair_lock_lock(&_lock);
    BOOL active = (_block != nil);
    os_unfair_lock_unlock(&_lock);
    return active;
}

- (OSStatus)invalidate {
    os_unfair_lock_lock(&_lock);
    AudioObjectPropertyListenerBlock block = _block;
    dispatch_queue_t queue = _queue;
    AudioObjectID objectID = _objectID;
    AudioObjectPropertyAddress address = _address;
    _block = nil;
    _queue = nil;
    os_unfair_lock_unlock(&_lock);

    if (block == nil) {
        return noErr;
    }
    return AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block);
}

- (void)dealloc {
    AudioObjectPropertyListenerBlock block = _block;
    dispatch_queue_t queue = _queue;
    AudioObjectID objectID = _objectID;
    AudioObjectPropertyAddress address = _address;
    _block = nil;
    _queue = nil;
    if (block != nil) {
        (void)AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block);
    }
}

@end

@implementation AudioTapHelper

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AudioTapBufferHandler)block
                   error:(NSError * _Nullable * _Nullable)error {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[AudioTapHelper] Exception installing tap (%@): %@",
              exception.name ?: @"NSException",
              exception.reason ?: @"unknown");
        if (error != NULL) {
            NSString *defaultReason = [[NSBundle mainBundle] localizedStringForKey:@"audio.error.mic_tap_install"
                                                                           value:@"Failed to install microphone audio tap"
                                                                           table:nil];
            *error = [NSError errorWithDomain:@"AudioTapHelper"
                                         code:-1004
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: defaultReason,
                                         @"NSExceptionName": exception.name ?: @"NSException"
                                     }];
        }
        return NO;
    }
#pragma clang diagnostic pop
}

+ (AudioHALListenerToken * _Nullable)addPropertyListenerOnObject:(AudioObjectID)objectID
                                                         address:(const AudioObjectPropertyAddress *)address
                                                           queue:(dispatch_queue_t _Nullable)queue
                                                           block:(AudioHALPropertyListenerHandler)block
                                                          status:(OSStatus * _Nullable)outStatus {
    if (address == NULL || block == nil) {
        if (outStatus != NULL) {
            *outStatus = kAudioHardwareIllegalOperationError;
        }
        return nil;
    }

    AudioObjectPropertyListenerBlock copiedBlock = [block copy];
    AudioObjectPropertyAddress localAddress = *address;
    OSStatus status = AudioObjectAddPropertyListenerBlock(objectID, &localAddress, queue, copiedBlock);
    if (outStatus != NULL) {
        *outStatus = status;
    }
    if (status != noErr) {
        return nil;
    }
    return [[AudioHALListenerToken alloc] initWithObjectID:objectID
                                                   address:localAddress
                                                     queue:queue
                                                     block:copiedBlock];
}

+ (OSStatus)removePropertyListener:(AudioHALListenerToken *)token {
    if (token == nil) {
        return noErr;
    }
    return [token invalidate];
}

@end
