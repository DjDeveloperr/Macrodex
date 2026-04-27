import CoreFoundation
import Foundation

enum VoiceSessionControl {
    static let realtimeFeatureName = "realtime_conversation"
    static let defaultPrompt = "You are Macrodex's live voice agent. Keep responses short, spoken, and conversational. Avoid markdown and code formatting unless explicitly asked."

    /// Build a voice prompt for the local on-device agent server.
    static func buildPrompt() -> String {
        return """
        \(defaultPrompt)

        When using the codex tool, use the local server on this iPhone. \
        You may call `list_sessions` to find recent chats; always give the user a short spoken summary of what you found. Do not stop after the tool result alone.
        """
    }

    private static let appGroupSuite = MacrodexPalette.appGroupSuite
    private static let endRequestKey = "voice_session.end_request_token"
    static let endRequestDarwinNotification = "com.dj.Macrodex.voice_session.end_request"

    static func requestEnd() {
        let token = UUID().uuidString
        UserDefaults(suiteName: appGroupSuite)?.set(token, forKey: endRequestKey)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(endRequestDarwinNotification as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    static func pendingEndRequestToken(after lastSeenToken: String?) -> String? {
        guard let token = UserDefaults(suiteName: appGroupSuite)?.string(forKey: endRequestKey),
              !token.isEmpty,
              token != lastSeenToken else {
            return nil
        }
        return token
    }
}
