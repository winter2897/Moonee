import SwiftUI

extension View {
    /// Animated opening on a cold launch: Moonee pops up and waves, "Moonee" springs in letter by letter with a shimmer,
    /// the tagline tracks in, then the splash fades into the app (≈1.9 s, a tap skips it). Apply once, outermost, so it
    /// also covers onboarding and the app lock (Face ID can run underneath; nothing behind it ever flashes).
    /// Launch with `-splash.off YES` to skip it (screenshots).
    func splash() -> some View { modifier(SplashModifier()) }
}

private struct SplashModifier: ViewModifier {
    // @State on the root view survives background → foreground, so the splash only plays on a cold launch.
    @State private var showing = !UserDefaults.standard.bool(forKey: "splash.off")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(showing)
            .overlay {
                if showing {
                    SplashView { withAnimation(.easeOut(duration: 0.35)) { showing = false } }
                        .transition(.asymmetric(insertion: .identity,
                                                removal: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.08))))
                }
            }
    }
}

/// The first frame is the launch screen (`UILaunchScreen`: LaunchBackground + the `moonee.greeting` image at its own size,
/// centred), so the hand-off from iOS is seamless. Motion follows the Animos styles used in the dashboards.
struct SplashView: View {
    var finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 launch frame · 1 Moonee pops up · 2 name springs in · 3 shimmer + tagline.
    @State private var stage = 0
    @State private var finished = false

    private let letters = Array("Moonee")

    var body: some View {
        let lift: CGFloat = reduceMotion ? 0 : -64
        ZStack {
            Color.brandMint // = LaunchBackground
            MooneeBackground().opacity(stage >= 1 ? 1 : 0)
            // Soft glow that blooms behind Moonee.
            Circle()
                .fill(RadialGradient(colors: [Color.brandPrimaryLight.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .scaleEffect(stage >= 1 ? 1 : 0.5)
                .opacity(stage >= 1 ? 1 : 0)
                .offset(y: lift)
            moonee
                .scaleEffect(stage == 1 && !reduceMotion ? 1.1 : 1)
                .offset(y: stage >= 1 ? lift : 0)
            VStack(spacing: 4) {
                title
                Text("Your AI Money Buddy", tableName: "Splash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.inkSecondary)
                    .tracking(stage >= 3 || reduceMotion ? 0.2 : 8)
                    .blur(radius: stage >= 3 || reduceMotion ? 0 : 5)
                    .opacity(stage >= 3 ? 1 : 0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 24)
            .offset(y: reduceMotion ? 130 : 56)
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture(perform: end)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Moonee: Your AI Money Buddy")) // brand line, never translated
        .accessibilityAddTraits(.isStaticText)
        .task { await play() }
    }

    /// The launch image at its own point size until the pop, then the animated (waving) pose.
    @ViewBuilder private var moonee: some View {
        // A hard swap (no cross-fade), hidden by the pop.
        if stage == 0 {
            Image("moonee.greeting").transition(.identity)
        } else {
            MooneeCharacter(mood: .greeting).frame(width: 161, height: 136).transition(.identity)
        }
    }

    /// "Moonee": letters rise, unblur and spring in one after another, then a light sweeps across.
    private var title: some View {
        let shown = stage >= 2
        return letterRow(shown: shown)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.4)
                        .rotationEffect(.degrees(12))
                        .offset(x: stage >= 3 ? g.size.width * 1.1 : -g.size.width * 0.5)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: stage)
                }
                .mask(letterRow(shown: shown))
                .allowsHitTesting(false)
            }
    }

    private func letterRow(shown: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                Text(String(letters[i]))
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.brandDeep)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 26)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.6, anchor: .bottom)
                    .blur(radius: shown || reduceMotion ? 0 : 8)
                    .animation(reduceMotion ? .easeOut(duration: 0.3)
                                            : .spring(duration: 0.55, bounce: 0.45).delay(Double(i) * 0.06), value: shown)
            }
        }
        .fixedSize()
    }

    private func play() async {
        if reduceMotion {
            // A still Moonee and a simple fade.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.4)) { stage = 3 }
            try? await Task.sleep(for: .milliseconds(1100))
            end()
            return
        }
        // Wait out iOS's own launch-screen fade, or its snapshot ghosts under the pop.
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.spring(duration: 0.5, bounce: 0.5)) { stage = 1 }   // pop up
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { stage = 2 }   // settle; name springs in
        try? await Task.sleep(for: .milliseconds(520))
        withAnimation(.easeOut(duration: 0.6)) { stage = 3 }               // shimmer + tagline
        try? await Task.sleep(for: .milliseconds(800))
        end()
    }

    private func end() {
        guard !finished else { return }
        finished = true
        finish()
    }
}
