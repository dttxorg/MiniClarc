import Foundation

/// Rough token count estimator. Uses a conservative chars/3 ratio
/// to slightly over-estimate mixed CJK/ASCII content (CJK is denser
/// than 3 chars/token in reality, so this errs on the side of
/// triggering compaction earlier).
public struct TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        max(0, text.count / 3)
    }

    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimate($1.content) }
    }
}
