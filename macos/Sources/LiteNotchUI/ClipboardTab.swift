import SwiftUI

struct ClipboardTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.clockOffsetMs) private var offset
    @State private var query = ""
    @State private var queryWork: DispatchWorkItem?
    @State private var copiedId: Int?
    @FocusState private var focused: Bool

    private var items: [ClipView] { vm.clipboard.items }
    private var hasUnpinned: Bool { items.contains { !$0.pinned } }

    var body: some View {
        if let id = model.clipPreview, let item = items.first(where: { $0.id == id }),
           let source = Thumbnails.source(of: item) {
            ClipPreview(item: item, source: source, copy: { copy(item) }, close: { model.clipPreview = nil })
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                searchField
                ConfirmPill(title: "Clear history", question: ConfirmGate.question(count: clearCount),
                            help: "Remove everything except pinned items", enabled: hasUnpinned, height: 30) {
                    model.send(.clipClear)
                }
            }
            swatches
            if items.isEmpty {
                empty
            } else {
                NotchScroll {
                    let now = nowMs(Date(), offset: offset)
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        row(item, now: now)
                        if idx < items.count - 1 { Hairline().padding(.horizontal, 6) }
                    }
                    .padding(.horizontal, 6)
                }
                // Rows reach 6 pt past the column so their hover fill has
                // room while the text stays aligned with the search field.
                .padding(.horizontal, -6)
            }
        }
        .onAppear { query = vm.clipboard.query }
        .onChange(of: focused) { _, f in model.requestKeyboard(f) }
        .onDisappear { model.requestKeyboard(false) }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").glyph(11)
                .foregroundStyle(NT.text3)
            if snapshot {
                Text(verbatim: query.isEmpty ? "Search clipboard" : query)
                    .nfont(.body).foregroundStyle(NT.text3)
                Spacer(minLength: 0)
            } else {
                TextField("", text: $query,
                          prompt: Text(verbatim: "Search clipboard").foregroundColor(NT.text3))
                    .textFieldStyle(.plain)
                    .font(NType.body.font)
                    .foregroundStyle(NT.text1)
                    .focused($focused)
                    .onChange(of: query) { _, q in debounce(q) }
                    .onSubmit { focused = false }
                    .simultaneousGesture(TapGesture().onEnded { model.requestKeyboard(true) })
                    .accessibilityLabel(Text(verbatim: "Search clipboard"))
            }
            if !query.isEmpty && !snapshot {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", size: 11, frame: 24) { query = "" }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    /// Colours picked from the screen; a click copies one again.
    @ViewBuilder private var swatches: some View {
        let colors = vm.colors.compactMap(ColorMath.normalize).prefix(8)
        if !colors.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "eyedropper").glyph(NGlyph.small)
                    .foregroundStyle(NT.text3)
                    .help("Colours you picked from the screen")
                ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                    Button { model.send(.colorPicked(hex: hex)) } label: {
                        Circle().fill(NT.color(hex))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(NT.hairline, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(hex)")
                    .accessibilityLabel(Text(verbatim: "Copy \(hex)"))
                }
                Spacer(minLength: 4)
                if let first = colors.first {
                    VText(first).nfont(.caption).monospaced().foregroundStyle(NT.text3)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 20)
        }
    }

    private func copyPlain(_ item: ClipView) {
        model.send(.clipCopyPlain(id: item.id))
        flashCopied(item)
    }

    private func copy(_ item: ClipView) {
        model.send(.clipCopy(id: item.id))
        flashCopied(item)
    }

    private func flashCopied(_ item: ClipView) {
        copiedId = item.id
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { if copiedId == id { copiedId = nil } }
    }

    private func debounce(_ q: String) {
        queryWork?.cancel()
        let work = DispatchWorkItem { model.send(.clipQuery(q)) }
        queryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @ViewBuilder private var empty: some View {
        if vm.clipboard.query.isEmpty {
            EmptyState(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                       hint: "Copy something and it appears here.")
        } else {
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       hint: "Try fewer words, or clear the search.")
        }
    }

    /// Items Clear would remove, when the list shows all of them.
    private var clearCount: Int? {
        guard vm.clipboard.query.isEmpty, items.count == vm.clipboard.total else { return nil }
        return items.filter { !$0.pinned }.count
    }

    private func icon(_ k: ClipKind) -> String {
        switch k {
        case .text, .unknown: return "text.alignleft"
        case .files: return "folder"
        case .image: return "photo"
        }
    }

    private func row(_ item: ClipView, now: Int) -> some View {
        HStack(alignment: .center, spacing: 2) {
            let source = Thumbnails.source(of: item)
            Button { copy(item) } label: {
                HStack(spacing: 10) {
                    if let source {
                        ClipThumb(source: source)
                    } else {
                        Image(systemName: icon(item.kind))
                            .glyph(11, .medium).foregroundStyle(NT.text2)
                            .frame(width: 24, height: 24)
                            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
                            // Same column as the thumbnails.
                            .frame(width: 34, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        VText(item.preview).nfont(.body).foregroundStyle(NT.text1)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        if copiedId == item.id {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark").glyph(9, .bold)
                                Text(verbatim: "Copied")
                            }
                            .nfont(.captionStrong).foregroundStyle(NT.accentText)
                        } else if let app = item.sourceApp, !app.isEmpty {
                            VText(app).nfont(.caption).foregroundStyle(NT.text3).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: Format.relative(from: item.createdMs, nowMs: now))
                        .nfont(.caption).foregroundStyle(NT.text3).lineLimit(1).fixedSize()
                        .padding(.trailing, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel(Text(verbatim: "Copy: \(item.preview)"))
            let actions = ClipActions.of(item, hasPreview: source != nil)
            if actions.contains(.copyPlain) {
                IconButton(symbol: "textformat", label: "Copy as plain text", size: 11,
                           tint: item.rich ? NT.text2 : NT.text3, help: "Copy without formatting") {
                    copyPlain(item)
                }
            }
            if actions.contains(.preview) {
                IconButton(symbol: "eye", label: "Preview", size: 11, tint: NT.text3) {
                    model.requestKeyboard(false)
                    model.clipPreview = item.id
                }
            }
            IconButton(symbol: item.pinned ? "pin.fill" : "pin", label: item.pinned ? "Unpin" : "Pin",
                       size: 11, tint: item.pinned ? NT.accent : NT.text3,
                       help: item.pinned ? "Unpin" : "Pin: keep it when the history is cleared") {
                model.send(.clipPin(id: item.id, pinned: !item.pinned))
            }
            IconButton(symbol: "xmark", label: "Delete", size: NGlyph.small, tint: NT.text3,
                       help: "Remove from history") {
                model.send(.clipRemove(id: item.id))
            }
        }
        .padding(.vertical, 4)
        .rowHover()
    }
}

/// The buttons a clipboard row offers besides copying, pin and delete.
public enum ClipActions: Equatable {
    case copyPlain, preview

    /// Every text clip can be copied as plain text, formatted or not; a
    /// clip with a thumbnail (image or files) can be previewed.
    public static func of(_ item: ClipView, hasPreview: Bool) -> [ClipActions] {
        var out: [ClipActions] = []
        if item.kind == .text { out.append(.copyPlain) }
        if hasPreview { out.append(.preview) }
        return out
    }
}
