import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One history row, and the whole interface for an entry. Kept cheap on purpose: no image
/// decoding beyond the cached thumbnail, no disk reads for text.
struct ClipRowView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let dense: Bool
    let showNumber: Bool
    let showSource: Bool
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var lineLimit: Int { dense ? 1 : 2 }

    /// Images get a wider strip so the thumbnail is actually readable at a glance.
    private var leadingSize: CGSize {
        if item.kind == .image { return dense ? CGSize(width: 30, height: 20) : CGSize(width: 42, height: 28) }
        return dense ? CGSize(width: 18, height: 18) : CGSize(width: 24, height: 24)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            leading
                .frame(width: leadingSize.width, height: leadingSize.height)
                .padding(.top, dense ? 0 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: dense ? 12 : 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !dense {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, dense ? 6 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Image rows carry their size in the second line already, so the first line stays a
    /// plain label instead of repeating it. A masked entry shows its name or dots, never
    /// the content; a name alone also stands in for the content when one was given.
    private var title: String {
        if item.masked { return item.label.isEmpty ? "••••••••••" : item.label }
        if !item.label.isEmpty { return item.label }
        if item.kind == .image { return "Image" }
        return item.preview.isEmpty ? item.kind.title : item.preview
    }

    private var subtitle: String {
        // Nothing that could identify the content leaks under a masked entry: no source
        // app, no size, just dots and the time.
        if item.masked { return "••••••  ·  " + item.timeText }
        var parts: [String] = []
        if showSource, !item.sourceName.isEmpty { parts.append(item.sourceName) }
        parts.append(item.timeText)
        parts.append(item.detailText)
        return parts.joined(separator: "  ·  ")
    }

    /// Hover reveals the two actions worth reaching for with the pointer. Everything else
    /// lives in the context menu so the row stays quiet.
    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 3) {
            if isHovering {
                rowButton(item.pinned ? "pin.slash" : "pin",
                          help: item.pinned ? "Unpin, or press Command P" : "Pin, or press Command P",
                          action: onPin)
                // No delete button on a pinned row: unpin it first.
                if !item.pinned {
                    rowButton("trash", help: "Delete, or press Command Delete",
                              danger: true, action: onDelete)
                }
            } else {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(45))
                        .frame(width: 16, height: 16)
                }
                if showNumber, index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                        .frame(width: 15, height: 15)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isSelected ? Theme.accentSoft : Theme.surface)
                        )
                }
            }
        }
        .frame(width: trailingWidth, height: 16, alignment: .trailing)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    /// Held constant so swapping the badges for the hover buttons never reflows the title
    /// underneath the pointer. Two buttons at 18 with 3 between them is the widest state.
    private var trailingWidth: CGFloat {
        let hovered: CGFloat = item.pinned ? 18 : 39
        var resting: CGFloat = item.pinned ? 16 : 0
        if showNumber, index < 9 { resting += resting > 0 ? 18 : 15 }
        return max(hovered, resting)
    }

    private func rowButton(_ symbol: String, help: String,
                           danger: Bool = false, action: @escaping () -> Void) -> some View {
        RowActionButton(symbol: symbol, help: help, danger: danger, action: action)
    }

    @ViewBuilder
    private var leading: some View {
        if item.masked {
            // The slashed eye replaces thumbnails and swatches too; an image or a colour
            // can give away as much as text.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : Theme.surface)
                .overlay(
                    Image(systemName: "eye.slash")
                        .font(.system(size: dense ? 8.5 : 10, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                )
        } else if item.kind == .image, let url = ClipStore.shared.thumbnailURL(for: item),
           let image = ThumbnailCache.shared.image(at: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // Sized and clipped here rather than by the frame outside. A frame on its own
                // does not clip, so a tall screenshot filled to the width used to hang out of
                // its box and push the row taller than every other one in the list.
                .frame(width: leadingSize.width, height: leadingSize.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        } else if item.kind == .color, let color = item.swatchColor {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : Theme.surface)
                .overlay(
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: dense ? 8.5 : 10, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                )
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.hover : Color.clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                        .padding(.leading, 2)
                }
            }
    }
}

/// A hover action on a row. The destructive tint only comes out when the pointer is on the
/// button itself, so a row full of red is not the first thing you see when you hover it.
private struct RowActionButton: View {
    let symbol: String
    let help: String
    let danger: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovering && danger ? Theme.danger.opacity(0.16) : Theme.surface)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }

    private var tint: Color {
        if danger { return isHovering ? Theme.danger : Theme.secondaryText }
        return isHovering ? Theme.primaryText : Theme.secondaryText
    }
}
