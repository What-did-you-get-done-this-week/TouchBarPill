import AppKit
import Foundation

enum FocusPhase: Equatable {
    case idle
    case running
    case paused
}

/// In-memory open-ended timer. No goal, no done state, no other-app watching.
final class FocusSession {
    static let shared = FocusSession()
    static let didChange = Notification.Name("FocusSessionDidChange")

    private(set) var phase: FocusPhase = .idle
    /// Accumulated elapsed seconds while running or paused.
    private(set) var elapsed: TimeInterval = 0
    private var runStartedAt: Date?
    private var tick: Timer?

    private init() {
        // 0.4.1 stored a 25/50 goal. 0.4.2 is open-ended only.
        UserDefaults.standard.removeObject(forKey: "FocusGoalMinutes")
    }

    /// Live elapsed including the current running segment.
    var displayElapsed: TimeInterval {
        guard phase == .running, let runStartedAt else { return elapsed }
        return elapsed + Date().timeIntervalSince(runStartedAt)
    }

    /// Whole minutes already elapsed. The center label uses this and does not tick seconds.
    var wholeMinutes: Int {
        ZonePolicy.wholeMinutes(elapsed: displayElapsed)
    }

    /// Center title. Idle keeps the product name. A session shows whole minutes only.
    var notchLabel: String {
        switch phase {
        case .idle:
            return L("Touch Bar")
        case .running, .paused:
            return ZonePolicy.minuteLabel(elapsed: displayElapsed)
        }
    }

    /// Opacity hint for the center label. Paused minutes stay put and read quieter.
    var labelAlpha: CGFloat {
        switch phase {
        case .idle: return 0.92
        case .running: return 0.96
        case .paused: return 0.62
        }
    }

    /// Single click on the collapsed notch: start / pause / resume.
    func toggleFromClick() {
        switch phase {
        case .idle:
            start()
        case .running:
            pause()
        case .paused:
            resume()
        }
    }

    func start() {
        guard phase == .idle || phase == .paused else { return }
        if phase == .idle {
            elapsed = 0
        }
        phase = .running
        runStartedAt = Date()
        startTick()
        postChange()
    }

    func pause() {
        guard phase == .running else { return }
        if let runStartedAt {
            elapsed += Date().timeIntervalSince(runStartedAt)
        }
        self.runStartedAt = nil
        phase = .paused
        stopTick()
        postChange()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .running
        runStartedAt = Date()
        startTick()
        postChange()
    }

    func reset() {
        stopTick()
        phase = .idle
        elapsed = 0
        runStartedAt = nil
        postChange()
    }

    private func startTick() {
        stopTick()
        scheduleMinuteTick()
    }

    /// Redraw when the whole minute changes. No per-second tick.
    private func scheduleMinuteTick() {
        stopTick()
        guard phase == .running else { return }
        let wait = ZonePolicy.secondsUntilNextMinute(elapsed: displayElapsed)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, self.phase == .running else { return }
            self.postChange()
            self.scheduleMinuteTick()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
