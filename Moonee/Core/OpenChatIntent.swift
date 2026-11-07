import AppIntents
import Observation

/// Where the app goes next, asked from outside: the `moonee://chat` deep link (widgets) and `OpenChatIntent`
/// (Control Center / Lock Screen control). `RootView` follows it. Compiled into the app and the widget extension.
@MainActor @Observable final class AppRoute {
    static let shared = AppRoute()
    /// Bumped to open the chat with the keyboard up.
    var composeRequest = 0
}

/// The "Log a transaction" control's action. It runs in the app (`openAppWhenRun`), which opens the chat composer.
/// (A control cannot use the system `OpenURLIntent`: the extension has no metadata for it.)
struct OpenChatIntent: AppIntent {
    static let title = LocalizedStringResource("Log a transaction", table: "Widgets")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        AppRoute.shared.composeRequest += 1
        return .result()
    }
}
