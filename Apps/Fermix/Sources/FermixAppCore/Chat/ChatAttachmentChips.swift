import AppKit
import ImageIO
import SwiftUI

/// The files the composer holds, over its field: a chip each, in a row that
/// scrolls sideways once it is wider than the field, and under the row the
/// sentence of each file that was not attached.
struct ChatAttachmentChips: View {
    @ObservedObject var attachments: ChatAttachments

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(attachments.items) { attachment in
                        ChatAttachmentChip(attachment: attachment) {
                            attachments.remove(attachment.id)
                        }
                    }
                }
            }

            ForEach(refusals, id: \.id) { refusal in
                Text(ProductStrings.commaPair(refusal.attachment.name, refusal.sentence))
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.error.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refusals: [(id: String, attachment: ChatAttachment, sentence: String)] {
        attachments.items.compactMap { attachment in
            guard case .refused(let sentence) = attachment.standing else { return nil }

            return (attachment.id, attachment, sentence)
        }
    }
}

/// One file over the composer: its picture, or its icon, its name, while it
/// is being attached a quiet progress mark, a mark where it was not, and the
/// button that takes it out.
private struct ChatAttachmentChip: View {
    let attachment: ChatAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ChatAttachmentThumb(source: attachment.source, kind: attachment.kind)

            Text(attachment.name)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ChatMetrics.attachChipNameWidth, alignment: .leading)

            standing

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: ChatMetrics.actionGlyph))
                    .frame(width: ChatMetrics.actionSize, height: ChatMetrics.actionSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChatActionButtonStyle())
            .help(String(format: ProductStrings[.chatAttachRemoveFormat], attachment.name))
            .accessibilityLabel(String(format: ProductStrings[.chatAttachRemoveFormat], attachment.name))
        }
        .padding(Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.cardFill.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var standing: some View {
        switch attachment.standing {
        case .copying, .handing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(ProductStrings[.chatAttachAttaching])
        case .refused:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Palette.error.color)
                .accessibilityHidden(true)
        case .held:
            EmptyView()
        }
    }
}

/// A file's picture, as small as the chip draws it, or its icon where it is
/// no picture or cannot be read as one.
private struct ChatAttachmentThumb: View {
    let source: URL
    let kind: CompanionAttachKind

    @State private var picture: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: ChatMetrics.attachChipThumb, height: ChatMetrics.attachChipThumb)
        .clipShape(RoundedRectangle(cornerRadius: Radius.iconTileSmall, style: .continuous))
        .task(id: source) {
            guard kind == .image || kind == .animation else { return }

            let pixels = ChatMetrics.attachChipThumb * scale
            picture = await Task.detached(priority: .utility) { [source] in
                Self.thumbnail(of: source, pixels: pixels)
            }.value
        }
    }

    private nonisolated static func thumbnail(of file: URL, pixels: Double) -> CGImage? {
        guard let image = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary)
    }
}
