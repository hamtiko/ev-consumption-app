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
    private var selected: PeriodSummary? {
        guard let selectedDate else { return nil }
        return cycles.min { abs($0.end.timeIntervalSince(selectedDate)) < abs($1.end.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        ReportCard(title: "\(metric.title) · \(metric.unit)",
                   note: "Average is weighted by distance. Min/max are individual completed cycles. Tap or drag the chart to inspect a cycle.") {
            HStack {
                statistic("Average", statistics.average)
                statistic("Minimum", statistics.minimum)
                statistic("Maximum", statistics.maximum)
            }
            Chart {
                ForEach(cycles) { cycle in
                    if let value = metric.value(cycle) {
                        LineMark(x: .value("Cycle completed", cycle.end), y: .value(metric.unit, Numbers.double(value)))
                            .foregroundStyle(LedgerStyle.accent)
                        PointMark(x: .value("Cycle completed", cycle.end), y: .value(metric.unit, Numbers.double(value)))
                            .foregroundStyle(LedgerStyle.accent)
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
            .chartYScale(domain: .automatic(includesZero: true))
            .frame(height: 200)
            if let selected {
                Button { open(selected) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.end.formatted(date: .abbreviated, time: .omitted))
                            Text("\(LedgerStyle.number(metric.value(selected), digits: 2)) \(metric.unit) · \(LedgerStyle.number(selected.distance)) km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: cycles.map(\.id)) { _, _ in selectedDate = nil }
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
