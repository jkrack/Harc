#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL HarcInstallTapOnAudioNode(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    void (^block)(AVAudioPCMBuffer *buffer, AVAudioTime *when),
    NSError **error
);

NS_ASSUME_NONNULL_END
