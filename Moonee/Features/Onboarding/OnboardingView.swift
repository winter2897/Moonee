import SwiftData
import SwiftUI

extension View {
    /// First-launch onboarding (spec §7) over the whole app until it is finished or skipped. Apply once on the root view.
    /// A store that already has transactions (an existing user) never sees it.
    func onboarding() -> some View { modifier(OnboardingModifier()) }
}

private struct OnboardingModifier: ViewModifier {
    @AppStorage(Prefs.onboardingDone) private var done = false
    @AppStorage(Prefs.termsVersion) private var termsAccepted = 0
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(!done || Terms.needsConsent(accepted: termsAccepted))
            .overlay {
                // An overlay, not a cover: the first frame is already onboarding, with no slide-up over the dashboard.
                if !done {
                    OnboardingFlow { withAnimation(.smooth) { done = true } }
                        .transition(.opacity)
                } else if Terms.needsConsent(accepted: termsAccepted) {
                    // An existing user (or one who skipped onboarding) who hasn't accepted this version of the terms.
                    ConsentView(updated: termsAccepted > 0)
                        .transition(.opacity)
                }
            }
            .onAppear {
                if !done, ((try? context.fetchCount(FetchDescriptor<Txn>())) ?? 0) > 0 { done = true }
            }
    }
}

/// Terms consent (until accepted), step 1 (profile screen), then steps 2–4 as a scripted chat.
struct OnboardingFlow: View {
    var onFinish: () -> Void
    @State private var profileDone = false
    @AppStorage(Prefs.termsVersion) private var termsAccepted = 0

    var body: some View {
        ZStack {
            MooneeBackground()
            if Terms.needsConsent(accepted: termsAccepted) {
                ConsentView().transition(.opacity)
            } else if profileDone {
                OnboardingChat(onFinish: onFinish).transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ProfileSetupView { withAnimation(.smooth) { profileDone = true } }
            }
        }
    }
}

// MARK: - Step 1: profile setup (mockup "Mint Moonee Profile Setup Onboarding")

struct ProfileSetupView: View {
    var onNext: () -> Void
    @State private var name = UserDefaults.standard.string(forKey: Prefs.profileName) ?? ""
    @State private var avatar = UserDefaults.standard.string(forKey: Prefs.profileAvatar).flatMap { $0.isEmpty ? nil : $0 } ?? ProfileAvatars.all[0]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.title3.weight(.semibold)).foregroundStyle(Color.brandYellow)
                    Text(verbatim: "Moonee").font(.screenTitle).foregroundStyle(Color.brandDeep)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: "Moonee"))
                Text("Profile setup", tableName: "Onboarding")
                    .font(.title.bold()).foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Moonee only needs your name and an avatar. Everything stays on this device, no sign-in needed.", tableName: "Onboarding")
                    .font(.bodyText).foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                MooneeHero(mood: .greeting, compact: true) // compact so the whole step fits one screen, like the mockup
                SpeechBubble(Text("Hi! Before we start, let's set up your profile", tableName: "Onboarding"))
                    .frame(maxWidth: 300)

                ProfileForm(name: $name, avatar: $avatar)
                    .padding(.top, 4)

                VStack(spacing: 8) {
                    Button(action: save) { Text("Continue", tableName: "Onboarding") }
                        .buttonStyle(MooneeButtonStyle())
                    Button(action: onNext) { Text("Later", tableName: "Onboarding") }
                        .buttonStyle(SecondaryCapsuleStyle())
                }
                .padding(.top, 4)

                StepProgress(step: 1).padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func save() {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Prefs.profileName)
        UserDefaults.standard.set(avatar, forKey: Prefs.profileAvatar)
        onNext()
    }
}

/// Moonee's line under the character, with a little tail pointing up at it (mockup).
struct SpeechBubble: View {
    let text: Text
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.bodyText).foregroundStyle(Color.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color.surface, in: .rect(cornerRadius: 26))
            .background(alignment: .top) {
                Triangle().fill(Color.surface).frame(width: 18, height: 9).offset(y: -8)
            }
            .shadow(color: .brandDeep.opacity(0.08), radius: 10, y: 4)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: .init(x: r.midX, y: r.minY))
            p.addLine(to: .init(x: r.maxX, y: r.maxY))
            p.addLine(to: .init(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// "Later": white capsule, same height as the primary button.
struct SecondaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.surface.opacity(0.85), in: .capsule)
            .shadow(color: .brandDeep.opacity(0.06), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 4 bars + "Step n/4" (mockup).
struct StepProgress: View {
    let step: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { i in
                    Capsule().fill(i <= step ? AnyShapeStyle(LinearGradient.brand) : AnyShapeStyle(Color.track))
                        .frame(width: 38, height: 6)
                }
            }
            Text("Step \(step)/4", tableName: "Onboarding").font(.caption).foregroundStyle(Color.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step) of 4", tableName: "Onboarding"))
    }
}
