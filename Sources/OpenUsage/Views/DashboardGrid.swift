import AppKit
import SwiftUI

enum DashboardGrid {
    static let cardPadding = Theme.Spacing.xl
    static let cardTopPadding = Theme.Spacing.m
    static let cardBottomPadding = Theme.Spacing.l
    static let headerGap = Theme.Spacing.xs
    static let sectionSpacing = Theme.Spacing.xxl
    static let accountSpacing = Theme.Spacing.m
    static let captionGap = Theme.Spacing.xs
    static let columnGap = Theme.Spacing.m
    static let rowHeight: CGFloat = 22
    static let levelHeight: CGFloat = 9
    static let labelWidth: CGFloat = 90
    /// Fits three CJK characters (总用量) at the row font, so ordinary cards share one bar start.
    static let minLabelWidth: CGFloat = 40
    /// Fits 100% at the row font.
    static let valueWidth: CGFloat = 38
    /// Extra room between the figure and the reset, beyond `columnGap`.
    static let valueResetGap: CGFloat = 8
    /// Fits 23小时59分钟 / 23 hr 59 min spelled out, or 23h 59m compact.
    static var resetWidth: CGFloat { DurationFormatSetting.current == .compact ? 52 : 76 }
    static let clockResetWidth: CGFloat = 80

    static let headerFont: Font = .system(size: 15, weight: .semibold)
    static let planFont: Font = .system(size: 10, weight: .medium)
    static var planNSFont: NSFont { .systemFont(ofSize: 11) }
    static let planPadding: CGFloat = 5
    static let captionFont: Font = .system(size: 11, weight: .semibold)

    static let headerHeight: CGFloat = 24
    static let captionHeight = NSLayoutManager().defaultLineHeight(for: planNSFont).rounded(.up)
    static let iconSize: CGFloat = 16
}

/// An account's rows, one under the next, or a skeleton row per metric until its first reading.
struct DashboardLineStack<Row: View>: View {
    let account: DashboardAccount
    @ViewBuilder let row: (DashboardLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(account.lines) { row($0) }
            if !account.waitingMetricIDs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(account.waitingMetricIDs, id: \.self) { _ in SkeletonMetricRow() }
                }
                .accessibilityElement()
                .accessibilityLabel("Waiting for Usage")
            }
        }
    }
}

/// A metric row's bar, figure, and reset as grey bars in their own columns.
private struct SkeletonMetricRow: View {
    @Environment(\.dashboardColumns) private var columns

    var body: some View {
        let widths = columns ?? .fallback
        HStack(spacing: DashboardGrid.columnGap) {
            Capsule().frame(width: min(54, max(widths.label, 30)), height: 8)
                .frame(width: max(widths.label, 30), alignment: .leading)
            Capsule().frame(height: DashboardGrid.levelHeight)
            Capsule().frame(width: 30, height: 8)
                .frame(width: DashboardGrid.valueWidth, alignment: .trailing)
            Capsule().frame(width: 30, height: 7)
                .frame(width: DashboardGrid.resetWidth, alignment: .trailing)
                .padding(.leading, DashboardGrid.valueResetGap)
        }
        .skeleton()
        .frame(height: DashboardGrid.rowHeight)
    }
}

/// A card's label column: its widest label, never under `minLabelWidth` and never over `maxLabel`, so
/// cards with short labels (会话, 每周, 总用量) all line up and only a card with long ones widens.
struct DashboardColumnWidths: Equatable, Sendable {
    var label: CGFloat = 0

    static let maxLabel: CGFloat = 120

    /// What rows outside any card use: the original fixed grid.
    static let fallback = DashboardColumnWidths(label: DashboardGrid.labelWidth)

    var clamped: Self {
        Self(label: min(max(label.rounded(.up), DashboardGrid.minLabelWidth), Self.maxLabel))
    }
}

struct DashboardColumnWidthsKey: PreferenceKey {
    static let defaultValue = DashboardColumnWidths()
    static func reduce(value: inout DashboardColumnWidths, nextValue: () -> DashboardColumnWidths) {
        value.label = max(value.label, nextValue().label)
    }
}

private struct DashboardColumnsEnvironmentKey: EnvironmentKey {
    static let defaultValue: DashboardColumnWidths? = nil
}

extension EnvironmentValues {
    /// The label column of the enclosing card; nil outside one.
    var dashboardColumns: DashboardColumnWidths? {
        get { self[DashboardColumnsEnvironmentKey.self] }
        set { self[DashboardColumnsEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Reports this view's natural width as a label's width.
    func measuresDashboardLabel() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DashboardColumnWidthsKey.self, value: DashboardColumnWidths(label: proxy.size.width))
        })
    }

    /// Sizes the label column of the metric rows inside to their widest label, within bounds.
    func dashboardColumns() -> some View {
        modifier(DashboardColumnsModifier())
    }
}

private struct DashboardColumnsModifier: ViewModifier {
    @State private var widths: DashboardColumnWidths?

    func body(content: Content) -> some View {
        content
            .environment(\.dashboardColumns, widths ?? DashboardColumnWidths(label: DashboardGrid.minLabelWidth))
            .onPreferenceChange(DashboardColumnWidthsKey.self) { measured in
                let next = measured.clamped
                if next != widths { widths = next }
            }
    }
}
