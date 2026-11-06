import SwiftUI

/// The built-in avatars (`Assets.xcassets/Avatar`), in picker order. Stored by asset name in `Prefs.profileAvatar`.
enum ProfileAvatars {
    static let all = ["avatar.boy", "avatar.girlYellow", "avatar.boyCap", "avatar.girlPink", "avatar.cat", "avatar.dog", "avatar.plant"]
}

/// A round avatar; a person glyph on mint when none is chosen yet.
struct ProfileAvatarImage: View {
    let avatar: String
    var size: CGFloat = 56

    var body: some View {
        Group {
            if ProfileAvatars.all.contains(avatar) {
                Image(avatar).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color.brandDeep)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.brandMintSoft)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// Name field + avatar picker (spec §7 step 0). Standalone so onboarding (S10) reuses it:
/// `ProfileForm(name: $name, avatar: $avatar)`; it writes nothing itself.
struct ProfileForm: View {
    @Binding var name: String
    @Binding var avatar: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("Display name", tableName: "Account").font(.headline) } icon: { IconBadge(symbol: "person.fill", color: .brandDeep, size: 32) }
            TextField(String(localized: "Your name", table: "Account"), text: $name)
                .textContentType(.name)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.track.opacity(0.5), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.track))

            Label { Text("Choose avatar", tableName: "Account").font(.headline) } icon: { IconBadge(symbol: "photo", color: .brandDeep, size: 32) }
            AvatarPicker(selection: $avatar)

            Label { Text("Stored on this device only · No account needed", tableName: "Account") } icon: { Image(systemName: "checkmark.shield").foregroundStyle(Color.brandDeep) }
                .font(.footnote).foregroundStyle(Color.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.brandMintSoft.opacity(0.6), in: .capsule)
        }
        .card()
    }
}

/// The chosen avatar large on the left, the others in a 3-column grid (as in the onboarding mockup).
struct AvatarPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 16) {
            ProfileAvatarImage(avatar: selection, size: 110)
                .overlay(alignment: .bottomTrailing) {
                    if ProfileAvatars.all.contains(selection) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, Color.brandPrimary)
                            .background(.white, in: .circle)
                    }
                }
            Divider().frame(height: 100)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 10), count: 3), spacing: 10) {
                ForEach(ProfileAvatars.all.filter { $0 != selection }, id: \.self) { name in
                    Button {
                        withAnimation(.snappy) { selection = name }
                    } label: {
                        ProfileAvatarImage(avatar: name, size: 54)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Avatar \((ProfileAvatars.all.firstIndex(of: name) ?? 0) + 1)", tableName: "Account"))
                }
            }
        }
    }
}

/// Account → profile. Edits apply as you type.
struct ProfileEditView: View {
    @AppStorage(Prefs.profileName) private var name = ""
    @AppStorage(Prefs.profileAvatar) private var avatar = ""
    @ScaledMetric private var cell = 56

    var body: some View {
        Form {
            Section {
                ProfileAvatarImage(avatar: avatar, size: 96)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section {
                TextField(String(localized: "Your name", table: "Account"), text: $name)
                    .textContentType(.name)
            } header: {
                Text("Display name", tableName: "Account")
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 12)], spacing: 12) {
                    ForEach(Array(ProfileAvatars.all.enumerated()), id: \.element) { i, a in
                        Button { avatar = a } label: {
                            ProfileAvatarImage(avatar: a, size: cell)
                                .padding(3)
                                .overlay { if a == avatar { Circle().stroke(.tint, lineWidth: 3) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Avatar \(i + 1)", tableName: "Account"))
                        .accessibilityAddTraits(a == avatar ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Choose avatar", tableName: "Account")
            } footer: {
                Text("Stored on this device only · No account needed", tableName: "Account")
            }
        }
        .navigationTitle(Text("Profile", tableName: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ProfileEditView() }
}
