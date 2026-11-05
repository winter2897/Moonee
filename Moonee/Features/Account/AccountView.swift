import SwiftUI

struct AccountView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Image("Logo").resizable().frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Personal finance").font(.title3.weight(.bold))
                        Label("Data stays on this device (offline)", systemImage: "checkmark")
                            .labelStyle(TrailingIcon())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .card()

                // Each feature session owns its destination file; rows here stay stable.
                VStack(spacing: 0) {
                    AccountRow(symbol: "tag", title: "Categories") { CategoriesView() }
                    Divider().padding(.leading, 44)
                    AccountRow(symbol: "wallet.bifold", title: "Wallets") { WalletsView() }
                    Divider().padding(.leading, 44)
                    AccountRow(symbol: "square.stack.3d.up", title: "Customize jars") { JarSettingsView() }
                    Divider().padding(.leading, 44)
                    AccountRow(symbol: "arrow.triangle.branch", title: "Assign categories to jars") { JarMappingView() }
                    Divider().padding(.leading, 44)
                    AccountRow(symbol: "brain.head.profile", title: "Moonee assistant (AI)") { AISettingsView() }
                }
                .card(padding: 12)
            }
            .foregroundStyle(Color.mooneeInk)
            .mooneeScreen(String(localized: "Account"))
        }
    }
}

private struct AccountRow<Destination: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.mooneeGreen).frame(width: 30)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.foregroundStyle(Color.mooneeGreen).fontWeight(.bold)
        }
    }
}
