import AppKit
import Foundation

/// Manual focus timer for the collapsed notch. No Accessibility, no app watching.
enum FocusGoal: Int, CaseIterable {
    case off = 0
    case minutes25 = 25
    case minutes50 = 50

    var menuTitle: String {
        switch self {
        case .off: return L("Goal: Off")
        case .minutes25: return L("Goal: 25 min")
        case .minutes50: return L("Goal: 50 min")
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return L("Off")
        case .minutes25: return L("25 min")
        case .minutes50: return L("50 min")
        }
    }
}

enum FocusPhase: Equatable {
    case idle
    case running
    case paused
    case done
}

/// In-memory session. Only the goal preference is persisted.
final class FocusSession {
    static let shared = FocusSession()
    static let didChange = Notification.Name("FocusSessionDidChange")
    static let goalKey = "FocusGoalMinutes"

    private(set) var phase: FocusPhase = .idle
    /// Accumulated elapsed seconds while running/paused/done.
    private(set) var elapsed: TimeInterval = 0
    private var runStartedAt: Date?
    private var tick: Timer?

    var goal: FocusGoal {
        get {
            let raw = UserDefaults.standard.integer(forKey: Self.goalKey)
            return FocusGoal(rawValue: raw) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.goalKey)
            postChange()
            checkGoal()
        }
    }

    /// Live elapsed including the current running segment.
    var displayElapsed: TimeInterval {
        guard phase == .running, let runStartedAt else { return elapsed }
        return elapsed + Date().timeIntervalSince(runStartedAt)
    }

    var formattedTime: String {
        let total = max(0, Int(displayElapsed.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Compact notch label for the current phase.
    var notchLabel: String {
        switch phase {
        case .idle:
            return L("Touch Bar")
        case .running:
            return formattedTime
        case .paused:
            return "⏸ \(formattedTime)"
        case .done:
            return "✓ \(L("Done"))"
        }
    }

    /// Opacity hint for the label (paused is slightly dimmer).
    var labelAlpha: CGFloat {
        switch phase {
        case .idle: return 0.88
        case .running: return 0.94
        case .paused: return 0.62
        case .done: return 0.9
        }
    }

    /// Single click on the collapsed notch: start / pause / clear-done-and-start.
    func toggleFromClick() {
        switch phase {
        case .idle:
            start()
        case .running:
            pause()
        case .paused:
            resume()
        case .done:
            reset()
            start()
        }
    }

    func start() {
        guard phase == .idle || phase == .paused || phase == .done else { return }
        if phase == .done || phase == .idle {
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
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickFired()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func tickFired() {
        checkGoal()
        postChange()
    }

    private func checkGoal() {
        guard phase == .running else { return }
        let minutes = goal.rawValue
        guard minutes > 0 else { return }
        if displayElapsed >= TimeInterval(minutes * 60) {
            if let runStartedAt {
                elapsed += Date().timeIntervalSince(runStartedAt)
            }
            self.runStartedAt = nil
            // Snap elapsed to the goal so the done state shows the target cleanly.
            elapsed = TimeInterval(minutes * 60)
            phase = .done
            stopTick()
            postChange()
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
