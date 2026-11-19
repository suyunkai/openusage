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
    static let valueWidth: CGFloat = 52
    static let resetWidth: CGFloat = 48
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
                .frame(width: max(widths.value, 30), alignment: .trailing)
            Capsule().frame(width: 30, height: 7)
                .frame(width: max(widths.reset, 30), alignment: .trailing)
        }
        .skeleton()
        .frame(height: DashboardGrid.rowHeight)
    }
}

/// The label, figure, and reset columns of a card's metric rows, each as wide as its widest entry, so
/// the bars line up without a fixed width that's too wide for 会话 or too narrow for 5天14小时.
struct DashboardColumnWidths: Equatable, Sendable {
    var label: CGFloat = 0
    var value: CGFloat = 0
    var reset: CGFloat = 0

    /// A long label (an email, a model name) truncates past this instead of squeezing the bar.
    static let maxLabel: CGFloat = 120

    /// What rows outside any card use: the original fixed grid.
    static let fallback = DashboardColumnWidths(
        label: DashboardGrid.labelWidth, value: DashboardGrid.valueWidth, reset: DashboardGrid.resetWidth
    )

    func merged(with other: Self) -> Self {
        Self(label: max(label, other.label), value: max(value, other.value), reset: max(reset, other.reset))
    }

    var clamped: Self {
        Self(label: min(label.rounded(.up), Self.maxLabel), value: value.rounded(.up), reset: reset.rounded(.up))
    }
}

struct DashboardColumnWidthsKey: PreferenceKey {
    static let defaultValue = DashboardColumnWidths()
    static func reduce(value: inout DashboardColumnWidths, nextValue: () -> DashboardColumnWidths) {
        value = value.merged(with: nextValue())
    }
}

private struct DashboardColumnsEnvironmentKey: EnvironmentKey {
    static let defaultValue: DashboardColumnWidths? = nil
}

extension EnvironmentValues {
    /// The measured columns of the enclosing card; nil outside one.
    var dashboardColumns: DashboardColumnWidths? {
        get { self[DashboardColumnsEnvironmentKey.self] }
        set { self[DashboardColumnsEnvironmentKey.self] = newValue }
    }
}

enum DashboardColumn { case label, value, reset }

extension View {
    /// Reports this view's natural width as one column's width.
    func measuresDashboardColumn(_ column: DashboardColumn) -> some View {
        background(GeometryReader { proxy in
            let width = proxy.size.width
            Color.clear.preference(key: DashboardColumnWidthsKey.self, value: {
                switch column {
                case .label: DashboardColumnWidths(label: width)
                case .value: DashboardColumnWidths(value: width)
                case .reset: DashboardColumnWidths(reset: width)
                }
            }())
        })
    }

    /// Sizes the metric rows inside to their widest label, figure, and reset.
    func dashboardColumns() -> some View {
        modifier(DashboardColumnsModifier())
    }
}

private struct DashboardColumnsModifier: ViewModifier {
    @State private var widths: DashboardColumnWidths?

    func body(content: Content) -> some View {
        content
            .environment(\.dashboardColumns, widths ?? .fallback)
            .onPreferenceChange(DashboardColumnWidthsKey.self) { measured in
                let next = measured.clamped
                if next != widths { widths = next }
            }
    }
}
