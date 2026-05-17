#import "HarcAudioObjC.h"

BOOL HarcInstallTapOnAudioNode(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    void (^block)(AVAudioPCMBuffer *buffer, AVAudioTime *when),
    NSError **error
) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"Unknown AVAudioEngine exception";
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{
                NSLocalizedDescriptionKey: reason,
                @"HarcExceptionName": exception.name ?: @"NSException"
            };
            *error = [NSError errorWithDomain:@"com.harc.audio.tap"
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}
