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
            Chart(sources) { source in
                BarMark(x: .value("kWh", Numbers.double(source.energy)), y: .value("Source", source.id))
                    .foregroundStyle(by: .value("Source", source.id))
            }
            .chartForegroundStyleScale(["Home": LedgerStyle.accent, "Outside": LedgerStyle.outside])
            .chartLegend(.hidden)
            .frame(height: 95)
            HStack {
                Metric(title: "Outside energy share", value: LedgerStyle.number(statistics.outsideEnergyShare), unit: "%")
                Metric(title: "Outside spending share", value: LedgerStyle.number(statistics.outsideCostShare), unit: "%")
            }
            HStack {
                Metric(title: "Home average price", value: LedgerStyle.number(statistics.homePricePerKWh, digits: 2), unit: "AMD/kWh")
                Metric(title: "Outside average price", value: LedgerStyle.number(statistics.outsidePricePerKWh, digits: 2), unit: "AMD/kWh")
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
        ReportCard(title: "Charging brand comparison", note: "Compare energy, actual payments or session count. Brands describe where you charge, not driving efficiency.") {
            Picker("Compare brands by", selection: $measure) {
                ForEach(BrandMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            // IDs distinguish an unassigned brand from a brand literally named “Unspecified”.
            Chart(sorted) { brand in
                BarMark(x: .value(measure.rawValue, measure.value(brand)), y: .value("Brand", brand.id))
                    .foregroundStyle(LedgerStyle.outside)
                    .annotation(position: .trailing) {
                        Text(measure == .sessions ? String(brand.sessions) : LedgerStyle.number(measure == .energy ? brand.energy : brand.cost))
                            .font(.caption2)
                    }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), let brand = brands.first(where: { $0.id == key }) { Text(brand.name) }
                    }
                }
            }
            .frame(height: CGFloat(max(140, brands.count * 42)))
        }
    }
}
