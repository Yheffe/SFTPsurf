import SwiftUI
import SFTPsurfCore

/// Column widths shared by a listing's header and its rows.
///
/// The name column absorbs the remaining space; the other columns have fixed
/// widths so they line up, and drop out entirely when the pane is too narrow
/// for them to be readable.
struct ColumnLayout {
    var size: CGFloat = 80
    var modified: CGFloat = 150
    var kind: CGFloat = 96

    /// Space between adjacent columns. Applied by both the header and the rows
    /// so they stay aligned.
    static let gutter: CGFloat = 12

    /// How narrow the pane can get before a column stops being worth showing.
    static let minimumForSize: CGFloat = 250
    static let minimumForModified: CGFloat = 420
    static let minimumForKind: CGFloat = 590

    func plan(for width: CGFloat) -> ColumnPlan {
        ColumnPlan(
            showSize: width >= Self.minimumForSize,
            showModified: width >= Self.minimumForModified,
            showKind: width >= Self.minimumForKind,
            layout: self
        )
    }
}

/// Which columns are visible at a given width.
struct ColumnPlan {
    let showSize: Bool
    let showModified: Bool
    let showKind: Bool
    let layout: ColumnLayout

    /// Used before the first measurement lands so nothing flashes in and out.
    static let widest = ColumnPlan(
        showSize: true,
        showModified: true,
        showKind: true,
        layout: ColumnLayout()
    )
}

/// Reports its width so a pane can choose a column plan.
private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Calls `handler` with the rendered width whenever it changes.
    func measuringWidth(_ handler: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: WidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WidthPreferenceKey.self) { width in
            handler(width)
        }
    }
}

/// The header strip above a listing, with clickable sort targets.
struct ListingHeader: View {
    let plan: ColumnPlan
    @Binding var sortColumn: SortColumn
    @Binding var sortAscending: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sortTarget(.name, width: nil, alignment: .leading)
            if plan.showSize {
                sortTarget(.size, width: plan.layout.size, alignment: .trailing)
                    .padding(.leading, ColumnLayout.gutter)
            }
            if plan.showModified {
                sortTarget(.modified, width: plan.layout.modified, alignment: .leading)
                    .padding(.leading, ColumnLayout.gutter)
            }
            if plan.showKind {
                sortTarget(.kind, width: plan.layout.kind, alignment: .leading)
                    .padding(.leading, ColumnLayout.gutter)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The name column passes a nil width and so absorbs the leftover space,
    /// which keeps it exactly aligned with the rows below.
    private func sortTarget(_ column: SortColumn, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
            onChange()
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
        .contentShape(Rectangle())
        .help("Sort by \(column.title.lowercased())")
    }
}

/// One listing row, shared by both panes.
struct EntryRow: View {
    let plan: ColumnPlan
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let detail: String?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: EntryIcon.symbol(
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    name: name
                ))
                .font(.system(size: 13))
                .foregroundStyle(isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)

                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if plan.showSize {
                Text(ListingFormatter.size(bytes: size, isDirectory: isDirectory))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: plan.layout.size, alignment: .trailing)
                    .padding(.leading, ColumnLayout.gutter)
            }

            if plan.showModified {
                Text(ListingFormatter.date(modified))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: plan.layout.modified, alignment: .leading)
                    .padding(.leading, ColumnLayout.gutter)
            }

            if plan.showKind {
                Text(detail ?? ListingFormatter.kind(
                    name: name,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink
                ))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: plan.layout.kind, alignment: .leading)
                .padding(.leading, ColumnLayout.gutter)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

/// Reusable empty-state placeholder for a pane with nothing to show.
struct PaneMessage: View {
    let symbol: String
    let title: String
    let subtitle: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// The address field at the top of each pane.
struct PathField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit(onSubmit)
    }
}
