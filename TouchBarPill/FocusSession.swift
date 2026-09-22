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
        }
    }

    /// Opacity hint for the label (paused is slightly dimmer).
    var labelAlpha: CGFloat {
        switch phase {
        case .idle: return 0.88
        case .running: return 0.94
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
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.postChange()
        }
        timer.tolerance = 0.05
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
