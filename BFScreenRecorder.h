//
//  BFScreenRecorder.h
//  BFViewDebugger
//
//  Created by Sachin Kesiraju on 12/19/16.
//  Copyright © 2016 Sachin Kesiraju. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BFScreenRecorder;

@protocol BFScreenRecorderDelegate <NSObject>
- (void) screenRecorderDidStartRecording:(BFScreenRecorder *) recorder;
- (void) screenRecorder:(BFScreenRecorder *) recorder didStopRecordingWithCapturedVideo:(NSURL *) videoURL;
@end

@interface BFScreenRecorder : NSObject

@property (nonatomic, weak) id <BFScreenRecorderDelegate> delegate;
@property (nonatomic) BOOL isRecording;

+ (instancetype) sharedRecorder;
- (void) startRecording;
- (void) stopRecording;

@end

NS_ASSUME_NONNULL_END

