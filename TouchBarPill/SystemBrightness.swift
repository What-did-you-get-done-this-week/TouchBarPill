import CoreGraphics
import Darwin
import Foundation

/// Built-in display brightness via DisplayServices.
///
/// `IODisplaySetFloatParameter` has no `IODisplayConnect` service on this
/// Apple silicon panel. `DisplayServicesGetBrightness` /
/// `DisplayServicesSetBrightness` are resolved at runtime from
/// `/System/Library/PrivateFrameworks/DisplayServices.framework` and applied
/// to the built-in display (`CGDisplayIsBuiltin`). An external-only layout,
/// or a missing symbol, is a no-op. This does not scan other apps.
enum SystemBrightness {
    /// Same key-step the volume wing uses (~1/16).
    static let step: Float = 1.0 / 16.0

    /// Current built-in brightness in 0...1, or nil if it cannot be read.
    static func brightness() -> Float? {
        guard let display = builtinDisplay() else { return nil }
        return read(display)
    }

    /// Move brightness by `delta` (−1...1). Returns the level that was written.
    @discardableResult
    static func adjust(by delta: Float) -> Float? {
        guard delta.isFinite, let display = builtinDisplay(), let current = read(display) else { return nil }
        let next = min(max(current + delta, 0), 1)
        guard write(display, next) else { return nil }
        return next
    }

    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        for index in 0..<Int(count) where CGDisplayIsBuiltin(ids[index]) != 0 {
            return ids[index]
        }
        return nil
    }

    private static func read(_ display: CGDirectDisplayID) -> Float? {
        guard let get = symbols?.get else { return nil }
        var value: Float = -1
        let status = get(display, &value)
        guard status == 0, value >= 0, value <= 1.05 else { return nil }
        return min(max(value, 0), 1)
    }

    @discardableResult
    private static func write(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let set = symbols?.set else { return false }
        return set(display, value) == 0
    }

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let symbols: (get: GetFn, set: SetFn)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (
            unsafeBitCast(getSym, to: GetFn.self),
            unsafeBitCast(setSym, to: SetFn.self)
        )
    }()
}
