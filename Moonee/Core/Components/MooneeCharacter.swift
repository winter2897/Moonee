import SwiftUI
import ImageIO

/// The 8 character states of spec §D.
enum MooneeMood: String, CaseIterable, Identifiable {
    case greeting   // onboarding, empty chat
    case listening  // mic on
    case thinking   // parsing / calling AI
    case happy      // transaction saved
    case celebrate  // goal reached, under budget
    case worried    // jar ≥ 80% or over
    case sleepy     // empty states, evening reminder
    case confused   // AI did not understand, offline

    var id: String { rawValue }
    var imageName: String { "moonee.\(rawValue)" }
}

/// Full-size character. Plays the animated version unless Reduce Motion is on (then the static pose).
struct MooneeCharacter: View {
    let mood: MooneeMood
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated, !reduceMotion, let anim = MooneeAnimation.load(mood) {
                TimelineView(.periodic(from: .now, by: anim.frameDuration)) { context in
                    Image(decorative: anim.frame(at: context.date), scale: 1).resizable().scaledToFit()
                }
            } else {
                Image(mood.imageName).resizable().scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}

/// The character on a tab's hills, under the header. 104 pt visible (mockups); `compact` 76 pt (Budget).
/// The images are cropped to the character, so the frame height is the visible height.
struct MooneeHero: View {
    let mood: MooneeMood
    var compact = false

    var body: some View {
        let height: CGFloat = compact ? 76 : 104
        MooneeCharacter(mood: mood)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .background(alignment: .bottom) {
                // Hills run edge to edge behind the lower half and fade out, so there is no seam under the hero.
                Hills()
                    .frame(height: height * 0.72)
                    .padding(.horizontal, -16)
                    .opacity(0.55)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
    }
}

/// Small face for the chat and the tab bar; reads at 24–28 pt.
struct MooneeAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        Image("moonee.avatar").resizable().scaledToFit()
            .padding(size * 0.1)
            .frame(width: size, height: size)
            .background(Color.brandMintSoft, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Decoded frames of the animated APNG data assets (`moonee.<mood>.anim`).
/// The source GIFs had a solid red background; they were keyed to real alpha and re-encoded as APNG.
final class MooneeAnimation {
    let frames: [CGImage]
    let frameDuration: Double

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        frames = (0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
        guard frames.count > 1 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        // ponytail: one delay for all frames (the source GIFs use a constant delay).
        let delay = (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0.15
        frameDuration = max(0.04, delay)
    }

    func frame(at date: Date) -> CGImage {
        frames[Int(date.timeIntervalSinceReferenceDate / frameDuration) % frames.count]
    }

    @MainActor private static var cache: [MooneeMood: MooneeAnimation] = [:]

    @MainActor static func load(_ mood: MooneeMood) -> MooneeAnimation? {
        if let hit = cache[mood] { return hit }
        guard let data = NSDataAsset(name: mood.imageName + ".anim")?.data, let anim = MooneeAnimation(data: data) else { return nil }
        cache[mood] = anim
        return anim
    }
}
