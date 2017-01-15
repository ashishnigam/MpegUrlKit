//
//  MUKMasterPlaylist.m
//  MpegUrlKit
//
//  Created by Hinagiku Soranoba on 2017/01/06.
//  Copyright © 2017年 Hinagiku Soranoba. All rights reserved.
//

#import "MUKMasterPlaylist.h"
#import "MUKAttributeList.h"
#import "MUKConsts.h"
#import "MUKXStreamInf+Private.h"
#import "NSError+MUKErrorDomain.h"
#import "NSString+MUKExtension.h"

@interface MUKMasterPlaylist ()
@property (nonatomic, nonnull, strong) NSMutableArray<MUKXMedia*>* processingMedias;
@property (nonatomic, assign) BOOL isWaitingStreamUri;
@property (nonatomic, nonnull, strong) NSMutableArray<MUKXStreamInf*>* processingStreamInfs;
@property (nonatomic, nonnull, strong) NSMutableArray<MUKXSessionData*>* processingSessionData;
@end

@implementation MUKMasterPlaylist

#pragma mark - Lifecycle

- (instancetype _Nullable)init
{
    if (self = [super init]) {
        self.processingMedias = [NSMutableArray array];
        self.processingStreamInfs = [NSMutableArray array];
        self.processingSessionData = [NSMutableArray array];
        self.isWaitingStreamUri = NO;
    }
    return self;
}

#pragma mark - Private Methods

#pragma mark M3U8 Tag

/**
 * 4.3.4.1. EXT-X-MEDIA
 */
- (MUKTagActionResult)onMedia:(NSString* _Nonnull)tagValue error:(NSError* _Nullable* _Nullable)error
{
    NSDictionary<NSString*, MUKAttributeValue*>* attributes
        = [MUKAttributeList parseFromString:tagValue
                             validateOption:@{ @"TYPE" : @(MUKAttributeRequired | MUKAttributeQuotedString),
                                               @"URI" : @(MUKAttributeQuotedString),
                                               @"GROUP-ID" : @(MUKAttributeRequired | MUKAttributeQuotedString),
                                               @"LANGUAGE" : @(MUKAttributeQuotedString),
                                               @"ASSOC-LANGUAGE" : @(MUKAttributeQuotedString),
                                               @"NAME" : @(MUKAttributeRequired | MUKAttributeQuotedString),
                                               @"DEFAULT" : @(MUKAttributeBoolean),
                                               @"AUTOSELECT" : @(MUKAttributeBoolean),
                                               @"FORCED" : @(MUKAttributeBoolean),
                                               @"INSTREAM-ID" : @(MUKAttributeQuotedString),
                                               @"CHARACTERISTICS" : @(MUKAttributeQuotedString),
                                               @"CHANNELS" : @(MUKAttributeQuotedString) }
                                      error:error];
    if (!attributes) {
        return MUKTagActionResultErrored;
    }

    MUKAttributeValue* v;
    NSArray<NSString*>* characteristics = nil;
    if ((v = attributes[@"CHARACTERISTICS"])) {
        characteristics = [v.value componentsSeparatedByString:@","];
    }

    NSMutableArray<NSNumber*>* channels = nil;
    if ((v = attributes[@"CHANNELS"])) {
        NSUInteger num;
        channels = [NSMutableArray array];

        for (NSString* channelStr in [v.value componentsSeparatedByString:@"/"]) {
            if (![channelStr muk_scanDecimalInteger:&num error:error]) {
                return MUKTagActionResultErrored;
            }
            [channels addObject:[NSNumber numberWithUnsignedInteger:num]];
        }
    }

    MUKXMedia* media = [[MUKXMedia alloc] initWithType:[MUKXMedia mediaTypeFromString:attributes[@"TYPE"].value]
                                                   uri:attributes[@"URI"].value
                                               groupId:attributes[@"GROUP-ID"].value
                                              language:attributes[@"LANGUAGE"].value
                                    associatedLanguage:attributes[@"ASSOC-LANGUAGE"].value
                                                  name:attributes[@"NAME"].value
                                    isDefaultRendition:[attributes[@"DEFAULT"].value isEqualToString:@"YES"]
                                         canAutoSelect:[attributes[@"AUTOSELECT"].value isEqualToString:@"YES"]
                                                forced:[attributes[@"FORCED"].value isEqualToString:@"YES"]
                                            instreamId:attributes[@"INSTREAM-ID"].value
                                       characteristics:characteristics
                                              channels:channels];
    [self.processingMedias addObject:media];
    return MUKTagActionResultProcessed;
}

/**
 * 4.3.4.2. EXT-X-STREAM-INF
 */
- (MUKTagActionResult)onStreamInf:(NSString* _Nonnull)tagValue error:(NSError* _Nullable* _Nullable)error
{
    NSDictionary<NSString*, MUKAttributeValue*>* attributes
        = [MUKAttributeList parseFromString:tagValue
                             validateOption:@{ @"BANDWIDTH" : @(MUKAttributeNotQuotedString | MUKAttributeRequired),
                                               @"AVERAGE-BANDWIDTH" : @(MUKAttributeNotQuotedString),
                                               @"CODECS" : @(MUKAttributeQuotedString),
                                               @"RESOLUTION" : @(MUKAttributeNotQuotedString),
                                               @"FRAME-RATE" : @(MUKAttributeNotQuotedString),
                                               @"HDCP-LEVEL" : @(MUKAttributeNotQuotedString),
                                               @"AUDIO" : @(MUKAttributeQuotedString),
                                               @"VIDEO" : @(MUKAttributeQuotedString),
                                               @"SUBTITLES" : @(MUKAttributeQuotedString),
                                               @"CLOSED-CAPTIONS" : @(0) }
                                      error:error];

    if (!attributes) {
        return MUKTagActionResultErrored;
    }

    MUKAttributeValue* v;
    NSUInteger maxBitrate, avgBitrate = 0;
    CGSize resolution = CGSizeZero;
    double frameRate = 0;
    if (![attributes[@"BANDWIDTH"].value muk_scanDecimalInteger:&maxBitrate error:error]) {
        return MUKTagActionResultErrored;
    }

    if (((v = attributes[@"AVERAGE-BANDWIDTH"]) && ![v.value muk_scanDecimalInteger:&avgBitrate error:error])
        || ((v = attributes[@"RESOLUTION"]) && ![v.value muk_scanDecimalResolution:&resolution error:error])
        || ((v = attributes[@"FRAME-RATE"]) && ![v.value muk_scanDouble:&frameRate error:error])) {
        return MUKTagActionResultErrored;
    }

    NSArray<NSString*>* codecs = nil;
    if ((v = attributes[@"CODECS"])) {
        codecs = [v.value componentsSeparatedByString:@","];
    }

    MUKXStreamInfHdcpLevel level = MUKXStreamInfHdcpLevelUnknown;
    if ((v = attributes[@"HDCP-LEVEL"])) {
        level = [MUKXStreamInf hdcpLevelFromString:v.value];
        if (level == MUKXStreamInfHdcpLevelUnknown) {
            SET_ERROR(error, MUKErrorInvalidType,
                      ([NSString stringWithFormat:@"HDCP-LEVEL is enumerate-string. %@ is not supported.", v.value]));
            return MUKTagActionResultErrored;
        }
    }

    NSString* closedCaptions = nil;
    if ((v = attributes[@"CLOSED-CAPTIONS"])) {
        if (v.isQuotedString) {
            closedCaptions = v.value;
        } else {
            if (![v.value isEqualToString:@"NONE"]) {
                SET_ERROR(error, MUKErrorInvalidType,
                          @"CLOSED-CAPTIONS is either a quoted-string or an enumerated-string with the value NONE");
                return MUKTagActionResultErrored;
            }
        }
    }

    MUKXStreamInf* streamInf
        = [[MUKXStreamInf alloc] initWithMaxBitrate:maxBitrate
                                     averageBitrate:avgBitrate
                                             codecs:codecs
                                         resolution:resolution
                                       maxFrameRate:frameRate
                                          hdcpLevel:level
                                       audioGroupId:attributes[@"AUDIO"].value
                                       videoGroupId:attributes[@"VIDEO"].value
                                   subtitlesGroupId:attributes[@"SUBTITLES"].value
                              closedCaptionsGroupId:closedCaptions
                                                uri:@""]; // dummy
    self.isWaitingStreamUri = YES;
    [self.processingStreamInfs addObject:streamInf];
    return MUKTagActionResultProcessed;
}

- (MUKTagActionResult)onStreamInfUri:(NSString* _Nonnull)tagValue error:(NSError* _Nullable* _Nullable)error
{
    NSAssert(self.processingStreamInfs.count > 0, @"processingStreamInfs.count MUST be greater than 0");

    MUKXStreamInf* streamInf = (MUKXStreamInf*)(self.processingStreamInfs.lastObject);
    streamInf.uri = tagValue;
    self.isWaitingStreamUri = NO;

    if (![streamInf validate:error]) {
        return MUKTagActionResultErrored;
    }

    return MUKTagActionResultProcessed;
}

/**
 * 4.3.4.3. EXT-X-I-FRAME-STREAM-INF
 */
- (MUKTagActionResult)onIframeStreamInf:(NSString* _Nonnull)tagValue error:(NSError* _Nullable* _Nullable)error
{
    NSDictionary<NSString*, MUKAttributeValue*>* attributes
        = [MUKAttributeList parseFromString:tagValue
                             validateOption:@{ @"BANDWIDTH" : @(MUKAttributeNotQuotedString | MUKAttributeRequired),
                                               @"AVERAGE-BANDWIDTH" : @(MUKAttributeNotQuotedString),
                                               @"CODECS" : @(MUKAttributeQuotedString),
                                               @"RESOLUTION" : @(MUKAttributeNotQuotedString),
                                               @"HDCP-LEVEL" : @(MUKAttributeNotQuotedString),
                                               @"VIDEO" : @(MUKAttributeQuotedString),
                                               @"URI" : @(MUKAttributeQuotedString | MUKAttributeRequired) }
                                      error:error];

    if (!attributes) {
        return MUKTagActionResultErrored;
    }

    MUKAttributeValue* v;
    NSUInteger maxBitrate, avgBitrate = 0;
    CGSize resolution = CGSizeZero;
    if (![attributes[@"BANDWIDTH"].value muk_scanDecimalInteger:&maxBitrate error:error]) {
        return MUKTagActionResultErrored;
    }

    if (((v = attributes[@"AVERAGE-BANDWIDTH"]) && ![v.value muk_scanDecimalInteger:&avgBitrate error:error])
        || ((v = attributes[@"RESOLUTION"]) && ![v.value muk_scanDecimalResolution:&resolution error:error])) {
        return MUKTagActionResultErrored;
    }

    NSArray<NSString*>* codecs = nil;
    if ((v = attributes[@"CODECS"])) {
        codecs = [v.value componentsSeparatedByString:@","];
    }

    MUKXStreamInfHdcpLevel level = MUKXStreamInfHdcpLevelUnknown;
    if ((v = attributes[@"HDCP-LEVEL"])) {
        level = [MUKXStreamInf hdcpLevelFromString:v.value];
        if (level == MUKXStreamInfHdcpLevelUnknown) {
            SET_ERROR(error, MUKErrorInvalidType,
                      ([NSString stringWithFormat:@"HDCP-LEVEL is enumerate-string. %@ is not supported.", v.value]));
            return MUKTagActionResultErrored;
        }
    }

    MUKXStreamInf* streamInf
        = [[MUKXIframeStreamInf alloc] initWithMaxBitrate:maxBitrate
                                           averageBitrate:avgBitrate
                                                   codecs:codecs
                                               resolution:resolution
                                                hdcpLevel:level
                                             videoGroupId:attributes[@"VIDEO"].value
                                                      uri:attributes[@"URI"].value];
    if (![streamInf validate:error]) {
        return MUKTagActionResultErrored;
    }

    [self.processingStreamInfs addObject:streamInf];
    return MUKTagActionResultProcessed;
}

/**
 * 4.3.4.4. EXT-X-SESSION-DATA
 */
- (MUKTagActionResult)onSessionData:(NSString* _Nonnull)tagValue error:(NSError* _Nullable* _Nullable)error
{
    NSDictionary<NSString*, MUKAttributeValue*>* attributes
        = [MUKAttributeList parseFromString:tagValue
                             validateOption:@{ @"DATA-ID" : @(MUKAttributeRequired | MUKAttributeQuotedString),
                                               @"VALUE" : @(MUKAttributeQuotedString),
                                               @"URI" : @(MUKAttributeQuotedString),
                                               @"LANGUAGE" : @(MUKAttributeQuotedString) }
                                      error:error];

    if (!attributes) {
        return MUKTagActionResultErrored;
    }

    MUKXSessionData* sessionData = [[MUKXSessionData alloc] initWithDataId:attributes[@"DATA-ID"].value
                                                                     value:attributes[@"VALUE"].value
                                                                       uri:attributes[@"URI"].value
                                                                  language:attributes[@"LANGUAGE"].value];
    if (![sessionData validate:error]) {
        return MUKTagActionResultErrored;
    }

    [self.processingSessionData addObject:sessionData];
    return MUKTagActionResultProcessed;
}

#pragma mark - MUKSerializing (Override)

- (NSDictionary<NSString*, MUKTagAction>* _Nonnull)tagActions
{
    if (self.isWaitingStreamUri) {
        return @{ @"" : ACTION([self onStreamInfUri:tagValue error:error]) };
    } else {
        return @{ MUK_EXT_X_MEDIA : ACTION([self onMedia:tagValue error:error]),
                  MUK_EXT_X_STREAM_INF : ACTION([self onStreamInf:tagValue error:error]),
                  MUK_EXT_X_I_FRAME_STREAM_INF : ACTION([self onIframeStreamInf:tagValue error:error]),
                  MUK_EXT_X_SESSION_DATA : ACTION([self onSessionData:tagValue error:error]) };
    }
}

@end