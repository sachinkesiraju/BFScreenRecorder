//
//  BFScreenRecorder.m
//  BFViewDebugger
//
//  Created by Sachin Kesiraju on 12/19/16.
//  Copyright © 2016 Sachin Kesiraju. All rights reserved.
//

#import "BFScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <MediaPlayer/MediaPlayer.h>

@interface BFScreenRecorder()

@property (strong, nonatomic) AVAssetWriter *videoWriter;
@property (strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *videoWriterAdapter;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (nonatomic) CVPixelBufferPoolRef outputBufferPool;
@property (nonatomic) CFTimeInterval firstTimeStamp;

//rendering queues
@property (strong, nonatomic) dispatch_queue_t videoRenderQueue;
@property (strong, nonatomic) dispatch_queue_t pixelBufferQueue;
@property (strong, nonatomic) dispatch_semaphore_t frameRenderingSemaphore;
@property (strong, nonatomic) dispatch_semaphore_t pixelAppendingSemaphore;

@end

@implementation BFScreenRecorder

#pragma mark - Init

+ (instancetype) sharedRecorder
{
    static BFScreenRecorder *screenRecorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        screenRecorder = [[self alloc] init];
    });
    return screenRecorder;
}

- (instancetype) init
{
    self = [super init];
    if (self) {
        _pixelBufferQueue = dispatch_queue_create("BFScreenRecorder.pixelBufferQueue", DISPATCH_QUEUE_SERIAL);
        _videoRenderQueue = dispatch_queue_create("BFScreenRecorder.videoRenderQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_videoRenderQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendingSemaphore = dispatch_semaphore_create(1);
        [self setupVideoWriter];
    }
    return self;
}

#pragma mark - Recording

- (void) startRecording
{
    if (!self.isRecording) {
        [self videoWriterStartRecording];
        self.isRecording = (self.videoWriter.status == AVAssetWriterStatusWriting);
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        if ([self.delegate respondsToSelector:@selector(screenRecorderDidStartRecording:)]) {
            [self.delegate screenRecorderDidStartRecording:self];
        }
    }
}

- (void) stopRecording
{
    if (self.isRecording) {
        self.isRecording = !self.isRecording;
        [self.displayLink removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self completeRecordingSessionWithCompletion:^(NSURL *videoURL) {
            [self saveVideoToPhotoLibrary:videoURL]; //save video to camera roll
            if ([self.delegate respondsToSelector:@selector(screenRecorder:didStopRecordingWithCapturedVideo:)]) {
                [self.delegate screenRecorder:self didStopRecordingWithCapturedVideo:videoURL];
            }
        }];
    }
}

- (void) saveVideoToPhotoLibrary:(NSURL *) videoURL
{
    //Save recorded video to photos
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    [library writeVideoAtPathToSavedPhotosAlbum:videoURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (!error) {
            NSLog(@"Video saved to camera roll");
        } else {
            NSLog(@"Could not save video to camera roll");
        }
    }];
}

#pragma mark - Internal

-(void) setupVideoWriter
{
    CGFloat videoScale = [UIScreen mainScreen].scale;
    CGSize viewSize = [[UIScreen mainScreen] bounds].size;
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(viewSize.width * videoScale),
                                       (id)kCVPixelBufferHeightKey : @(viewSize.height * videoScale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(viewSize.width * videoScale * 4)
                                       };
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    NSError* error = nil;
    self.videoWriter = [[AVAssetWriter alloc] initWithURL:[self videoFileURL]
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(self.videoWriter);
    
    NSInteger pixelNumber = viewSize.width * viewSize.height * videoScale;
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt: viewSize.width * videoScale],
                                    AVVideoHeightKey: [NSNumber numberWithInt: viewSize.height * videoScale],
                                    AVVideoCompressionPropertiesKey: videoCompression};
    
    //Initialize video writer with settings
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(self.videoWriterInput);
    
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    self.videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    
    self.videoWriterAdapter = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoWriterInput sourcePixelBufferAttributes:nil];
    
    [self.videoWriter addInput:self.videoWriterInput];
}

- (void) videoWriterStartRecording
{
    [self.videoWriter startWriting];
    [self.videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
}

- (void) completeRecordingSessionWithCompletion:(void(^)(NSURL *videoURL)) completionBlock
{
    dispatch_async(self.videoRenderQueue, ^{
        dispatch_sync(self.pixelBufferQueue, ^{
            [self.videoWriterInput markAsFinished];
            [self.videoWriter finishWritingWithCompletionHandler:^{
                [self removeVideoFilePath:self.videoWriter.outputURL.path];
                NSURL *videoURL = self.videoWriter.outputURL;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionBlock) {
                        [self cleanup];
                        completionBlock(videoURL);
                    }
                });
            }];

        });
    });
}

- (void) writeVideoFrame
{
    if (dispatch_semaphore_wait(self.frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    
    dispatch_async(self.videoRenderQueue, ^{
        if (![_videoWriterInput isReadyForMoreMediaData]) {
            return;
        }
        
        if (!self.firstTimeStamp) {
            self.firstTimeStamp = self.displayLink.timestamp;
        }
        CFTimeInterval elapsed = (self.displayLink.timestamp - self.firstTimeStamp);
        CMTime time = CMTimeMakeWithSeconds(elapsed, 1000);
        
        CVPixelBufferRef pixelBuffer = NULL;
        CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
        
        //draw each window into the context
        CGSize viewSize = [UIScreen mainScreen].bounds.size;
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIGraphicsPushContext(bitmapContext); {
                for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
                    [window drawViewHierarchyInRect:CGRectMake(0, 0, viewSize.width, viewSize.height) afterScreenUpdates:NO];
                }
            } UIGraphicsPopContext();
        });

        //append pixelBuffer on a async dispatch_queue and simultaneously render next frame
        //to prevent overwhelming queue with pixel buffers, check if append_pixelBuffer_queue ready else release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(self.pixelAppendingSemaphore, DISPATCH_TIME_NOW) == 0) {
            dispatch_async(self.pixelBufferQueue, ^{
                BOOL success = [self.videoWriterAdapter appendPixelBuffer:pixelBuffer withPresentationTime:time];
                if (!success) {
                    NSLog(@"Warning: Unable to write buffer to video");
                }
                CGContextRelease(bitmapContext);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                
                dispatch_semaphore_signal(self.pixelAppendingSemaphore);
            });
        } else {
            CGContextRelease(bitmapContext);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
        }
        
        dispatch_semaphore_signal(self.frameRenderingSemaphore);
    });
}

- (void)cleanup
{
    self.videoWriterAdapter = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    self.firstTimeStamp = 0;
    CVPixelBufferPoolRelease(_outputBufferPool);
}

#pragma mark - Util

- (NSURL *) videoFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"];
    [self removeVideoFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void) removeVideoFilePath:(NSString *) filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if (![fileManager removeItemAtPath:filePath error:&error]) {
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}

- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), CGColorSpaceCreateDeviceRGB(),
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGFloat videoScale = [UIScreen mainScreen].scale;
    CGSize viewSize = [[UIScreen mainScreen] bounds].size;
    CGContextScaleCTM(bitmapContext, videoScale, videoScale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    return bitmapContext;
}

@end
