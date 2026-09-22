#import "DFRMirror.h"

#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <os/log.h>

/// Second-generation simulator. The third argument must match.
/// Legacy DFRSetStatus / SLSDFRDisplayStreamCreate is intentionally not called:
/// that path blanks the Touch Bar on some 16-inch MacBook Pro models.
static const int kDFRSecondGeneration = 3;

typedef id (*DFRCreateSimulatorFn)(int generation, id properties, int sameAsGeneration);
typedef id (*DFRGetTouchBarFn)(id simulator);
typedef BOOL (*DFRPostEventFn)(id simulator, NSEventType type, NSPoint point);
typedef CGDisplayStreamRef (*DFRCreateStreamFn)(id touchBar, int displayID, dispatch_queue_t queue, CGDisplayStreamFrameAvailableHandler handler);
typedef void (*DFRInvalidateFn)(id simulator);
typedef CGSize (*DFRScreenSizeFn)(void);

static os_log_t DFRLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.touchbarpill.TouchBarPill", "DFR");
    });
    return log;
}

static NSString *DFRFrameworkPath(void) {
    return @"/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation";
}

@interface DFRMirror ()
@property (nonatomic, readwrite, copy) NSString *statusMessage;
@property (nonatomic, readwrite) BOOL hasFrame;
@property (nonatomic, readwrite) BOOL simulatorReady;
@property (nonatomic, readwrite) BOOL clicksEnabled;
@property (nonatomic, readwrite) CGSize touchBarPointSize;
@property (nonatomic, readwrite) NSInteger lastSurfaceWidth;
@property (nonatomic, readwrite) NSInteger lastSurfaceHeight;
@property (nonatomic, copy, nullable) CGDisplayStreamFrameAvailableHandler frameHandler;
@property (nonatomic, strong, nullable) id simulator;
@property (nonatomic, strong, nullable) id touchBar;
@property (nonatomic, strong, nullable) CIContext *ciContext;
@property (nonatomic, weak) NSView *streamView;
@end

@implementation DFRMirror {
    CGDisplayStreamRef _displayStream;
    void *_framework;
    DFRCreateSimulatorFn _create;
    DFRGetTouchBarFn _getTouchBar;
    DFRPostEventFn _post;
    DFRCreateStreamFn _createStream;
    DFRInvalidateFn _invalidate;
    DFRScreenSizeFn _screenSize;
    BOOL _symCreate;
    BOOL _symGetTouchBar;
    BOOL _symPost;
    BOOL _symCreateStream;
    BOOL _symInvalidate;
    BOOL _symScreenSize;
    NSInteger _frameCount;
    NSInteger _blitFailures;
    int _lastStreamStatus;
    NSString *_loadedPath;
    NSString *_dlError;
    BOOL _loggedFirstFrame;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusMessage = @"Not started.";
        _touchBarPointSize = CGSizeMake(1004, 30);
        _dlError = @"";
        _loadedPath = @"";
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_framework) {
        dlclose(_framework);
        _framework = NULL;
    }
}

#pragma mark - Public

- (void)attachStreamToView:(NSView *)view {
    self.streamView = view;
    view.wantsLayer = YES;
    view.layer.contentsGravity = kCAGravityResize;
    view.layer.magnificationFilter = kCAFilterLinear;
    view.layer.minificationFilter = kCAFilterLinear;
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }

    [self stop];
    _frameCount = 0;
    _blitFailures = 0;
    _loggedFirstFrame = NO;
    self.hasFrame = NO;
    self.simulatorReady = NO;
    self.clicksEnabled = NO;
    self.lastSurfaceWidth = 0;
    self.lastSurfaceHeight = 0;

    if (![self loadSymbols]) {
        [self publish];
        return;
    }

    id simulator = _create(kDFRSecondGeneration, nil, kDFRSecondGeneration);
    if (!simulator) {
        self.statusMessage = @"The Touch Bar simulator did not start. Quit Touché if it is open, then choose Try Again. The gen-3 entry point returned nil.";
        os_log_error(DFRLog(), "DFRTouchBarSimulatorCreate returned nil");
        [self publish];
        return;
    }
    self.simulator = simulator;
    self.touchBarPointSize = [self resolvePointSize];

    id touchBar = _getTouchBar(simulator);
    if (!touchBar) {
        self.statusMessage = @"The simulator started but did not hand back a Touch Bar object.";
        os_log_error(DFRLog(), "DFRTouchBarSimulatorGetTouchBar returned nil");
        [self stop];
        [self publish];
        return;
    }
    self.touchBar = touchBar;

    __weak DFRMirror *weakSelf = self;
    CGDisplayStreamFrameAvailableHandler handler = ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
        (void)displayTime;
        (void)update;
        DFRMirror *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        @autoreleasepool {
            [strongSelf handleFrameWithStatus:status surface:surface];
        }
    };
    // The function pointer hides the block from ARC. Keep an explicit heap copy.
    self.frameHandler = [handler copy];

    CGDisplayStreamRef stream = _createStream(touchBar, 0, dispatch_get_main_queue(), self.frameHandler);
    if (!stream) {
        self.statusMessage = @"The simulator started, but DFRTouchBarCreateDisplayStream returned NULL. This macOS build may have changed the stream entry point.";
        os_log_error(DFRLog(), "DFRTouchBarCreateDisplayStream returned NULL");
        [self stop];
        [self publish];
        return;
    }
    _displayStream = stream;

    CGError error = CGDisplayStreamStart(stream);
    if (error != kCGErrorSuccess) {
        self.statusMessage = [NSString stringWithFormat:@"The Touch Bar display stream refused to start (CGError %d).", (int)error];
        os_log_error(DFRLog(), "CGDisplayStreamStart failed: %d", (int)error);
        [self stop];
        [self publish];
        return;
    }

    self.simulatorReady = YES;
    self.clicksEnabled = (_post != NULL);
    if (self.clicksEnabled) {
        self.statusMessage = @"Waiting for the adaptive Touch Bar. Press fn, or focus an app that shows Touch Bar controls.";
    } else {
        self.statusMessage = @"The picture stream is attached, but click forwarding is missing (DFRTouchBarSimulatorPostEventWithMouseActivity).";
    }
    os_log_info(DFRLog(), "simulator started, point size %.1f x %.1f, clicks %d",
                self.touchBarPointSize.width, self.touchBarPointSize.height, self.clicksEnabled);
    [self publish];
}

- (void)stop {
    if (_displayStream) {
        CGDisplayStreamStop(_displayStream);
        CFRelease(_displayStream);
        _displayStream = NULL;
    }
    self.frameHandler = nil;

    if (self.simulator && _invalidate) {
        _invalidate(self.simulator);
    }
    self.simulator = nil;
    self.touchBar = nil;
    self.simulatorReady = NO;
    self.clicksEnabled = NO;
    self.hasFrame = NO;

    NSView *view = self.streamView;
    if (view.layer) {
        view.layer.contents = nil;
    }
}

- (void)postMouseEvent:(NSEvent *)event inView:(NSView *)view {
    if (!_post || !self.simulator || !view) {
        return;
    }
    NSRect bounds = view.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) {
        return;
    }
    CGSize size = self.touchBarPointSize;
    if (size.width < 1 || size.height < 1) {
        size = CGSizeMake(1004, 30);
    }

    NSPoint local = [view convertPoint:event.locationInWindow fromView:nil];
    CGFloat x = (local.x / bounds.size.width) * size.width;
    CGFloat y = (local.y / bounds.size.height) * size.height;
    // AppKit views are y-up. jslegendre's on-screen simulator posts those
    // points unchanged. PinchBar's Vision path sends y-down. Full-height
    // Touch Bar buttons work either way; flip if a control is vertically wrong.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"FlipTouchBarY"]) {
        y = size.height - y;
    }
    x = MIN(MAX(x, 0), size.width);
    y = MIN(MAX(y, 0), size.height);
    _post(self.simulator, event.type, NSMakePoint(x, y));
}

- (NSString *)diagnosticSummary {
    return [NSString stringWithFormat:
            @"frameworkLoaded: %@\n"
            @"path: %@\n"
            @"dlerror: %@\n"
            @"symbol create: %@\n"
            @"symbol getTouchBar: %@\n"
            @"symbol postEvent: %@\n"
            @"symbol createStream: %@\n"
            @"symbol invalidate: %@\n"
            @"symbol screenSize: %@\n"
            @"simulatorReady: %@\n"
            @"clicksEnabled: %@\n"
            @"hasFrame: %@\n"
            @"frames: %ld\n"
            @"blitFailures: %ld\n"
            @"pointSize: %.1f x %.1f\n"
            @"surface: %ld x %ld\n"
            @"lastStreamStatus: %d\n"
            @"FlipTouchBarY: %@\n"
            @"FlipStreamVertically: %@\n"
            @"status: %@",
            _framework ? @"yes" : @"no",
            _loadedPath ?: @"",
            _dlError.length ? _dlError : @"(none)",
            _symCreate ? @"yes" : @"no",
            _symGetTouchBar ? @"yes" : @"no",
            _symPost ? @"yes" : @"no",
            _symCreateStream ? @"yes" : @"no",
            _symInvalidate ? @"yes" : @"no",
            _symScreenSize ? @"yes" : @"no",
            self.simulatorReady ? @"yes" : @"no",
            self.clicksEnabled ? @"yes" : @"no",
            self.hasFrame ? @"yes" : @"no",
            (long)_frameCount,
            (long)_blitFailures,
            self.touchBarPointSize.width,
            self.touchBarPointSize.height,
            (long)self.lastSurfaceWidth,
            (long)self.lastSurfaceHeight,
            _lastStreamStatus,
            [[NSUserDefaults standardUserDefaults] boolForKey:@"FlipTouchBarY"] ? @"yes" : @"no",
            [[NSUserDefaults standardUserDefaults] boolForKey:@"FlipStreamVertically"] ? @"yes" : @"no",
            self.statusMessage ?: @""];
}

#pragma mark - Symbols

- (BOOL)loadSymbols {
    if (_create && _getTouchBar && _createStream) {
        return YES;
    }

    if (!_framework) {
        const char *path = DFRFrameworkPath().UTF8String;
        _framework = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!_framework) {
            const char *error = dlerror();
            _dlError = error ? [NSString stringWithUTF8String:error] : @"dlopen failed";
            _loadedPath = DFRFrameworkPath();
            self.statusMessage = @"DFRFoundation is not on this Mac, so there is no Touch Bar simulator to mirror. The pill still works; the picture does not. A dead Touch Bar OLED is fine — a missing framework is not.";
            os_log_error(DFRLog(), "dlopen failed: %{public}@", _dlError);
            return NO;
        }
        _loadedPath = DFRFrameworkPath();
        _dlError = @"";
    }

    _dlError = @"";
    _create = (DFRCreateSimulatorFn)[self lookup:"DFRTouchBarSimulatorCreate" found:&_symCreate];
    _getTouchBar = (DFRGetTouchBarFn)[self lookup:"DFRTouchBarSimulatorGetTouchBar" found:&_symGetTouchBar];
    _post = (DFRPostEventFn)[self lookup:"DFRTouchBarSimulatorPostEventWithMouseActivity" found:&_symPost];
    _createStream = (DFRCreateStreamFn)[self lookup:"DFRTouchBarCreateDisplayStream" found:&_symCreateStream];
    _invalidate = (DFRInvalidateFn)[self lookup:"DFRTouchBarSimulatorInvalidate" found:&_symInvalidate];
    _screenSize = (DFRScreenSizeFn)[self lookup:"DFRGetScreenSize" found:&_symScreenSize];

    if (!_create || !_getTouchBar || !_createStream) {
        self.statusMessage = @"DFRFoundation loaded, but the gen-3 simulator symbols are missing. This macOS version removed DFRTouchBarSimulatorCreate. The legacy stream API is not used, because it blanks some real Touch Bars.";
        os_log_error(DFRLog(), "missing required symbol");
        return NO;
    }
    if (!_post) {
        os_log_error(DFRLog(), "click symbol missing; stream will be view-only");
    }
    return YES;
}

- (void *)lookup:(const char *)name found:(BOOL *)found {
    dlerror();
    void *symbol = dlsym(_framework, name);
    if (found) {
        *found = symbol != NULL;
    }
    if (!symbol) {
        const char *error = dlerror();
        NSString *message = error ? [NSString stringWithUTF8String:error] : @"symbol was NULL";
        NSString *line = [NSString stringWithFormat:@"%s: %@", name, message];
        _dlError = _dlError.length ? [_dlError stringByAppendingFormat:@"\n%@", line] : line;
        os_log_error(DFRLog(), "dlsym failed: %{public}@", line);
        return NULL;
    }
    return symbol;
}

- (CGSize)resolvePointSize {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat overrideW = [defaults doubleForKey:@"TouchBarPointWidth"];
    CGFloat overrideH = [defaults doubleForKey:@"TouchBarPointHeight"];
    if (overrideW >= 100 && overrideH >= 10) {
        os_log_info(DFRLog(), "using TouchBarPointWidth/Height override %.1f x %.1f", overrideW, overrideH);
        return CGSizeMake(overrideW, overrideH);
    }

    // Both public simulators post into a 1004×30 point space. DFRGetScreenSize
    // sometimes reports that, and sometimes reports pixels or garbage. Only
    // trust a result that looks like a point size (one row, a few hundred to
    // ~1400 points wide).
    if (_screenSize) {
        CGSize reported = _screenSize();
        os_log_info(DFRLog(), "DFRGetScreenSize -> %.1f x %.1f", reported.width, reported.height);
        if (reported.width >= 600 && reported.width <= 1400 && reported.height >= 20 && reported.height <= 45) {
            return reported;
        }
    }
    return CGSizeMake(1004, 30);
}

#pragma mark - Frames

- (void)handleFrameWithStatus:(CGDisplayStreamFrameStatus)status surface:(IOSurfaceRef)surface {
    _lastStreamStatus = (int)status;
    if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface) {
        return;
    }

    NSInteger width = (NSInteger)IOSurfaceGetWidth(surface);
    NSInteger height = (NSInteger)IOSurfaceGetHeight(surface);
    if (width < 2 || height < 2) {
        return;
    }

    CIImage *image = [CIImage imageWithIOSurface:surface];
    if (!image) {
        [self noteBlitFailure:@"Core Image could not read a Touch Bar frame."];
        return;
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"FlipStreamVertically"]) {
        image = [image imageByApplyingOrientation:kCGImagePropertyOrientationDownMirrored];
    }
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) {
        [self noteBlitFailure:@"A Touch Bar frame had an empty image extent."];
        return;
    }
    if (!self.ciContext) {
        self.ciContext = [CIContext context];
    }
    CGImageRef picture = [self.ciContext createCGImage:image fromRect:extent];
    if (!picture) {
        [self noteBlitFailure:@"Core Image could not draw a Touch Bar frame."];
        return;
    }

    NSView *view = self.streamView;
    if (view) {
        if (!view.wantsLayer) {
            view.wantsLayer = YES;
        }
        view.layer.contentsScale = 1;
        view.layer.contentsGravity = kCAGravityResize;
        view.layer.contents = (__bridge id)picture;
    }
    CGImageRelease(picture);

    self.lastSurfaceWidth = width;
    self.lastSurfaceHeight = height;
    _frameCount += 1;
    if (!_loggedFirstFrame) {
        _loggedFirstFrame = YES;
        os_log_info(DFRLog(), "first frame %ld x %ld", (long)width, (long)height);
    }
    if (!self.hasFrame) {
        self.hasFrame = YES;
        self.simulatorReady = YES;
        self.statusMessage = self.clicksEnabled
            ? @"Mirroring the live adaptive Touch Bar."
            : @"Mirroring the Touch Bar picture. Clicks are unavailable on this OS build.";
        [self publish];
    }
}

- (void)noteBlitFailure:(NSString *)message {
    _blitFailures += 1;
    os_log_error(DFRLog(), "blit failed: %{public}@", message);
    if (self.hasFrame || _blitFailures > 1) {
        return;
    }
    self.statusMessage = message;
    [self publish];
}

- (void)publish {
    void (^handler)(void) = self.stateHandler;
    if (handler) {
        handler();
    }
}

@end
