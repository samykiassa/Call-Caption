#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AudioTapBufferHandler)(AVAudioPCMBuffer *buffer, AVAudioTime *when) NS_SWIFT_SENDABLE;
typedef void (^AudioHALPropertyListenerHandler)(UInt32 numberAddresses, const AudioObjectPropertyAddress *addresses) NS_SWIFT_SENDABLE;

/// Opaque, Sendable token owning the exact heap-copied Objective-C block pointer registered with CoreAudio.
/// Using this token guarantees AudioObjectRemovePropertyListenerBlock matches by block pointer identity.
NS_SWIFT_SENDABLE
@interface AudioHALListenerToken : NSObject

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) AudioObjectID objectID;
@property (nonatomic, readonly) BOOL isActive;

/// Unregisters the underlying CoreAudio property listener if still active. Idempotent and thread-safe.
- (OSStatus)invalidate;

@end

@interface AudioTapHelper : NSObject

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AudioTapBufferHandler)block
                   error:(NSError * _Nullable * _Nullable)error;

/// Registers a CoreAudio property listener using a single heap-copied Objective-C block so removal matches
/// by pointer identity. Returns nil on CoreAudio error (writing the status to outStatus when non-NULL).
+ (AudioHALListenerToken * _Nullable)addPropertyListenerOnObject:(AudioObjectID)objectID
                                                         address:(const AudioObjectPropertyAddress *)address
                                                           queue:(dispatch_queue_t _Nullable)queue
                                                           block:(AudioHALPropertyListenerHandler)block
                                                          status:(OSStatus * _Nullable)outStatus;

/// Unregisters a listener token previously returned by +addPropertyListenerOnObject:address:queue:block:status:.
+ (OSStatus)removePropertyListener:(AudioHALListenerToken *)token;

@end

NS_ASSUME_NONNULL_END
