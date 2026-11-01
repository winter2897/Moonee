import SwiftUI
import UIKit
import Vision

enum ReceiptScanner {
    /// OCR lines top to bottom; text on the same row ("Tổng cộng ... 58.000") is joined into one line.
    static func lines(in image: UIImage) async throws -> [String] {
        // Redraw so the CGImage is upright whatever the camera orientation was.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        guard let cgImage = UIGraphicsImageRenderer(size: image.size, format: format).image(actions: { _ in image.draw(at: .zero) }).cgImage else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let vietnamese = (try? request.supportedRecognitionLanguages().filter { $0.hasPrefix("vi") }) ?? []
            if vietnamese.isEmpty {
                request.automaticallyDetectsLanguage = true
            } else {
                request.recognitionLanguages = vietnamese + ["en-US"]
            }
            try VNImageRequestHandler(cgImage: cgImage).perform([request])

            // Vision's origin is bottom-left: sort by midY descending, group observations whose centres share a row.
            let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var rows: [[VNRecognizedTextObservation]] = []
            for o in observations {
                if let last = rows.last?.last, abs(last.boundingBox.midY - o.boundingBox.midY) < last.boundingBox.height / 2 {
                    rows[rows.count - 1].append(o)
                } else {
                    rows.append([o])
                }
            }
            return rows.map { row in
                row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "  ")
            }
        }.value
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
