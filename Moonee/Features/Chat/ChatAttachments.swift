import PDFKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo or PDF waiting in the composer: sent with the text, never on its own (owner feedback round 4).
struct ChatAttachment: Identifiable {
    enum Content {
        case image(UIImage)
        case pdf(PDFDocument, name: String)
    }

    let id = UUID()
    let content: Content
    /// The library photo it came from (the recent strip), so tapping that photo again takes it off.
    var assetID: String? = nil

    var name: String? {
        if case .pdf(_, let name) = content { name } else { nil }
    }

    var thumbnail: UIImage? {
        switch content {
        case .image(let image): image.scaled(maxSide: 240)
        case .pdf(let pdf, _): pdf.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
        }
    }

    /// What the sent message keeps: a small JPEG of a photo, a PDF's file name.
    var stored: StoredAttachment {
        switch content {
        case .image: StoredAttachment(name: nil, thumbnail: thumbnail?.jpegData(compressionQuality: 0.7))
        case .pdf(_, let name): StoredAttachment(name: name, thumbnail: nil)
        }
    }

    /// The document's rows with their layout: OCR of a photo, a PDF's text (or OCR of its pages).
    func lines() async -> [OCRLine] {
        switch content {
        case .image(let image): (try? await ReceiptScanner.lines(in: image)) ?? []
        case .pdf(let pdf, _): await ReceiptScanner.lines(in: pdf)
        }
    }

    /// A photo for models that see images, small enough to send; a PDF goes as its text.
    var jpeg: Data? {
        if case .image(let image) = content { image.scaled(maxSide: 1600).jpegData(compressionQuality: 0.7) } else { nil }
    }

    /// A file from the importer: a PDF or an image; nil when it can't be read.
    static func load(_ url: URL) -> ChatAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil } // read now: access ends with this function
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true, let pdf = PDFDocument(data: data) {
            return ChatAttachment(content: .pdf(pdf, name: url.lastPathComponent))
        }
        return UIImage(data: data).map { ChatAttachment(content: .image($0)) }
    }

    /// Picked in the system photo picker; nil when the photo can't be loaded.
    static func load(_ item: PhotosPickerItem) async -> ChatAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return nil }
        return ChatAttachment(content: .image(image))
    }
}

/// A sent attachment as the message stores it (JSON in `ChatMessage.attachmentsData`).
struct StoredAttachment: Codable, Equatable {
    var name: String?
    var thumbnail: Data?
}

extension ChatMessage {
    var attachments: [StoredAttachment] {
        get { attachmentsData.flatMap { try? JSONDecoder().decode([StoredAttachment].self, from: $0) } ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}

extension UIImage {
    /// Fits in `maxSide` pixels; never upscales.
    func scaled(maxSide: CGFloat) -> UIImage {
        let ratio = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

// MARK: - Composer chips

/// The attachments above the composer's text: photo thumbnails and PDF names, each with an ✕.
struct AttachmentChips: View {
    let items: [ChatAttachment]
    let onRemove: (ChatAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { a in
                    AttachmentTile(thumbnail: a.thumbnail, name: a.name)
                        .overlay(alignment: .topTrailing) {
                            Button { onRemove(a.id) } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(Color.ink.opacity(0.75), in: .circle)
                                    .frame(width: 32, height: 32).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 8, y: -8)
                            .accessibilityLabel(Text("Remove attachment", tableName: "Chat"))
                        }
                }
            }
            .padding(.top, 8).padding(.horizontal, 8)
        }
        .scrollClipDisabled()
    }
}

/// A photo thumbnail, or a PDF's icon and name.
struct AttachmentTile: View {
    let thumbnail: UIImage?
    var name: String?
    var side: CGFloat = 64

    var body: some View {
        if let name {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(Color.brandPrimary)
                Text(name).font(.footnote.weight(.medium)).foregroundStyle(Color.ink).lineLimit(2).truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 170, minHeight: side, maxHeight: side, alignment: .leading)
            .background(Color.brandMintSoft, in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        } else {
            Color.track
                .frame(width: side, height: side)
                .overlay { if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() } }
                .clipShape(.rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.ink.opacity(0.12)) } // white receipts on a white card
                .accessibilityElement()
                .accessibilityLabel(Text("Photo", tableName: "Chat"))
        }
    }
}

/// The photos and files of a sent message, right-aligned above its bubble.
struct SentAttachments: View {
    let items: [StoredAttachment]

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 56)
            ForEach(items.indices, id: \.self) { i in
                AttachmentTile(thumbnail: items[i].thumbnail.flatMap(UIImage.init(data:)), name: items[i].name, side: items.count > 3 ? 56 : 76)
            }
        }
    }
}

// MARK: - Recent photos

/// The recent-photos strip of "Add to chat", drawn with PhotoKit: access is asked the normal way (no system overlay).
/// Limited access shows the allowed photos and "Manage"; no access, a button to Settings.
struct RecentPhotosStrip: View {
    /// Library ids already attached (checkmarked).
    let selected: Set<String>
    let onToggle: (PHAsset) -> Void
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch status {
            case .authorized, .limited:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets, id: \.localIdentifier) { a in
                            Button { onToggle(a) } label: { PhotoCell(asset: a, selected: selected.contains(a.localIdentifier)) }
                                .buttonStyle(.plain)
                        }
                        if status == .limited { manageButton }
                    }
                }
                .overlay {
                    if assets.isEmpty && status == .authorized {
                        Text("No photos yet", tableName: "Chat").font(.footnote).foregroundStyle(Color.inkSecondary)
                    }
                }
            case .denied, .restricted:
                Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label { Text("Allow access to Photos", tableName: "Chat").font(.subheadline.weight(.semibold)) } icon: { Image(systemName: "photo.badge.exclamationmark") }
                        Text("Turn on Photos for Moonee in Settings to pick receipts here.", tableName: "Chat")
                            .font(.footnote).foregroundStyle(Color.inkSecondary)
                    }
                    .foregroundStyle(Color.brandDeep)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.brandMintSoft, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            fetch()
        }
    }

    private var manageButton: some View {
        Button(action: manageLimited) {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.title2)
                Text("Manage", tableName: "Chat").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Color.brandDeep)
            .frame(width: 88).frame(maxHeight: .infinity)
            .background(Color.brandMintSoft, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose which photos Moonee can see", tableName: "Chat"))
    }

    private func fetch() {
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 40
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = (0..<result.count).map(result.object(at:))
    }

    /// The system sheet for choosing which photos Moonee may see; the strip refreshes after it.
    private func manageLimited() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in Task { @MainActor in fetch() } }
    }

    static let images = PHCachingImageManager()

    /// The photo for OCR: big enough to read, never the 48 MP original.
    static func image(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // one callback
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { done in
            images.requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: options) { image, _ in
                done.resume(returning: image)
            }
        }
    }
}

private struct PhotoCell: View {
    let asset: PHAsset
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.track
            .frame(width: 96).frame(maxHeight: .infinity)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(.rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.ink.opacity(0.08)) }
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.brandPrimary, lineWidth: 3) }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Color.brandPrimary : Color.black.opacity(0.25))
                    .shadow(color: .black.opacity(selected ? 0 : 0.35), radius: 1.5)
                    .padding(6)
            }
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(Text("Photo", tableName: "Chat"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .task(id: asset.localIdentifier) {
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                RecentPhotosStrip.images.requestImage(for: asset, targetSize: CGSize(width: 288, height: 288), contentMode: .aspectFill, options: options) { img, _ in
                    if let img { image = img }
                }
            }
    }
}
