import SwiftUI
import AppKit

/// A content search's results: each matching file once, its matching lines
/// nested under it. Selecting a line selects its file; Return or a
/// double-click opens it.
struct ContentResults<RowMenu: View>: View {
    @ObservedObject var model: SearchModel
    let select: (Hit) -> Void
    let rowMenu: (Hit) -> RowMenu

    var body: some View {
        // Rows follow sortedHits so display order is the selection/Quick Look
        // order; relevance sorting keeps the engine's own ranking.
        let filesByPath = Dictionary(
            model.contentFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.sortedHits.enumerated()), id: \.element.id) {
                        index, hit in
                        if let file = filesByPath[hit.path] {
                            fileGroup(file, hit: hit, divider: index > 0)
                        }
                    }
                }
            }
            .scrollPosition(id: $model.scrollAnchor)
            .onReceive(model.selectionNavigation) { request in
                proxy.scrollTo(request.path)
            }
        }
    }

    @ViewBuilder private func fileGroup(
        _ file: GrepFile, hit: Hit, divider: Bool
    ) -> some View {
        if divider { Divider() }
        fileRow(file, hit: hit)
        if !model.contentCollapsed.contains(file.path) {
            ForEach(Array(file.matches.enumerated()), id: \.offset) { _, match in
                matchRow(file, match: match, hit: hit)
            }
        }
    }

    private func fileRow(_ file: GrepFile, hit: Hit) -> some View {
        let collapsed = model.contentCollapsed.contains(file.path)
        return HStack(spacing: 6) {
            Button {
                model.setContentCollapsed(file.path, !collapsed)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            FileIcon(hit: hit).frame(width: 16, height: 16)
            FileNameLabel(model: model, hit: hit)
            Text(file.parent)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(verbatim: String(file.matches.count))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help("\(file.matches.count) matching lines")
        }
        .padding(.horizontal, 12).frame(height: 24)
        .background(
            model.selection.contains(file.path) ? Color.accentColor.opacity(0.22) : Color.clear
        )
        .contentShape(Rectangle())
        .modifier(FileClickActions(select: { select(hit) }, open: { model.open(hit) }))
        .contextMenu { rowMenu(hit) }
        .draggable(file.url)
        .id(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(file.matches.count) matches")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAction(named: collapsed ? "Expand" : "Collapse") {
            model.setContentCollapsed(file.path, !collapsed)
        }
        .accessibilityAddTraits(model.selection.contains(file.path) ? [.isSelected] : [])
    }

    private func matchRow(_ file: GrepFile, match: GrepMatch, hit: Hit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: String(match.line))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
            Text(match.highlighted())
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.trailing, 12).frame(height: 20)
        .background(
            model.selection.contains(file.path) ? Color.accentColor.opacity(0.22) : Color.clear
        )
        .contentShape(Rectangle())
        .modifier(FileClickActions(select: { select(hit) }, open: { model.open(hit) }))
        .contextMenu { rowMenu(hit) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line \(match.line): \(match.text)")
    }
}

extension GrepMatch {
    /// The matched line with its match ranges tinted. `ranges` are UTF-8
    /// byte offsets into `text`; a range that misses a code-point boundary
    /// snaps to the boundary below it.
    func highlighted() -> AttributedString {
        let lead = text.utf8.prefix { $0 == 32 || $0 == 9 }.count
        let text = String(text.dropFirst(lead))
        let ranges = self.ranges.map { $0.map { max(0, $0 - lead) } }
        var attributed = AttributedString(text)
        var highlight = AttributeContainer()
        highlight.swiftUI.backgroundColor = Color.accentColor.opacity(0.25)
        if def == true {
            highlight.swiftUI.font = .system(size: 12, weight: .semibold)
        }
        for range in ranges where range.count == 2 && range[0] < range[1] {
            guard
                let lower = Self.utf8Boundary(text, offset: range[0]),
                let upper = Self.utf8Boundary(text, offset: range[1]),
                let start = AttributedString.Index(lower, within: attributed),
                let end = AttributedString.Index(upper, within: attributed),
                start < end
            else { continue }
            attributed[start..<end].mergeAttributes(highlight)
        }
        return attributed
    }

    private static func utf8Boundary(_ text: String, offset: Int) -> String.Index? {
        var offset = min(offset, text.utf8.count)
        while offset >= 0 {
            guard
                let candidate = text.utf8.index(
                    text.utf8.startIndex, offsetBy: offset, limitedBy: text.utf8.endIndex)
            else { return nil }
            if let boundary = String.Index(candidate, within: text) { return boundary }
            offset -= 1
        }
        return nil
    }
}
