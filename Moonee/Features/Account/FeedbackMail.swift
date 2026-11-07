import MessageUI
import SwiftUI

/// Help & feedback (spec §6.5): a mail to the owner with what a bug report needs. Mail not set up: the same as a `mailto:` link.
enum FeedbackMail {
    static let address = "haiquantran2897@gmail.com"

    static var subject: String { "Moonee feedback (\(AppInfo.number) (\(AppInfo.build)))" }

    /// Room to write on top, then the facts (English: they are for the owner).
    @MainActor static var body: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        return """


        ---
        Moonee \(AppInfo.number) (\(AppInfo.build))
        \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Device: \(deviceModel)
        Language: \(lang) (\(Locale.current.identifier))
        """
    }

    @MainActor static var mailto: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return c.url ?? URL(string: "mailto:\(address)")!
    }

    /// "iPhone18,1" (the Simulator reports the model it simulates).
    static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// The Account row: Mail's composer, or the `mailto:` link when Mail can't send.
struct FeedbackRow: View {
    @State private var composing = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if MFMailComposeViewController.canSendMail() { composing = true } else { openURL(FeedbackMail.mailto) }
        } label: {
            SettingsLabel("Help & feedback", symbol: "questionmark", color: .teal)
        }
        .sheet(isPresented: $composing) { MailComposer(isPresented: $composing).ignoresSafeArea() }
    }
}

private struct MailComposer: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([FeedbackMail.address])
        vc.setSubject(FeedbackMail.subject)
        vc.setMessageBody(FeedbackMail.body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let isPresented: Binding<Bool>
        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            isPresented.wrappedValue = false
        }
    }
}
