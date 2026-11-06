import PDFKit
import SwiftUI
import UIKit
import Vision

/// One OCR row with where it sits: big text near the top of a confirmation screen is the amount (spec §3.1).
struct OCRLine: Equatable, Sendable {
    var text: String
    /// Top of the row: 0 = top of the page, 1 = bottom.
    var y: Double = 0
    /// Text height as a share of the page height (0 = unknown, e.g. a PDF's text).
    var height: Double = 0
    /// Vision's confidence, 0…1.
    var confidence: Double = 1
}

extension OCRLine {
    /// Rows without layout (typed text, tests): top to bottom, size unknown.
    static func plain(_ texts: [String]) -> [OCRLine] {
        texts.enumerated().map { OCRLine(text: $1, y: Double($0) / Double(max(texts.count, 1))) }
    }
}

enum ReceiptScanner {
    /// OCR rows top to bottom; text on the same row ("Tổng cộng ... 58.000") is joined into one line, split by two spaces.
    static func lines(in image: UIImage) async throws -> [OCRLine] {
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
                let texts = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first }
                return OCRLine(text: texts.map(\.string).joined(separator: "  "),
                               y: 1 - Double(row.map(\.boundingBox.maxY).max() ?? 1),
                               height: Double(row.map(\.boundingBox.height).max() ?? 0),
                               confidence: Double(texts.map(\.confidence).min() ?? 0))
            }
        }.value
    }

    /// A PDF's rows with their place on the page: its text, or OCR of its first pages when it has none (a scan).
    static func lines(in pdf: PDFDocument) async -> [OCRLine] {
        let pages = (0..<min(pdf.pageCount, 3)).compactMap(pdf.page(at:))
        var out: [OCRLine] = []
        for (i, page) in pages.enumerated() {
            let box = page.bounds(for: .mediaBox)
            let rows = (page.selection(for: box)?.selectionsByLine() ?? []).compactMap { s -> OCRLine? in
                let text = (s.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, box.height > 0 else { return nil }
                let r = s.bounds(for: page) // PDF origin is bottom-left too
                return OCRLine(text: text, y: (Double(i) + (box.maxY - r.maxY) / box.height) / Double(pages.count),
                               height: r.height / box.height / Double(pages.count))
            }
            if !rows.isEmpty { out += rows; continue }
            let image = page.thumbnail(of: CGSize(width: box.width * 2, height: box.height * 2), for: .mediaBox)
            out += ((try? await lines(in: image)) ?? []).map {
                var l = $0
                (l.y, l.height) = ((Double(i) + l.y) / Double(pages.count), l.height / Double(pages.count))
                return l
            }
        }
        return out
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
