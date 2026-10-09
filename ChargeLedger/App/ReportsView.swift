import SwiftUI
import SwiftData
import Charts
import ChargeLedgerCore

struct ReportsView: View {
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @State private var showCycles = false
    @State private var monthsToShow = 6
    private var summaries: [PeriodSummary] {
        let all = showCycles ? Ledger.cycles(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
            : Ledger.months(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
        guard monthsToShow > 0,
              let currentMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start,
              let cutoff = Calendar.current.date(byAdding: .month, value: -monthsToShow, to: currentMonth) else { return all }
        return all.filter { ($0.month ?? $0.end) >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Measurement period", selection: $showCycles) {
                    Text("Monthly · Trip A").tag(false)
                    Text("100% cycles · Trip B").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("History", selection: $monthsToShow) {
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                    Text("All history").tag(0)
                }
                .pickerStyle(.segmented)
                if summaries.isEmpty {
                    ContentUnavailableView("Reports need two checkpoints", systemImage: "chart.xyaxis.line",
                                           description: Text(showCycles ? "Record two 100% checkpoints to complete a Trip B cycle." : "Record consecutive monthly checkpoints with Trip A mileage. Missing months are not filled with estimates."))
                } else {
                    HStack {
                        Metric(title: "Weighted consumption", value: LedgerStyle.number(Ledger.weightedEfficiency(summaries), digits: 2), unit: "kWh/100 km")
                        Metric(title: "Total distance", value: LedgerStyle.number(summaries.reduce(0) { $0 + $1.distance }), unit: "km")
                    }
                    .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))

                    chartCard("Charging energy per 100 km", note: "Electricity supplied, including charging losses.") {
                        Chart(summaries) { summary in
                            if let value = summary.energyPer100KM {
                                LineMark(x: .value("Period", chartDate(summary)), y: .value("kWh/100 km", Numbers.double(value)))
                                    .foregroundStyle(LedgerStyle.accent)
                                PointMark(x: .value("Period", chartDate(summary)), y: .value("kWh/100 km", Numbers.double(value)))
                                    .foregroundStyle(LedgerStyle.accent)
                            }
                        }
                    }
                    chartCard("Charging cost", note: "Home cost uses the prices saved on each reading. Outside costs are the amounts paid.") {
                        Chart(summaries) { summary in
                            BarMark(x: .value("Period", chartDate(summary)), y: .value("AMD", Numbers.double(summary.estimatedHomeCost)))
                                .foregroundStyle(by: .value("Source", "Home"))
                            BarMark(x: .value("Period", chartDate(summary)), y: .value("AMD", Numbers.double(summary.outsideCost)))
                                .foregroundStyle(by: .value("Source", "Outside"))
                        }
                        .chartForegroundStyleScale(["Home": LedgerStyle.accent, "Outside": LedgerStyle.outside])
                    }
                    chartCard("Estimated cost per kilometre", note: "AMD/km, including home and outside charging.") {
                        Chart(summaries) { summary in
                            if let value = summary.costPerKM {
                                BarMark(x: .value("Period", chartDate(summary)), y: .value("AMD/km", Numbers.double(value)))
                                    .foregroundStyle(LedgerStyle.accent)
                            }
                        }
                    }
                    chartCard("Where your energy comes from", note: "Home and outside charging, in kWh.") {
                        Chart(summaries) { summary in
                            BarMark(x: .value("Period", chartDate(summary)), y: .value("kWh", Numbers.double(summary.homeEnergy)))
                                .foregroundStyle(by: .value("Source", "Home"))
                            BarMark(x: .value("Period", chartDate(summary)), y: .value("kWh", Numbers.double(summary.outsideEnergy)))
                                .foregroundStyle(by: .value("Source", "Outside"))
                        }
                        .chartForegroundStyleScale(["Home": LedgerStyle.accent, "Outside": LedgerStyle.outside])
                    }
                    Text("Period details").font(.headline)
                    ForEach(summaries.reversed()) { summary in
                        NavigationLink {
                            PeriodDetailView(summary: summary)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(summary.month.map(LedgerStyle.month) ?? summary.end.formatted(date: .abbreviated, time: .omitted))
                                        .font(.headline).foregroundStyle(.primary)
                                    Text("\(LedgerStyle.number(summary.distance)) km · \(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(LedgerStyle.background)
        .navigationTitle("Reports")
    }

    private func chartDate(_ summary: PeriodSummary) -> Date { summary.month ?? summary.end }

    private func chartCard<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content().frame(height: 190)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PeriodDetailView: View {
    let summary: PeriodSummary
    var body: some View {
        Form {
            Section("Measurement period") {
                LabeledContent("Started", value: summary.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Ended", value: summary.end.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Distance", value: "\(LedgerStyle.number(summary.distance)) km")
                if let battery = summary.startBattery { LabeledContent("Starting battery", value: "\(battery)%") }
                if let battery = summary.endBattery { LabeledContent("Ending battery", value: "\(battery)%") }
            }
            Section("Energy") {
                LabeledContent("Home", value: "\(LedgerStyle.number(summary.homeEnergy, digits: 2)) kWh")
                LabeledContent("Outside", value: "\(LedgerStyle.number(summary.outsideEnergy, digits: 2)) kWh")
                LabeledContent("Total", value: "\(LedgerStyle.number(summary.totalEnergy, digits: 2)) kWh")
                LabeledContent("Consumption", value: "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
            }
            Section("Cost") {
                LabeledContent("Home · saved prices", value: "\(LedgerStyle.number(summary.estimatedHomeCost, digits: 2)) AMD")
                LabeledContent("Outside · actual paid", value: "\(LedgerStyle.number(summary.outsideCost, digits: 2)) AMD")
                LabeledContent("Total estimated", value: "\(LedgerStyle.number(summary.estimatedTotalCost, digits: 2)) AMD")
                LabeledContent("Estimated per kilometre", value: "\(LedgerStyle.number(summary.costPerKM, digits: 2)) AMD/km")
            }
            Section {
                LabeledContent("Home using T1/T2 rates", value: "\(LedgerStyle.number(summary.tariffComparisonCost, digits: 2)) AMD")
            } header: { Text("Tariff comparison") } footer: {
                Text("This comparison depends on matching the meter’s tariff time windows to the grid’s. Battery percentages are shown for context; no assumed battery-capacity correction is applied.")
            }
        }
        .navigationTitle(summary.month.map(LedgerStyle.month) ?? "100% cycle")
        .navigationBarTitleDisplayMode(.inline)
    }
}
