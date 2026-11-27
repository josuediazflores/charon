import SwiftUI

/* ── DataTable ─────────────────────────────────────────────────────────
   HOST          BOARD            UPTIME   TEMP   LINK   STATUS
   ─────────────────────────────────────────────────────────────
   raspberrypi   Pi 5 · NVMe      17h 36m  37.5°C  ▲▲▲   [+CONNECTED]

   A rule under the header and nothing between the rows. Row rules in a
   monospace table fight the columns; the alignment is already doing the work
   borders would do in a proportional one.

   **Interactivity is opt-in and arrives as one prop.** The Overview and
   Hardware tables select, sort and open nothing, and pass none of these -- a
   row that looked pressable and did nothing would be worse than one that
   plainly is not. The CMO's tables pass `onRowClick`, and get the surface tint
   under the cursor a TUI list marks its line with; passing `isRowSelected` as
   well turns the row inverse in the signal colour, which is that tab's one
   cyan.
*/

/// Whether the row a cell is drawing in is selected.
///
/// Read by the cell helpers below and by `StatusPill`, so a row that goes
/// inverse takes its contents with it rather than leaving every span holding
/// its own ink against a cyan ground. The design system voids exactly these in
/// a selected row and deliberately not the lamps.
private struct HTRowSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var htRowSelected: Bool {
        get { self[HTRowSelectedKey.self] }
        set { self[HTRowSelectedKey.self] = newValue }
    }
}

/// A span whose ink gives way when its row inverts.
struct TableInk: ViewModifier {
    var normal: Color
    @Environment(\.htRowSelected) private var selected

    func body(content: Content) -> some View {
        content.foregroundStyle(selected ? HT.void : normal)
    }
}

enum ColumnAlign {
    case leading, trailing, center

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }
}

struct DataColumn<Row> {
    /// Stable identity for the column.
    var key: String
    /// Header cell text. Set uppercase by the header row itself.
    var header: String
    /// A header that is also a control -- the sort buttons, and nothing else.
    /// It inherits the header's own typography and adds only the direction
    /// glyph, so the header stays a header.
    var headerView: AnyView? = nil
    /// Fixed column width. Nil sizes the column to its widest cell.
    var width: CGFloat? = nil
    var align: ColumnAlign = .leading
    /// Absorb the slack. Exactly one column per table should carry this, and
    /// it is the one holding a sentence -- otherwise the table sizes to its
    /// content and strands the right-hand columns mid-panel.
    var flexible: Bool = false
    /// Cell renderer. Return a StatusPill, a StatusLamp or plain text.
    var cell: (Row) -> AnyView
}

extension DataColumn {
    /// The bright cell: the column a row is identified by.
    static func primary(_ s: String) -> AnyView {
        AnyView(Text(s).font(HT.body).lineLimit(1).modifier(TableInk(normal: HT.inkBright)))
    }

    /// The dim cell: context beside the thing being identified.
    static func muted(_ s: String) -> AnyView {
        AnyView(Text(s).font(HT.body).lineLimit(1).modifier(TableInk(normal: HT.inkDim)))
    }

    /// Plain ink, for a reading that is neither identity nor aside.
    static func plain(_ s: String) -> AnyView {
        AnyView(Text(s).font(HT.body).lineLimit(1).modifier(TableInk(normal: HT.ink)))
    }
}

struct DataTable<Row: Identifiable>: View {
    var columns: [DataColumn<Row>]
    var rows: [Row]
    /// Shown in place of the body when there is nothing to list.
    var empty: String = "No records"
    /// Tighten the header's padding one step, for a table inside a small panel.
    var dense: Bool = false
    /// Makes rows pressable. Absent, the table is inert and says so by having
    /// no hover state at all.
    var onRowClick: ((Row) -> Void)? = nil
    /// Marks a row selected: inverse video in the signal colour.
    var isRowSelected: ((Row) -> Bool)? = nil

    /// One id at a time, held here rather than per row: the cells of a row are
    /// siblings in the grid and each reports its own pointer, so the row they
    /// share is the only place that can hold the answer for all of them.
    @State private var hovered: Row.ID?

    private var indexedColumns: [(offset: Int, element: DataColumn<Row>)] {
        Array(columns.enumerated())
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(indexedColumns, id: \.offset) { pair in
                    Group {
                        if let headerView = pair.element.headerView {
                            headerView
                        } else {
                            Text(pair.element.header)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HT.inkDim)
                                .lineLimit(1)
                        }
                    }
                    // The cell's own line box before its padding. Without it
                    // the glyphs sit at the very top of the header and a flush
                    // panel's notched title paints across them -- the
                    // stylesheet's 16px line-height is what holds them clear,
                    // not the 4px padding.
                    .frame(height: HT.row)
                    .padding(.horizontal, HT.cw)
                    .padding(.vertical, dense ? 0 : HT.s1)
                    .modifier(ColumnFrame(column: pair.element))
                    .gridColumnAlignment(pair.element.align.horizontal)
                }
            }
            .zIndex(1)

            if rows.isEmpty {
                GridRow {
                    Text(empty)
                        .font(HT.body)
                        .foregroundStyle(HT.inkDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, HT.row2)
                        .padding(.horizontal, HT.cw)
                        .gridCellColumns(Swift.max(1, columns.count))
                }
            } else {
                ForEach(rows) { row in
                    let selected = isRowSelected?(row) ?? false
                    let lit = hovered == row.id
                    GridRow {
                        ForEach(indexedColumns, id: \.offset) { pair in
                            pair.element.cell(row)
                                .lineLimit(1)
                                .padding(.horizontal, HT.cw)
                                .frame(height: dense ? 20 : 25)
                                .modifier(ColumnFrame(column: pair.element))
                                // Per cell, and the cells abut: the grid's
                                // horizontal spacing is zero, so the tints tile
                                // into one continuous row.
                                .background(rowFill(selected: selected, lit: lit))
                                .contentShape(Rectangle())
                        }
                    }
                    .environment(\.htRowSelected, selected)
                    .modifier(RowPress(enabled: onRowClick != nil,
                                       press: { onRowClick?(row) },
                                       hover: { inside in
                                           if inside { hovered = row.id }
                                           else if hovered == row.id { hovered = nil }
                                       }))
                }
            }
        }
        .background(alignment: .top) {
            Rectangle().fill(HT.surface3)
                .frame(height: HT.row + (dense ? 0 : HT.s1 * 2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowFill(selected: Bool, lit: Bool) -> Color {
        if selected { return HT.signal }
        if lit, onRowClick != nil { return HT.surface3 }
        return .clear
    }
}

/// The press and the pointer, applied to every cell of a row at once.
///
/// A `GridRow` is not a view and cannot be wrapped in one without leaving the
/// grid, so the gestures go on the cells and the row is what they report to.
private struct RowPress: ViewModifier {
    var enabled: Bool
    var press: () -> Void
    var hover: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(perform: press)
                .onHover(perform: hover)
        } else {
            content
        }
    }
}

/// A fixed width, the slack, or whatever the column turned out to be.
///
/// `frame(width:)` and `frame(maxWidth:)` are different modifiers and cannot be
/// spelled in one call, so the three cases are three branches rather than three
/// arguments.
private struct ColumnFrame<Row>: ViewModifier {
    var column: DataColumn<Row>

    func body(content: Content) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: column.align.alignment)
        } else if column.flexible {
            content.frame(maxWidth: .infinity, alignment: column.align.alignment)
        } else {
            content
        }
    }
}
