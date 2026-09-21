import CoreGraphics

public enum MacSystemActivity {
    /// Seconds since the last hardware input in the combined login session.
    public static func idleSeconds() -> Double {
        guard let anyEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyEvent)
    }
}
