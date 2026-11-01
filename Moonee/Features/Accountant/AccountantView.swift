import SwiftUI

// Placeholder: owned by the feature session that builds this screen.
struct AccountantView: View {
    var body: some View {
        ContentUnavailableView("Sắp có", systemImage: "brain.head.profile", description: Text("AI kế toán & Báo cáo"))
            .navigationTitle("AI kế toán & Báo cáo")
    }
}
