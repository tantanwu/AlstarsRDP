#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDPNativeSessionState) {
    RDPNativeSessionStateIdle = 0,
    RDPNativeSessionStateConnecting,
    RDPNativeSessionStateConnected,
    RDPNativeSessionStateDisconnecting,
    RDPNativeSessionStateClosed,
    RDPNativeSessionStateFailed
};

typedef NS_ENUM(NSUInteger, RDPCertificateDecision) {
    RDPCertificateDecisionReject = 0,
    RDPCertificateDecisionTrustAndStore = 1,
    RDPCertificateDecisionTrustForSession = 2
};

typedef NS_OPTIONS(NSUInteger, RDPMouseButton) {
    RDPMouseButtonLeft = 1 << 0,
    RDPMouseButtonRight = 1 << 1,
    RDPMouseButtonMiddle = 1 << 2
};

@interface RDPConnectionConfiguration : NSObject <NSCopying>
@property(nonatomic, copy) NSString *connectionHost;
@property(nonatomic) uint16_t connectionPort;
@property(nonatomic, copy) NSString *certificateName;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *domain;
@property(nonatomic, copy) NSString *password;
@property(nonatomic) uint32_t desktopWidth;
@property(nonatomic) uint32_t desktopHeight;
@property(nonatomic) BOOL dynamicResolution;
@property(nonatomic) BOOL redirectClipboard;
@property(nonatomic) BOOL audioPlayback;
@property(nonatomic) BOOL audioCapture;
@property(nonatomic) BOOL redirectDrives;
@property(nonatomic, copy) NSArray<NSString *> *redirectDrivePaths;
@property(nonatomic) BOOL redirectPrinters;
@property(nonatomic) BOOL redirectSmartCards;
@property(nonatomic, copy, nullable) NSString *gatewayHost;
@property(nonatomic) uint16_t gatewayPort;
@property(nonatomic, copy) NSString *gatewayUsername;
@property(nonatomic, copy) NSString *gatewayDomain;
@property(nonatomic, copy) NSString *gatewayPassword;
@property(nonatomic) BOOL gatewayHTTPTransport;
@property(nonatomic) BOOL gatewayRPCTransport;
@end

@interface RDPCertificateInfo : NSObject
@property(nonatomic, readonly, copy) NSString *host;
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly, copy) NSString *commonName;
@property(nonatomic, readonly, copy) NSString *subject;
@property(nonatomic, readonly, copy) NSString *issuer;
@property(nonatomic, readonly, copy) NSString *fingerprintOrPEM;
@property(nonatomic, readonly) BOOL changed;
@property(nonatomic, readonly, copy, nullable) NSString *oldFingerprintOrPEM;
@end

@class RDPSession;
NS_SWIFT_UI_ACTOR @protocol RDPSessionDelegate <NSObject>
- (void)session:(RDPSession *)session didChangeState:(RDPNativeSessionState)state errorCode:(uint32_t)errorCode
    NS_SWIFT_NAME(session(_:didChange:errorCode:));
- (void)session:(RDPSession *)session didReceiveFrame:(NSData *)frame width:(uint32_t)width height:(uint32_t)height stride:(uint32_t)stride
    NS_SWIFT_NAME(session(_:didReceiveFrame:width:height:stride:));
- (RDPCertificateDecision)session:(RDPSession *)session decideCertificate:(RDPCertificateInfo *)certificate
    NS_SWIFT_NAME(session(_:decideCertificate:));
@end

@interface RDPSession : NSObject
@property(nonatomic, weak, nullable) id<RDPSessionDelegate> delegate;
@property(nonatomic, readonly) RDPNativeSessionState state;
@property(nonatomic, readonly, copy) NSString *lastErrorName;
@property(nonatomic, readonly, copy) NSString *lastErrorDescription;
@property(nonatomic, readonly, copy) NSString *lastNativeLogDetail;
@property(nonatomic, readonly) uint32_t lastSystemErrorCode;
@property(nonatomic, readonly) int32_t lastSocketErrorCode;

- (instancetype)initWithConfiguration:(RDPConnectionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
- (void)disconnect;
- (void)sendScanCode:(uint32_t)scanCode keyDown:(BOOL)keyDown;
- (void)sendUnicodeScalar:(uint16_t)scalar keyDown:(BOOL)keyDown;
- (void)sendMouseAtX:(uint16_t)x y:(uint16_t)y buttons:(RDPMouseButton)buttons keyDown:(BOOL)keyDown move:(BOOL)move
    NS_SWIFT_NAME(sendMouse(atX:y:buttons:keyDown:move:));
- (void)sendVerticalScroll:(int16_t)delta atX:(uint16_t)x y:(uint16_t)y;
- (void)sendHorizontalScroll:(int16_t)delta atX:(uint16_t)x y:(uint16_t)y;
- (void)sendControlAltDelete;
@end

NS_ASSUME_NONNULL_END
