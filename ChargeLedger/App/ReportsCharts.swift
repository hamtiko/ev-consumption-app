import SwiftUI
import Charts
import ChargeLedgerCore

enum CycleMetric {
    case consumption, cost
    var title: String { self == .consumption ? "Energy consumption" : "Cost per kilometre" }
    var unit: String { self == .consumption ? "kWh/100 km" : "AMD/km" }
    func value(_ cycle: PeriodSummary) -> Decimal? { self == .consumption ? cycle.energyPer100KM : cycle.costPerKM }
}

struct ReportCard<Content: View>: View {
    let title: String
    var note = ""
    let content: () -> Content
    init(title: String, note: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.note = note; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content()
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct CycleTrendChart: View {
    let cycles: [PeriodSummary]
    let metric: CycleMetric
    let statistics: MetricStatistics
    let open: (PeriodSummary) -> Void
    @State private var selectedDate: Date?
    @State private var selectedCycleID: UUID?
    @ScaledMetric(relativeTo: .caption) private var calloutHeadroom: CGFloat = 90
    @ScaledMetric(relativeTo: .subheadline) private var selectionControlHeight: CGFloat = 44
    private var selected: PeriodSummary? {
        cycles.first { $0.id == selectedCycleID }
    }

    var body: some View {
        ReportCard(title: "\(metric.title) · \(metric.unit)",
                   note: "Average is weighted by distance. Min/max are individual completed cycles.") {
            HStack {
                statistic("Average", statistics.average)
                statistic("Minimum", statistics.minimum)
                statistic("Maximum", statistics.maximum)
            }
            // Reserve the controls' height so selection never moves the chart under the finger.
            HStack {
                if let selected {
                    Button { open(selected) } label: {
                        Label("View cycle", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LedgerStyle.accent)
                    Spacer()
                    Button {
                        selectedCycleID = nil; selectedDate = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selected cycle")
                } else {
                    Text("Touch or drag to inspect a cycle.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .font(.subheadline)
            .frame(minHeight: selectionControlHeight)
            Chart {
                ForEach(cycles) { cycle in
                    if let value = metric.value(cycle) {
                        LineMark(x: .value("Cycle completed", cycle.end), y: .value(metric.unit, Numbers.double(value)))
                            .foregroundStyle(LedgerStyle.accent)
                        PointMark(x: .value("Cycle completed", cycle.end), y: .value(metric.unit, Numbers.double(value)))
                            .foregroundStyle(LedgerStyle.accent)
                            .symbolSize(selectedCycleID == cycle.id ? 80 : 30)
                            .annotation(position: .top, spacing: 20,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                if selectedCycleID == cycle.id { selectionCallout(cycle) }
                            }
                    }
                }
                RuleMark(y: .value("Average", Numbers.double(statistics.average)))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) { Text("Average").font(.caption2).foregroundStyle(.secondary) }
                if let selected {
                    RuleMark(x: .value("Selected cycle", selected.end))
                        .foregroundStyle(.secondary.opacity(0.4))
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYScale(domain: .automatic(includesZero: true),
                         range: .plotDimension(startPadding: 0, endPadding: calloutHeadroom))
            .frame(height: 200 + calloutHeadroom)
            .onChange(of: selectedDate) { _, date in
                // Charts clears its transient gesture value on release. Keep the inspected cycle
                // until the user clears it or chooses another point, so its details remain readable.
                guard let date else { return }
                selectedCycleID = cycles.min {
                    abs($0.end.timeIntervalSince(date)) < abs($1.end.timeIntervalSince(date))
                }?.id
            }
        }
        .onChange(of: cycles.map(\.id)) { _, _ in selectedCycleID = nil; selectedDate = nil }
    }

    private func selectionCallout(_ cycle: PeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(LedgerStyle.number(metric.value(cycle), digits: 2)) \(metric.unit)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("\(cycle.end.formatted(date: .abbreviated, time: .omitted)) · \(LedgerStyle.number(cycle.distance)) km")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 200, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func statistic(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(LedgerStyle.number(value, digits: 2)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(LedgerStyle.number(value, digits: 2)) \(metric.unit)")
    }
}

struct MonthlyRatioChart: View {
    let months: [PeriodSummary]
    let metric: CycleMetric
    private var measured: [PeriodSummary] { months.filter { metric.value($0) != nil } }
    private var title: String {
        metric == .consumption ? "Monthly average consumption" : "Monthly average cost per kilometre"
    }
    private var note: String {
        let formula = metric == .consumption
            ? "(Home + outside energy) ÷ Trip A kilometres × 100."
            : "(Estimated home cost + outside payments) ÷ Trip A kilometres."
        return formula + " Requires complete energy and positive Trip A mileage. Late readings cover their actual dates."
    }

    var body: some View {
        ReportCard(title: "\(title) · \(metric.unit)", note: note) {
            if measured.isEmpty {
                Text("Record Trip A kilometres and consecutive monthly meter readings to see an average for each month.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart(measured) { summary in
                    if let month = summary.month, let value = metric.value(summary) {
                        BarMark(x: .value("Month", month, unit: .month),
                                y: .value(metric.unit, Numbers.double(value)))
                            .foregroundStyle(LedgerStyle.accent)
                            .annotation(position: .top) {
                                Text(LedgerStyle.number(value, digits: 2)).font(.caption).monospacedDigit()
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 200)
            }
        }
    }
}

struct ChargingSourceChart: View {
    let statistics: CycleStatistics
    private struct Source: Identifiable {
        let id: String
        let energy: Decimal
        let cost: Decimal
    }
    private var sources: [Source] {
        [Source(id: "Home", energy: statistics.homeEnergy, cost: statistics.homeCost),
         Source(id: "Outside", energy: statistics.outsideEnergy, cost: statistics.outsideCost)]
    }
    var body: some View {
        ReportCard(title: "Home versus outside", note: "Completed cycles only. Home spending is estimated at saved prices; outside spending is the actual amount paid.") {
            HorizontalComparisonChart(
                rows: sources.map {
                    HorizontalComparisonRow(id: $0.id, label: $0.id, value: Numbers.double($0.energy),
                                            color: $0.id == "Home" ? LedgerStyle.accent : LedgerStyle.outside)
                },
                unit: "kWh", labelWidth: 60
            )
            metricPair("Outside energy share", LedgerStyle.number(statistics.outsideEnergyShare),
                       "Outside spending share", LedgerStyle.number(statistics.outsideCostShare), unit: "%")
            metricPair("Home average price", LedgerStyle.number(statistics.homePricePerKWh, digits: 2),
                       "Outside average price", LedgerStyle.number(statistics.outsidePricePerKWh, digits: 2), unit: "AMD/kWh")
        }
    }

    private func metricPair(_ first: String, _ firstValue: String,
                            _ second: String, _ secondValue: String, unit: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                Metric(title: first, value: firstValue, unit: unit).fixedSize(horizontal: true, vertical: false)
                Metric(title: second, value: secondValue, unit: unit).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                Metric(title: first, value: firstValue, unit: unit)
                Metric(title: second, value: secondValue, unit: unit)
            }
        }
    }
}

enum BrandMeasure: String, CaseIterable {
    case energy = "kWh", spending = "AMD", sessions = "Sessions"
    func value(_ brand: BrandSummary) -> Double {
        switch self {
        case .energy: Numbers.double(brand.energy)
        case .spending: Numbers.double(brand.cost)
        case .sessions: Double(brand.sessions)
        }
    }
}

struct BrandComparisonChart: View {
    let brands: [BrandSummary]
    @State private var measure = BrandMeasure.energy
    private var sorted: [BrandSummary] {
        brands.sorted { measure.value($0) == measure.value($1) ? $0.id < $1.id : measure.value($0) > measure.value($1) }
    }
    var body: some View {
        ReportCard(title: "Charging station comparison", note: "Compare energy, actual payments or session count by charging station.") {
            Picker("Compare stations by", selection: $measure) {
                ForEach(BrandMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            // IDs distinguish an unassigned station from one literally named “Unspecified”.
            HorizontalComparisonChart(
                rows: sorted.map { brand in
                    HorizontalComparisonRow(
                        id: brand.id, label: brand.name, value: measure.value(brand),
                        color: LedgerStyle.outside,
                        valueLabel: measure == .sessions ? String(brand.sessions)
                            : LedgerStyle.number(measure == .energy ? brand.energy : brand.cost)
                    )
                },
                unit: measure.rawValue
            )
        }
    }
}

private struct HorizontalComparisonRow: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
    var valueLabel: String? = nil
}

/// Both text columns use the bar's actual categorical position in the plot, rather
/// than axis-label placement (which can anchor a label at a category boundary).
private struct HorizontalComparisonChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rows: [HorizontalComparisonRow]
    let unit: String
    @ScaledMetric(relativeTo: .caption) var labelWidth: CGFloat = 90
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 52
    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 28
    private let columnSpacing: CGFloat = 8
    private var upperBound: Double { max(rows.map(\.value).max() ?? 0, 1) }

    var body: some View {
        GeometryReader { container in
            let categoryWidth = min(labelWidth, container.size.width * 0.34)
            HStack(spacing: columnSpacing) {
                Color.clear.frame(width: categoryWidth)
                Chart(rows) { row in
                    BarMark(x: .value(unit, row.value), y: .value("Category", row.id), width: .ratio(0.65))
                        .foregroundStyle(row.color)
                        .accessibilityLabel(row.label)
                        .accessibilityValue("\(row.valueLabel ?? row.value.formatted()) \(unit)")
                }
                .chartYScale(domain: rows.map(\.id))
                .chartXScale(domain: 0...upperBound)
                .chartYAxis(.hidden)
                .chartXAxis {
                    if dynamicTypeSize >= .xxxLarge {
                        // Two endpoints stay readable when larger type narrows the plot.
                        AxisMarks(values: [0, upperBound]) { tick in
                            AxisGridLine()
                            numericAxisLabel(tick)
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 3)) { tick in
                            AxisGridLine()
                            numericAxisLabel(tick)
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plot = proxy.plotFrame {
                            let frame = geometry[plot]
                            ForEach(rows) { row in
                                if let y = proxy.position(forY: row.id) {
                                    Text(row.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .lineLimit(3)
                                        .frame(width: categoryWidth, alignment: .trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .position(x: frame.minX - columnSpacing - categoryWidth / 2,
                                                  y: frame.minY + y)
                                    if let value = row.valueLabel {
                                        Text(value)
                                            .font(.caption2).monospacedDigit()
                                            .fixedSize()
                                            .frame(width: 0, alignment: .leading)
                                            .position(x: frame.maxX + columnSpacing, y: frame.minY + y)
                                    }
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // Intrinsic text widths reserve room for every value, including the
                // largest formatted AMD amount at the current Dynamic Type size.
                if rows.contains(where: { $0.valueLabel != nil }) {
                    ZStack {
                        ForEach(rows) { row in
                            if let value = row.valueLabel {
                                Text(value).font(.caption2).monospacedDigit()
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .accessibilityHidden(true)
                }
            }
        }
        // Includes a separate axis band so the final category cannot touch the ticks.
        .frame(height: CGFloat(rows.count) * rowHeight + axisHeight)
    }

    private func numericAxisLabel(_ tick: AxisValue) -> some AxisMark {
        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName),
                       anchor: tick.as(Double.self) == 0 ? .topLeading : .topTrailing)
            .font(.caption2)
    }

}
