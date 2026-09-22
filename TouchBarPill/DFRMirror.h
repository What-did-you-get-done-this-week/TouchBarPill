#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process client for the private Touch Bar simulator in DFRFoundation.
///
/// Symbols are resolved with dlopen/dlsym at runtime. The framework is not in
/// the public SDK, so the app still builds when the linker cannot see it, and
/// it still launches when a newer macOS has removed the symbols.
@interface DFRMirror : NSObject

/// Human-readable state for the expanded fallback and Preferences.
@property (nonatomic, readonly, copy) NSString *statusMessage;

/// YES after at least one display-stream frame has been drawn.
@property (nonatomic, readonly) BOOL hasFrame;

/// YES when the gen-3 simulator and its display stream are running.
@property (nonatomic, readonly) BOOL simulatorReady;

/// YES when mouse events can be posted into the simulator.
@property (nonatomic, readonly) BOOL clicksEnabled;

/// Point size used to map clicks. Defaults to 1004×30.
@property (nonatomic, readonly) CGSize touchBarPointSize;

/// Pixel size of the newest frame. Zero until a frame arrives.
@property (nonatomic, readonly) NSInteger lastSurfaceWidth;
@property (nonatomic, readonly) NSInteger lastSurfaceHeight;

/// Called on the main queue when readiness, the message, or the first frame changes.
@property (nonatomic, copy, nullable) void (^stateHandler)(void);

- (void)start;
- (void)stop;

/// View whose layer receives each frame. Weak.
- (void)attachStreamToView:(NSView *)view;

/// Forwards a mouse event in `view` into the simulator's Touch Bar coordinate space.
- (void)postMouseEvent:(NSEvent *)event inView:(NSView *)view;

- (NSString *)diagnosticSummary;

@end

NS_ASSUME_NONNULL_END
