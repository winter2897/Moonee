import SwiftUI

// Placeholder: owned by the feature session that builds this screen.
struct BankLinkView: View {
    var body: some View {
        ContentUnavailableView("Sắp có", systemImage: "building.columns", description: Text("Liên kết ngân hàng"))
            .navigationTitle("Liên kết ngân hàng")
    }
}
