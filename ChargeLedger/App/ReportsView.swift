import SwiftUI
import SwiftData
import Charts
import ChargeLedgerCore

private enum ReportMode: String, CaseIterable {
    case cycles = "100% cycles"
    case energy = "Energy"
    case monthly = "Monthly"
}

struct ReportsView: View {
    let add: (EntryRequest) -> Void
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @Query(sort: \MonthlyMileage.month) private var mileage: [MonthlyMileage]
    @State private var mode = ReportMode.cycles
    @State private var monthsToShow = 6
    private var summaries: [PeriodSummary] {
        let all = reports(mode: mode, checkpoints: checkpoints, charges: charges, mileage: mileage)
        guard monthsToShow > 0, let start = Calendar.current.dateInterval(of: .month, for: .now)?.start,
              let cutoff = Calendar.current.date(byAdding: .month, value: -monthsToShow, to: start) else { return all }
        return all.filter { ($0.month ?? $0.end) >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Report", selection: $mode) {
                    ForEach(ReportMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("History", selection: $monthsToShow) {
                    Text("6 months").tag(6); Text("12 months").tag(12); Text("All").tag(0)
                }
                .pickerStyle(.segmented)
                if summaries.isEmpty {
                    ContentUnavailableView("No reports yet", systemImage: "chart.xyaxis.line",
                        description: Text(mode == .monthly ? "Record your home meter on the 1st. Trip A kilometres are optional." : "Record two 100% checkpoints to complete a cycle. Home readings complete the energy totals."))
                } else {
                    HStack {
                        if mode == .monthly {
                            let known = summaries.filter(\.homeEnergyKnown)
                            Metric(title: "Home energy · measured", value: LedgerStyle.number(known.isEmpty ? nil : known.reduce(0) { $0 + $1.homeEnergy }), unit: "kWh")
                            Metric(title: "Utility bill contribution", value: LedgerStyle.number(known.isEmpty ? nil : known.reduce(0) { $0 + $1.estimatedHomeCost }), unit: "AMD")
                        } else {
                            Metric(title: "Distance", value: LedgerStyle.number(summaries.reduce(0) { $0 + $1.distance }), unit: "km")
                            Metric(title: "Consumption · complete data", value: LedgerStyle.number(Ledger.weightedEfficiency(summaries), digits: 2), unit: "kWh/100 km")
                        }
                    }
                    .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
                    if mode == .energy {
                        Text("Home energy reports cover the trips between complete meter readings. Adding missing home data can split them into individual 100% cycles.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if mode == .monthly {
                        chartCard("Home charging energy", note: "Two consecutive monthly meter readings measure the home energy. Late readings cover their actual dates. Outside charging does not affect the utility bill.") {
                            Chart(summaries) { summary in
                                if summary.homeEnergyKnown {
                                    BarMark(x: .value("Month", chartDate(summary)), y: .value("kWh", Numbers.double(summary.homeEnergy)))
                                        .foregroundStyle(LedgerStyle.accent)
                                }
                            }
                        }
                    } else if summaries.contains(where: \.homeEnergyKnown) {
                        chartCard("Charging energy per 100 km", note: "Complete reports only. Partial data is excluded from this chart and the consumption average.") {
                            Chart(summaries) { summary in
                                if let value = summary.energyPer100KM {
                                    LineMark(x: .value("Period", chartDate(summary)), y: .value("kWh/100 km", Numbers.double(value)))
                                        .foregroundStyle(LedgerStyle.accent)
                                    PointMark(x: .value("Period", chartDate(summary)), y: .value("kWh/100 km", Numbers.double(value)))
                                        .foregroundStyle(LedgerStyle.accent)
                                }
                            }
                        }
                    }
                    if summaries.contains(where: \.distanceKnown) {
                        chartCard(mode == .monthly ? "Monthly mileage · optional" : "Distance driven", note: mode == .monthly ? "Recorded Trip A only. Months without mileage are omitted." : "Trip B distances for each period.") {
                            Chart(summaries) { summary in
                                if summary.distanceKnown {
                                    BarMark(x: .value("Period", chartDate(summary)), y: .value("km", Numbers.double(summary.distance)))
                                        .foregroundStyle(LedgerStyle.accent)
                                }
                            }
                        }
                    }
                    chartCard("Charging cost logged", note: "Home is the estimated utility bill contribution at saved prices. Outside payments are separate and do not increase your utility bill. Missing home totals are omitted.") {
                        Chart(summaries) { summary in
                            if summary.homeEnergyKnown {
                                BarMark(x: .value("Period", chartDate(summary)), y: .value("AMD", Numbers.double(summary.estimatedHomeCost)))
                                    .foregroundStyle(by: .value("Source", "Home"))
                            }
                            BarMark(x: .value("Period", chartDate(summary)), y: .value("AMD", Numbers.double(summary.outsideCost)))
                                .foregroundStyle(by: .value("Source", "Outside"))
                        }
                        .chartForegroundStyleScale(["Home": LedgerStyle.accent, "Outside": LedgerStyle.outside])
                    }
                    Text("Period details").font(.headline)
                    ForEach(summaries.reversed()) { summary in
                        NavigationLink {
                            PeriodDetailView(id: summary.id, mode: mode, add: add)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(summary.month.map(LedgerStyle.month) ?? summary.end.formatted(date: .abbreviated, time: .omitted))
                                        .font(.headline).foregroundStyle(.primary)
                                    if mode == .monthly && summary.homeEnergyKnown {
                                        Text("Home: \(LedgerStyle.number(summary.homeEnergy)) kWh · \(LedgerStyle.number(summary.estimatedHomeCost)) AMD")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if summary.distanceKnown {
                                        Text("\(LedgerStyle.number(summary.distance)) km")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !summary.homeEnergyKnown && mode != .monthly {
                                        Label("Partial data · add home reading", systemImage: "exclamationmark.circle.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if mode == .monthly && !summary.homeEnergyKnown {
                                        Text("Home cost pending · needs consecutive monthly meter readings")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
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

private struct PeriodDetailView: View {
    let id: UUID
    let mode: ReportMode
    let add: (EntryRequest) -> Void
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @Query(sort: \MonthlyMileage.month) private var mileage: [MonthlyMileage]
    private var summary: PeriodSummary? { reports(mode: mode, checkpoints: checkpoints, charges: charges, mileage: mileage).first { $0.id == id } }

    var body: some View {
        Form {
            if let summary {
                if !summary.homeEnergyKnown && mode != .monthly {
                    Section {
                        Label("This report is based on partial data", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        ForEach(checkpoints.filter { summary.missingHomeReadingIDs.contains($0.id) }) { reading in
                            Button("Add home data · \(reading.date.formatted(date: .abbreviated, time: .shortened))") {
                                add(EntryRequest(kind: .homeData, checkpoint: reading))
                            }
                        }
                    } footer: {
                        Text("Enter the home counter later, or confirm no home charging and use the latest known meter values. Reports update automatically.")
                    }
                }
                Section(mode == .monthly ? "Month" : "Measurement period") {
                    if let month = summary.month { LabeledContent("Month", value: LedgerStyle.month(month)) }
                    else {
                        LabeledContent("Started", value: summary.start.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Ended", value: summary.end.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Distance", value: summary.distanceKnown ? "\(LedgerStyle.number(summary.distance)) km" : "Not recorded")
                    if mode == .monthly && summary.homeEnergyKnown {
                        LabeledContent("Meter period started", value: summary.start.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Meter period ended", value: summary.end.formatted(date: .abbreviated, time: .shortened))
                    }
                    if summary.cycleCount > 1 { LabeledContent("100% cycles covered", value: String(summary.cycleCount)) }
                }
                Section("Energy") {
                    LabeledContent("Home", value: summary.homeEnergyKnown ? "\(LedgerStyle.number(summary.homeEnergy, digits: 2)) kWh" : "Not available yet")
                    LabeledContent("Outside logged", value: "\(LedgerStyle.number(summary.outsideEnergy, digits: 2)) kWh")
                    if summary.homeEnergyKnown {
                        LabeledContent("Total", value: "\(LedgerStyle.number(summary.totalEnergy, digits: 2)) kWh")
                        if summary.distanceKnown {
                            LabeledContent("Consumption", value: "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
                        }
                    }
                }
                Section("Cost") {
                    LabeledContent("Outside · actual paid", value: "\(LedgerStyle.number(summary.outsideCost, digits: 2)) AMD")
                    if summary.homeEnergyKnown {
                        LabeledContent(mode == .monthly ? "Utility bill contribution · estimated" : "Home · saved prices", value: "\(LedgerStyle.number(summary.estimatedHomeCost, digits: 2)) AMD")
                        LabeledContent("Total estimated", value: "\(LedgerStyle.number(summary.estimatedTotalCost, digits: 2)) AMD")
                        if summary.distanceKnown {
                            LabeledContent("Estimated per kilometre", value: "\(LedgerStyle.number(summary.costPerKM, digits: 2)) AMD/km")
                        }
                    }
                }
                if mode == .monthly && !summary.homeEnergyKnown {
                    Section {
                        Text("Home cost needs meter readings for both ends of this month. The first monthly reading establishes the next month’s starting counter. Monthly meter readings never reset Trip B; Trip A is optional.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if mode == .monthly {
                    Section {
                        Text("Home totals use the actual interval between the monthly readings and prices saved on each meter record. Read on the 1st for a calendar-month comparison, or align readings with your utility billing period. Outside sessions shown here cover the same measured period when home data is available.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let record = mileage.first(where: { $0.id == id }) {
                            Button("Edit monthly readings") { add(EntryRequest(kind: .month, mileage: record)) }
                        }
                    }
                }
                ForEach(checkpoints.filter { $0.hasMeterReading && ($0.endedOutside || $0.linkedChargeID != nil) && ($0.id == id || summary.start == $0.date) }) { reading in
                    Section {
                        if reading.homeDataStatus == "unchanged" { Text("No home charging confirmed · latest meter values used") }
                        Button("Edit home data · \(reading.date.formatted(date: .abbreviated, time: .omitted))") {
                            add(EntryRequest(kind: .homeData, checkpoint: reading))
                        }
                    }
                }
            } else {
                ContentUnavailableView("Report no longer available", systemImage: "chart.xyaxis.line")
            }
        }
        .navigationTitle(mode == .monthly ? "Monthly utility report" : "Charging report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func reports(mode: ReportMode, checkpoints: [Checkpoint], charges: [OutsideCharge], mileage: [MonthlyMileage]) -> [PeriodSummary] {
    switch mode {
    case .cycles: return Ledger.cycles(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
    case .energy: return Ledger.measurements(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
    case .monthly: return Ledger.months(readings: checkpoints.map(\.reading), charges: charges.map(\.charge), mileage: mileage.map(\.record))
    }
}
