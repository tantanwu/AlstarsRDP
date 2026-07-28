#import "RDPSession.h"

#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>

#include <freerdp/client.h>
#include <freerdp/addin.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/codec/color.h>
#include <freerdp/freerdp.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <winpr/crt.h>
#include <winpr/error.h>
#include <winpr/synch.h>
#include <winpr/winsock.h>
#include <winpr/wlog.h>

@interface RDPCertificateInfo ()
@property(nonatomic, readwrite, copy) NSString *host;
@property(nonatomic, readwrite) uint16_t port;
@property(nonatomic, readwrite, copy) NSString *commonName;
@property(nonatomic, readwrite, copy) NSString *subject;
@property(nonatomic, readwrite, copy) NSString *issuer;
@property(nonatomic, readwrite, copy) NSString *fingerprintOrPEM;
@property(nonatomic, readwrite) BOOL changed;
@property(nonatomic, readwrite, copy, nullable) NSString *oldFingerprintOrPEM;
@end

@implementation RDPCertificateInfo
@end

@implementation RDPConnectionConfiguration
- (instancetype)init {
    self = [super init];
    if (self) {
        _connectionHost = @"";
        _connectionPort = 3389;
        _serverName = @"";
        _certificateName = @"";
        _username = @"";
        _domain = @"";
        _password = @"";
        _desktopWidth = 1920;
        _desktopHeight = 1080;
        _desktopScaleFactor = 100;
        _deviceScaleFactor = 100;
        _dynamicResolution = YES;
        _redirectClipboard = YES;
        _audioPlayback = YES;
        _audioCapture = NO;
        _redirectDrives = NO;
        _redirectDrivePaths = @[];
        _redirectPrinters = NO;
        _redirectSmartCards = NO;
        _gatewayPort = 443;
        _gatewayUsername = @"";
        _gatewayDomain = @"";
        _gatewayPassword = @"";
        _gatewayHTTPTransport = YES;
        _gatewayRPCTransport = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    RDPConnectionConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.connectionHost = self.connectionHost;
    copy.connectionPort = self.connectionPort;
    copy.serverName = self.serverName;
    copy.certificateName = self.certificateName;
    copy.username = self.username;
    copy.domain = self.domain;
    copy.password = self.password;
    copy.desktopWidth = self.desktopWidth;
    copy.desktopHeight = self.desktopHeight;
    copy.desktopScaleFactor = self.desktopScaleFactor;
    copy.deviceScaleFactor = self.deviceScaleFactor;
    copy.dynamicResolution = self.dynamicResolution;
    copy.redirectClipboard = self.redirectClipboard;
    copy.audioPlayback = self.audioPlayback;
    copy.audioCapture = self.audioCapture;
    copy.redirectDrives = self.redirectDrives;
    copy.redirectDrivePaths = self.redirectDrivePaths;
    copy.redirectPrinters = self.redirectPrinters;
    copy.redirectSmartCards = self.redirectSmartCards;
    copy.gatewayHost = self.gatewayHost;
    copy.gatewayPort = self.gatewayPort;
    copy.gatewayUsername = self.gatewayUsername;
    copy.gatewayDomain = self.gatewayDomain;
    copy.gatewayPassword = self.gatewayPassword;
    copy.gatewayHTTPTransport = self.gatewayHTTPTransport;
    copy.gatewayRPCTransport = self.gatewayRPCTransport;
    return copy;
}
@end

@class RDPSession;
typedef struct {
    rdpContext context;
    __unsafe_unretained RDPSession *owner;
    BOOL gdiInitialized;
    BOOL channelEventsSubscribed;
    DispClientContext *displayControl;
    BOOL displayControlActivated;
    UINT32 maxNumMonitors;
    UINT32 maxMonitorAreaFactorA;
    UINT32 maxMonitorAreaFactorB;
} RDPAppContext;

@interface RDPSession () {
    RDPConnectionConfiguration *_configuration;
    dispatch_queue_t _sessionQueue;
    std::atomic<RDPNativeSessionState> _nativeState;
    std::atomic_bool _stopRequested;
    std::mutex _instanceMutex;
    freerdp *_instance;
    std::mutex _frameMutex;
    NSData *_pendingFrame;
    uint32_t _pendingFrameWidth;
    uint32_t _pendingFrameHeight;
    uint32_t _pendingFrameStride;
    bool _frameDeliveryScheduled;
}
@property(nonatomic, readwrite, copy) NSString *lastErrorName;
@property(nonatomic, readwrite, copy) NSString *lastErrorDescription;
@property(nonatomic, readwrite, copy) NSString *lastNativeLogDetail;
@property(nonatomic, readwrite) uint32_t lastSystemErrorCode;
@property(nonatomic, readwrite) int32_t lastSocketErrorCode;
- (void)publishState:(RDPNativeSessionState)state errorCode:(uint32_t)errorCode;
- (void)notifyState:(RDPNativeSessionState)state errorCode:(uint32_t)errorCode;
- (void)clearConfigurationSecrets;
- (RDPCertificateDecision)certificateDecision:(RDPCertificateInfo *)certificate;
- (void)publishFrameFromContext:(RDPAppContext *)context;
- (void)deliverPendingFrame;
- (void)clearPendingFrame;
- (void)displayControlConnected:(DispClientContext *)displayControl
                         context:(RDPAppContext *)context;
- (void)displayControlDisconnected:(DispClientContext *)displayControl
                            context:(RDPAppContext *)context;
- (void)displayControlActivated:(DispClientContext *)displayControl
                        context:(RDPAppContext *)context
                 maxNumMonitors:(UINT32)maxNumMonitors
          maxMonitorAreaFactorA:(UINT32)maxMonitorAreaFactorA
          maxMonitorAreaFactorB:(UINT32)maxMonitorAreaFactorB;
- (void)captureFailureDetailsForInstance:(freerdp *)instance
                               errorCode:(uint32_t)errorCode
                         systemErrorCode:(uint32_t)systemErrorCode
                         socketErrorCode:(int32_t)socketErrorCode;
@end

static constexpr size_t RDPMaxFrameBytes = 256u * 1024u * 1024u;
static constexpr size_t RDPMaxNativeLogBytes = 4u * 1024u;
static std::once_flag RDPNativeLogRegistration;
static thread_local std::string RDPThreadNativeLog;

static BOOL RDPNativeLogMessage(const wLogMessage *message) {
    if (!message || message->Level < WLOG_ERROR) return TRUE;
    const char *text = message->TextString;
    if (!text || text[0] == '\0') text = message->FormatString;
    if (!text || text[0] == '\0' || RDPThreadNativeLog.size() >= RDPMaxNativeLogBytes) return TRUE;
    if (!RDPThreadNativeLog.empty()) RDPThreadNativeLog.append("\n");
    const size_t remaining = RDPMaxNativeLogBytes - RDPThreadNativeLog.size();
    RDPThreadNativeLog.append(text, strnlen(text, remaining));
    return TRUE;
}

static void RDPConfigureNativeLogging(void) {
    std::call_once(RDPNativeLogRegistration, [] {
        wLog *root = WLog_GetRoot();
        if (!root || !WLog_SetLogLevel(root, WLOG_ERROR) ||
            !WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK)) return;
        wLogAppender *appender = WLog_GetLogAppender(root);
        if (!appender) return;
        wLogCallbacks callbacks = {};
        callbacks.message = RDPNativeLogMessage;
        if (!WLog_ConfigureAppender(appender, "callbacks", &callbacks)) return;
        (void)WLog_OpenAppender(root);
    });
}

static NSString *RDPString(const char *value) {
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

static RDPAppContext *RDPContextFromInstance(freerdp *instance) {
    return instance && instance->context ? reinterpret_cast<RDPAppContext *>(instance->context) : nullptr;
}

static UINT RDPDisplayControlCaps(DispClientContext *displayControl, UINT32 maxNumMonitors,
                                  UINT32 maxMonitorAreaFactorA,
                                  UINT32 maxMonitorAreaFactorB) {
    if (!displayControl || !displayControl->custom) return CHANNEL_RC_BAD_CHANNEL;
    RDPAppContext *context = static_cast<RDPAppContext *>(displayControl->custom);
    RDPSession *owner = context->owner;
    if (!owner) return CHANNEL_RC_BAD_CHANNEL;
    [owner displayControlActivated:displayControl
                           context:context
                    maxNumMonitors:maxNumMonitors
             maxMonitorAreaFactorA:maxMonitorAreaFactorA
             maxMonitorAreaFactorB:maxMonitorAreaFactorB];
    return CHANNEL_RC_OK;
}

static void RDPChannelConnected(void *contextValue, const ChannelConnectedEventArgs *event) {
    if (!contextValue || !event || !event->name || !event->pInterface ||
        strcmp(event->name, DISP_DVC_CHANNEL_NAME) != 0) return;
    RDPAppContext *context = static_cast<RDPAppContext *>(contextValue);
    RDPSession *owner = context->owner;
    if (owner) {
        [owner displayControlConnected:static_cast<DispClientContext *>(event->pInterface)
                               context:context];
    }
}

static void RDPChannelDisconnected(void *contextValue, const ChannelDisconnectedEventArgs *event) {
    if (!contextValue || !event || !event->name || !event->pInterface ||
        strcmp(event->name, DISP_DVC_CHANNEL_NAME) != 0) return;
    RDPAppContext *context = static_cast<RDPAppContext *>(contextValue);
    RDPSession *owner = context->owner;
    if (owner) {
        [owner displayControlDisconnected:static_cast<DispClientContext *>(event->pInterface)
                                  context:context];
    }
}

static BOOL RDPContextNew(freerdp *instance, rdpContext *context) {
    if (!instance || !context) return FALSE;
    RDPAppContext *appContext = reinterpret_cast<RDPAppContext *>(context);
    appContext->owner = nil;
    appContext->gdiInitialized = NO;
    return TRUE;
}

static void RDPContextFree(freerdp *instance, rdpContext *context) {
    WINPR_UNUSED(instance);
    if (!context) return;
    RDPAppContext *appContext = reinterpret_cast<RDPAppContext *>(context);
    if (appContext->channelEventsSubscribed && context->pubSub) {
        PubSub_UnsubscribeChannelConnected(context->pubSub, RDPChannelConnected);
        PubSub_UnsubscribeChannelDisconnected(context->pubSub, RDPChannelDisconnected);
    }
    appContext->displayControl = nullptr;
    appContext->displayControlActivated = NO;
    appContext->owner = nil;
}

static BOOL RDPBeginPaint(rdpContext *context) {
    if (!context || !context->gdi || !context->gdi->primary || !context->gdi->primary->hdc ||
        !context->gdi->primary->hdc->hwnd || !context->gdi->primary->hdc->hwnd->invalid) return FALSE;
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL RDPEndPaint(rdpContext *context) {
    if (!context) return FALSE;
    RDPAppContext *appContext = reinterpret_cast<RDPAppContext *>(context);
    RDPSession *owner = appContext->owner;
    if (owner) [owner publishFrameFromContext:appContext];
    return TRUE;
}

static BOOL RDPDesktopResize(rdpContext *context) {
    if (!context || !context->gdi || !context->settings) return FALSE;
    return gdi_resize(context->gdi,
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight));
}

static std::once_flag RDPAddinProviderRegistration;
static int RDPAddinProviderRegistrationStatus = -1;

static BOOL RDPPreConnect(freerdp *instance) {
    if (!instance || !instance->context || !instance->context->settings || !instance->context->update) return FALSE;
    RDPAppContext *appContext = RDPContextFromInstance(instance);
    if (!appContext || !instance->context->pubSub) return FALSE;
    if (!appContext->channelEventsSubscribed) {
        if (PubSub_SubscribeChannelConnected(instance->context->pubSub, RDPChannelConnected) < 0)
            return FALSE;
        if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, RDPChannelDisconnected) < 0) {
            PubSub_UnsubscribeChannelConnected(instance->context->pubSub, RDPChannelConnected);
            return FALSE;
        }
        appContext->channelEventsSubscribed = YES;
    }
    rdpSettings *settings = instance->context->settings;
    if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH)) return FALSE;
    instance->context->update->BeginPaint = RDPBeginPaint;
    instance->context->update->EndPaint = RDPEndPaint;
    instance->context->update->DesktopResize = RDPDesktopResize;
    std::call_once(RDPAddinProviderRegistration, [] {
        RDPAddinProviderRegistrationStatus =
            freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);
    });
    if (RDPAddinProviderRegistrationStatus != CHANNEL_RC_OK) return FALSE;
    return freerdp_client_load_addins(instance->context->channels, settings);
}

static BOOL RDPPostConnect(freerdp *instance) {
    RDPAppContext *context = RDPContextFromInstance(instance);
    if (!context || !gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    context->gdiInitialized = YES;
    RDPSession *owner = context->owner;
    if (owner) [owner publishState:RDPNativeSessionStateConnected errorCode:0];
    return TRUE;
}

static void RDPPostDisconnect(freerdp *instance) {
    RDPAppContext *context = RDPContextFromInstance(instance);
    if (context && context->gdiInitialized) {
        gdi_free(instance);
        context->gdiInitialized = NO;
    }
}

static DWORD RDPVerifyCertificate(freerdp *instance, const char *host, UINT16 port,
                                  const char *commonName, const char *subject,
                                  const char *issuer, const char *fingerprint, DWORD flags) {
    WINPR_UNUSED(flags);
    RDPAppContext *context = RDPContextFromInstance(instance);
    if (!context || !context->owner) return RDPCertificateDecisionReject;
    RDPCertificateInfo *certificate = [RDPCertificateInfo new];
    certificate.host = RDPString(host);
    certificate.port = port;
    certificate.commonName = RDPString(commonName);
    certificate.subject = RDPString(subject);
    certificate.issuer = RDPString(issuer);
    certificate.fingerprintOrPEM = RDPString(fingerprint);
    certificate.changed = NO;
    return static_cast<DWORD>([context->owner certificateDecision:certificate]);
}

static DWORD RDPVerifyChangedCertificate(freerdp *instance, const char *host, UINT16 port,
                                         const char *commonName, const char *subject,
                                         const char *issuer, const char *newFingerprint,
                                         const char *oldSubject, const char *oldIssuer,
                                         const char *oldFingerprint, DWORD flags) {
    WINPR_UNUSED(oldSubject);
    WINPR_UNUSED(oldIssuer);
    WINPR_UNUSED(flags);
    RDPAppContext *context = RDPContextFromInstance(instance);
    if (!context || !context->owner) return RDPCertificateDecisionReject;
    RDPCertificateInfo *certificate = [RDPCertificateInfo new];
    certificate.host = RDPString(host);
    certificate.port = port;
    certificate.commonName = RDPString(commonName);
    certificate.subject = RDPString(subject);
    certificate.issuer = RDPString(issuer);
    certificate.fingerprintOrPEM = RDPString(newFingerprint);
    certificate.changed = YES;
    certificate.oldFingerprintOrPEM = RDPString(oldFingerprint);
    return static_cast<DWORD>([context->owner certificateDecision:certificate]);
}

static int RDPLogonErrorInfo(freerdp *instance, UINT32 data, UINT32 type) {
    WINPR_UNUSED(data);
    WINPR_UNUSED(type);
    RDPAppContext *context = RDPContextFromInstance(instance);
    if (context && context->owner) {
        [context->owner publishState:RDPNativeSessionStateFailed
                             errorCode:freerdp_get_last_error(instance->context)];
    }
    return 1;
}

static BOOL RDPSetString(rdpSettings *settings, FreeRDP_Settings_Keys_String id, NSString *value) {
    return freerdp_settings_set_string(settings, id, value.UTF8String);
}

static BOOL RDPConfigureSettings(rdpSettings *settings, RDPConnectionConfiguration *configuration) {
    if (!settings || configuration.connectionHost.length == 0 || configuration.serverName.length == 0 ||
        configuration.certificateName.length == 0) return FALSE;
    BOOL ok = RDPSetString(settings, FreeRDP_ServerHostname, configuration.connectionHost) &&
              freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, configuration.connectionPort) &&
              RDPSetString(settings, FreeRDP_UserSpecifiedServerName, configuration.serverName) &&
              RDPSetString(settings, FreeRDP_CertificateName, configuration.certificateName) &&
              RDPSetString(settings, FreeRDP_Username, configuration.username) &&
              RDPSetString(settings, FreeRDP_Domain, configuration.domain) &&
              RDPSetString(settings, FreeRDP_Password, configuration.password) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, configuration.desktopWidth) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, configuration.desktopHeight) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, configuration.desktopScaleFactor) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, configuration.deviceScaleFactor) &&
              freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE) &&
              freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
              freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
              freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, configuration.dynamicResolution) &&
              freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, configuration.dynamicResolution) &&
              freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, configuration.redirectClipboard) &&
              freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, configuration.audioPlayback) &&
              freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, configuration.audioCapture) &&
              freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, configuration.redirectDrives) &&
              freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, configuration.redirectPrinters) &&
              freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, configuration.redirectSmartCards) &&
              freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, configuration.password.length > 0) &&
              freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
              freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE) &&
              freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
    if (!ok) return FALSE;

    if (configuration.gatewayHost.length > 0) {
        ok = RDPSetString(settings, FreeRDP_GatewayHostname, configuration.gatewayHost) &&
             freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort, configuration.gatewayPort) &&
             RDPSetString(settings, FreeRDP_GatewayUsername, configuration.gatewayUsername) &&
             RDPSetString(settings, FreeRDP_GatewayDomain, configuration.gatewayDomain) &&
             RDPSetString(settings, FreeRDP_GatewayPassword, configuration.gatewayPassword) &&
             freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE) &&
             freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, FALSE) &&
             freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport, configuration.gatewayHTTPTransport) &&
             freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport, configuration.gatewayRPCTransport) &&
             freerdp_set_gateway_usage_method(settings, TSC_PROXY_MODE_DIRECT);
    }
    return ok;
}

static void RDPClearSettingsSecrets(rdpSettings *settings) {
    if (!settings) return;
    freerdp_settings_set_string(settings, FreeRDP_Password, "");
    freerdp_settings_set_string(settings, FreeRDP_GatewayPassword, "");
}

static bool RDPStateCanTransition(RDPNativeSessionState from, RDPNativeSessionState to) {
    switch (from) {
        case RDPNativeSessionStateIdle:
            return to == RDPNativeSessionStateConnecting;
        case RDPNativeSessionStateConnecting:
            return to == RDPNativeSessionStateConnected ||
                   to == RDPNativeSessionStateDisconnecting ||
                   to == RDPNativeSessionStateClosed ||
                   to == RDPNativeSessionStateFailed;
        case RDPNativeSessionStateConnected:
            return to == RDPNativeSessionStateDisconnecting ||
                   to == RDPNativeSessionStateClosed ||
                   to == RDPNativeSessionStateFailed;
        case RDPNativeSessionStateDisconnecting:
            return to == RDPNativeSessionStateClosed;
        case RDPNativeSessionStateClosed:
        case RDPNativeSessionStateFailed:
            return false;
    }
    return false;
}

@implementation RDPSession

- (instancetype)initWithConfiguration:(RDPConnectionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _sessionQueue = dispatch_queue_create("com.example.RemoteDesktop.rdp-session", DISPATCH_QUEUE_SERIAL);
        _nativeState.store(RDPNativeSessionStateIdle);
        _stopRequested.store(false);
        _instance = nullptr;
        _pendingFrame = nil;
        _pendingFrameWidth = 0;
        _pendingFrameHeight = 0;
        _pendingFrameStride = 0;
        _frameDeliveryScheduled = false;
        _lastErrorName = @"";
        _lastErrorDescription = @"";
        _lastNativeLogDetail = @"";
        _lastSystemErrorCode = 0;
        _lastSocketErrorCode = 0;
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (RDPNativeSessionState)state { return _nativeState.load(); }

- (void)start {
    RDPNativeSessionState expected = RDPNativeSessionStateIdle;
    if (!_nativeState.compare_exchange_strong(expected, RDPNativeSessionStateConnecting)) return;
    _stopRequested.store(false);
    [self notifyState:RDPNativeSessionStateConnecting errorCode:0];
    __weak RDPSession *weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        RDPSession *strongSelf = weakSelf;
        if (!strongSelf) return;
        RDPConfigureNativeLogging();
        RDPThreadNativeLog.clear();
        if (strongSelf->_stopRequested.load()) {
            [strongSelf clearConfigurationSecrets];
            [strongSelf publishState:RDPNativeSessionStateClosed errorCode:0];
            return;
        }
        freerdp *instance = freerdp_new();
        if (!instance) {
            [strongSelf clearConfigurationSecrets];
            [strongSelf publishState:RDPNativeSessionStateFailed errorCode:UINT32_MAX];
            return;
        }
        instance->ContextSize = sizeof(RDPAppContext);
        instance->ContextNew = RDPContextNew;
        instance->ContextFree = RDPContextFree;
        instance->PreConnect = RDPPreConnect;
        instance->PostConnect = RDPPostConnect;
        instance->PostDisconnect = RDPPostDisconnect;
        instance->VerifyCertificateEx = RDPVerifyCertificate;
        instance->VerifyChangedCertificateEx = RDPVerifyChangedCertificate;
        instance->LogonErrorInfo = RDPLogonErrorInfo;
        if (!freerdp_context_new(instance)) {
            freerdp_free(instance);
            [strongSelf clearConfigurationSecrets];
            [strongSelf publishState:RDPNativeSessionStateFailed errorCode:UINT32_MAX - 1];
            return;
        }
        RDPAppContext *context = RDPContextFromInstance(instance);
        context->owner = strongSelf;
        {
            std::lock_guard<std::mutex> guard(strongSelf->_instanceMutex);
            strongSelf->_instance = instance;
        }
        if (strongSelf->_stopRequested.load()) {
            [strongSelf clearConfigurationSecrets];
            freerdp_abort_connect_context(instance->context);
        } else if (!RDPConfigureSettings(instance->context->settings, strongSelf->_configuration)) {
            RDPClearSettingsSecrets(instance->context->settings);
            [strongSelf clearConfigurationSecrets];
            [strongSelf publishState:RDPNativeSessionStateFailed errorCode:UINT32_MAX - 2];
        } else {
            SetLastError(ERROR_SUCCESS);
            WSASetLastError(0);
            const BOOL connected = freerdp_connect(instance);
            const uint32_t connectError = freerdp_get_last_error(instance->context);
            const uint32_t systemError = GetLastError();
            const int32_t socketError = WSAGetLastError();
            if (!connected) {
                [strongSelf captureFailureDetailsForInstance:instance
                                                   errorCode:connectError
                                             systemErrorCode:systemError
                                             socketErrorCode:socketError];
            }
            RDPClearSettingsSecrets(instance->context->settings);
            [strongSelf clearConfigurationSecrets];
            if (!connected) {
                [strongSelf publishState:RDPNativeSessionStateFailed errorCode:connectError];
            } else {
                HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {};
                while (!freerdp_shall_disconnect_context(instance->context)) {
                    DWORD count = freerdp_get_event_handles(instance->context, handles, ARRAYSIZE(handles));
                    if (count == 0) break;
                    DWORD wait = WaitForMultipleObjects(count, handles, FALSE, 1000);
                    if (wait == WAIT_FAILED || !freerdp_check_event_handles(instance->context)) break;
                }
            }
        }
        const uint32_t terminalError = instance->context
            ? freerdp_get_last_error(instance->context)
            : UINT32_MAX;
        {
            std::lock_guard<std::mutex> guard(strongSelf->_instanceMutex);
            strongSelf->_instance = nullptr;
        }
        if (instance->context) freerdp_disconnect(instance);
        freerdp_context_free(instance);
        freerdp_free(instance);
        [strongSelf clearPendingFrame];
        if (strongSelf.state != RDPNativeSessionStateFailed &&
            !strongSelf->_stopRequested.load() && terminalError != 0) {
            [strongSelf publishState:RDPNativeSessionStateFailed errorCode:terminalError];
        } else if (strongSelf.state != RDPNativeSessionStateFailed) {
            [strongSelf publishState:RDPNativeSessionStateClosed errorCode:0];
        }
    });
}

- (void)disconnect {
    _stopRequested.store(true);
    RDPNativeSessionState state = _nativeState.load();
    if (state == RDPNativeSessionStateClosed || state == RDPNativeSessionStateFailed ||
        state == RDPNativeSessionStateIdle || state == RDPNativeSessionStateDisconnecting) return;
    [self publishState:RDPNativeSessionStateDisconnecting errorCode:0];
    std::lock_guard<std::mutex> guard(_instanceMutex);
    if (_instance && _instance->context) freerdp_abort_connect_context(_instance->context);
}

- (void)displayControlConnected:(DispClientContext *)displayControl
                         context:(RDPAppContext *)context {
    if (!displayControl || !_configuration.dynamicResolution) return;
    std::lock_guard<std::mutex> guard(_instanceMutex);
    if (!context) return;
    context->displayControl = displayControl;
    context->displayControlActivated = NO;
    context->maxNumMonitors = 0;
    context->maxMonitorAreaFactorA = 0;
    context->maxMonitorAreaFactorB = 0;
    displayControl->custom = context;
    displayControl->DisplayControlCaps = RDPDisplayControlCaps;
}

- (void)displayControlDisconnected:(DispClientContext *)displayControl
                            context:(RDPAppContext *)context {
    if (!displayControl) return;
    std::lock_guard<std::mutex> guard(_instanceMutex);
    if (!context || context->displayControl != displayControl) return;
    if (displayControl->custom == context) {
        displayControl->DisplayControlCaps = nullptr;
        displayControl->custom = nullptr;
    }
    context->displayControl = nullptr;
    context->displayControlActivated = NO;
}

- (void)displayControlActivated:(DispClientContext *)displayControl
                        context:(RDPAppContext *)context
                 maxNumMonitors:(UINT32)maxNumMonitors
          maxMonitorAreaFactorA:(UINT32)maxMonitorAreaFactorA
          maxMonitorAreaFactorB:(UINT32)maxMonitorAreaFactorB {
    BOOL shouldNotify = NO;
    {
        std::lock_guard<std::mutex> guard(_instanceMutex);
        if (!context || context->displayControl != displayControl) return;
        shouldNotify = !context->displayControlActivated;
        context->displayControlActivated = YES;
        context->maxNumMonitors = maxNumMonitors;
        context->maxMonitorAreaFactorA = maxMonitorAreaFactorA;
        context->maxMonitorAreaFactorB = maxMonitorAreaFactorB;
    }
    if (!shouldNotify) return;
    id<RDPSessionDelegate> delegate = self.delegate;
    if (!delegate) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate == delegate) [delegate sessionDidActivateDisplayControl:self];
    });
}

- (BOOL)requestDesktopResizeToWidth:(uint32_t)width
                             height:(uint32_t)height
                 desktopScaleFactor:(uint32_t)desktopScaleFactor
                  deviceScaleFactor:(uint32_t)deviceScaleFactor
                      physicalWidth:(uint32_t)physicalWidth
                     physicalHeight:(uint32_t)physicalHeight {
    if (!_configuration.dynamicResolution || width < DISPLAY_CONTROL_MIN_MONITOR_WIDTH ||
        width > DISPLAY_CONTROL_MAX_MONITOR_WIDTH || (width % 2) != 0 ||
        height < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT ||
        height > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT ||
        physicalWidth < DISPLAY_CONTROL_MIN_PHYSICAL_MONITOR_WIDTH ||
        physicalWidth > DISPLAY_CONTROL_MAX_PHYSICAL_MONITOR_WIDTH ||
        physicalHeight < DISPLAY_CONTROL_MIN_PHYSICAL_MONITOR_HEIGHT ||
        physicalHeight > DISPLAY_CONTROL_MAX_PHYSICAL_MONITOR_HEIGHT ||
        desktopScaleFactor < 100 || desktopScaleFactor > 500 ||
        (deviceScaleFactor != 100 && deviceScaleFactor != 140 && deviceScaleFactor != 180)) {
        return NO;
    }

    std::lock_guard<std::mutex> guard(_instanceMutex);
    if (_nativeState.load() != RDPNativeSessionStateConnected) return NO;
    RDPAppContext *context = RDPContextFromInstance(_instance);
    if (!context || !context->displayControlActivated || context->maxNumMonitors < 1 ||
        !context->displayControl || !context->displayControl->SendMonitorLayout) return NO;
    if (context->maxMonitorAreaFactorA > 0 && context->maxMonitorAreaFactorB > 0) {
        const uint64_t maximumArea = static_cast<uint64_t>(context->maxMonitorAreaFactorA) *
                                     static_cast<uint64_t>(context->maxMonitorAreaFactorB);
        if (static_cast<uint64_t>(width) * static_cast<uint64_t>(height) > maximumArea) return NO;
    }

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = {};
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = width;
    layout.Height = height;
    layout.PhysicalWidth = physicalWidth;
    layout.PhysicalHeight = physicalHeight;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = desktopScaleFactor;
    layout.DeviceScaleFactor = deviceScaleFactor;
    const UINT status = context->displayControl->SendMonitorLayout(
        context->displayControl, 1, &layout
    );
    if (status != CHANNEL_RC_OK) return NO;

    rdpSettings *settings = _instance && _instance->context ? _instance->context->settings : nullptr;
    if (settings) {
        (void)freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width);
        (void)freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height);
        (void)freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, desktopScaleFactor);
        (void)freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, deviceScaleFactor);
    }
    return YES;
}

- (void)publishState:(RDPNativeSessionState)state errorCode:(uint32_t)errorCode {
    RDPNativeSessionState previous = _nativeState.load();
    while (true) {
        if (!RDPStateCanTransition(previous, state)) return;
        if (_nativeState.compare_exchange_weak(previous, state)) break;
    }
    [self notifyState:state errorCode:errorCode];
}

- (void)notifyState:(RDPNativeSessionState)state errorCode:(uint32_t)errorCode {
    id<RDPSessionDelegate> delegate = self.delegate;
    if (!delegate) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate session:self didChangeState:state errorCode:errorCode]; });
}

- (void)clearConfigurationSecrets {
    _configuration.password = @"";
    _configuration.gatewayPassword = @"";
}

- (void)captureFailureDetailsForInstance:(freerdp *)instance
                               errorCode:(uint32_t)errorCode
                         systemErrorCode:(uint32_t)systemErrorCode
                         socketErrorCode:(int32_t)socketErrorCode {
    self.lastErrorName = RDPString(freerdp_get_last_error_name(errorCode));
    self.lastErrorDescription = RDPString(freerdp_get_last_error_string(errorCode));
    self.lastSystemErrorCode = systemErrorCode;
    self.lastSocketErrorCode = socketErrorCode;

    NSString *detail = RDPString(RDPThreadNativeLog.c_str());
    if (instance && instance->context && instance->context->errorDescription) {
        NSString *contextDetail = RDPString(instance->context->errorDescription);
        if (contextDetail.length > 0 && ![detail containsString:contextDetail]) {
            detail = detail.length > 0
                ? [detail stringByAppendingFormat:@"\n%@", contextDetail]
                : contextDetail;
        }
    }
    for (NSString *secret in @[
        _configuration.password ?: @"",
        _configuration.gatewayPassword ?: @"",
        _configuration.username ?: @"",
        _configuration.gatewayUsername ?: @""
    ]) {
        if (secret.length > 0) {
            detail = [detail stringByReplacingOccurrencesOfString:secret withString:@"[redacted]"];
        }
    }
    self.lastNativeLogDetail = detail;
}

- (RDPCertificateDecision)certificateDecision:(RDPCertificateInfo *)certificate {
    id<RDPSessionDelegate> delegate = self.delegate;
    if (!delegate) return RDPCertificateDecisionReject;
    if ([NSThread isMainThread]) return [delegate session:self decideCertificate:certificate];
    __block RDPCertificateDecision decision = RDPCertificateDecisionReject;
    dispatch_sync(dispatch_get_main_queue(), ^{ decision = [delegate session:self decideCertificate:certificate]; });
    return decision;
}

- (void)publishFrameFromContext:(RDPAppContext *)context {
    if (!context || !context->context.gdi || !context->context.gdi->primary_buffer) return;
    if (!self.delegate) return;
    rdpGdi *gdi = context->context.gdi;
    const size_t widthValue = static_cast<size_t>(gdi->width);
    const size_t strideValue = static_cast<size_t>(gdi->stride);
    const size_t heightValue = static_cast<size_t>(gdi->height);
    if (widthValue == 0 || heightValue == 0 || strideValue == 0 ||
        widthValue > std::numeric_limits<size_t>::max() / 4u ||
        strideValue < widthValue * 4u ||
        strideValue > std::numeric_limits<size_t>::max() / heightValue) return;
    const size_t length = strideValue * heightValue;
    if (length > RDPMaxFrameBytes) return;
    NSData *frame = [[NSData alloc] initWithBytes:gdi->primary_buffer length:length];
    const uint32_t width = static_cast<uint32_t>(gdi->width);
    const uint32_t height = static_cast<uint32_t>(gdi->height);
    const uint32_t stride = gdi->stride;
    bool shouldSchedule = false;
    {
        std::lock_guard<std::mutex> guard(_frameMutex);
        _pendingFrame = frame;
        _pendingFrameWidth = width;
        _pendingFrameHeight = height;
        _pendingFrameStride = stride;
        if (!_frameDeliveryScheduled) {
            _frameDeliveryScheduled = true;
            shouldSchedule = true;
        }
    }
    if (!shouldSchedule) return;
    __weak RDPSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf deliverPendingFrame];
    });
}

- (void)deliverPendingFrame {
    NSData *frame = nil;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t stride = 0;
    {
        std::lock_guard<std::mutex> guard(_frameMutex);
        frame = _pendingFrame;
        width = _pendingFrameWidth;
        height = _pendingFrameHeight;
        stride = _pendingFrameStride;
        _pendingFrame = nil;
        _pendingFrameWidth = 0;
        _pendingFrameHeight = 0;
        _pendingFrameStride = 0;
        _frameDeliveryScheduled = false;
    }
    id<RDPSessionDelegate> delegate = self.delegate;
    if (delegate && frame) {
        [delegate session:self didReceiveFrame:frame width:width height:height stride:stride];
    }
}

- (void)clearPendingFrame {
    std::lock_guard<std::mutex> guard(_frameMutex);
    _pendingFrame = nil;
    _pendingFrameWidth = 0;
    _pendingFrameHeight = 0;
    _pendingFrameStride = 0;
}

- (void)sendScanCode:(uint32_t)scanCode keyDown:(BOOL)keyDown {
    std::lock_guard<std::mutex> guard(_instanceMutex);
    rdpInput *input = (_instance && _instance->context) ? _instance->context->input : nullptr;
    if (input) freerdp_input_send_keyboard_event_ex(input, keyDown, FALSE, scanCode);
}

- (void)sendUnicodeScalar:(uint16_t)scalar keyDown:(BOOL)keyDown {
    std::lock_guard<std::mutex> guard(_instanceMutex);
    rdpInput *input = (_instance && _instance->context) ? _instance->context->input : nullptr;
    if (input) freerdp_input_send_unicode_keyboard_event(input, keyDown ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE, scalar);
}

- (void)sendMouseAtX:(uint16_t)x y:(uint16_t)y buttons:(RDPMouseButton)buttons keyDown:(BOOL)keyDown move:(BOOL)move {
    UINT16 flags = move ? PTR_FLAGS_MOVE : 0;
    if (keyDown) flags |= PTR_FLAGS_DOWN;
    if (buttons & RDPMouseButtonLeft) flags |= PTR_FLAGS_BUTTON1;
    if (buttons & RDPMouseButtonRight) flags |= PTR_FLAGS_BUTTON2;
    if (buttons & RDPMouseButtonMiddle) flags |= PTR_FLAGS_BUTTON3;
    std::lock_guard<std::mutex> guard(_instanceMutex);
    rdpInput *input = (_instance && _instance->context) ? _instance->context->input : nullptr;
    if (input) freerdp_input_send_mouse_event(input, flags, x, y);
}

- (void)sendVerticalScroll:(int16_t)delta atX:(uint16_t)x y:(uint16_t)y {
    UINT16 amount = static_cast<UINT16>(MIN(abs(delta), 0x00ff));
    UINT16 flags = PTR_FLAGS_WHEEL | amount;
    if (delta < 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE;
    std::lock_guard<std::mutex> guard(_instanceMutex);
    rdpInput *input = (_instance && _instance->context) ? _instance->context->input : nullptr;
    if (input) freerdp_input_send_mouse_event(input, flags, x, y);
}

- (void)sendHorizontalScroll:(int16_t)delta atX:(uint16_t)x y:(uint16_t)y {
    UINT16 amount = static_cast<UINT16>(MIN(abs(delta), 0x00ff));
    UINT16 flags = PTR_FLAGS_HWHEEL | amount;
    if (delta < 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE;
    std::lock_guard<std::mutex> guard(_instanceMutex);
    rdpInput *input = (_instance && _instance->context) ? _instance->context->input : nullptr;
    if (input) freerdp_input_send_mouse_event(input, flags, x, y);
}

- (void)sendControlAltDelete {
    [self sendScanCode:RDP_SCANCODE_LCONTROL keyDown:YES];
    [self sendScanCode:RDP_SCANCODE_LMENU keyDown:YES];
    [self sendScanCode:RDP_SCANCODE_DELETE keyDown:YES];
    [self sendScanCode:RDP_SCANCODE_DELETE keyDown:NO];
    [self sendScanCode:RDP_SCANCODE_LMENU keyDown:NO];
    [self sendScanCode:RDP_SCANCODE_LCONTROL keyDown:NO];
}
@end
