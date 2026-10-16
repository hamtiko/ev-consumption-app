import SwiftUI
import SwiftData
import Charts
import ChargeLedgerCore

private enum ReportMode: String, CaseIterable {
    case consumption = "Consumption"
    case monthly = "Monthly"
    case stations = "Brands"
}

private extension ReportRange {
    var label: String {
        switch self {
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .twelveMonths: "12 months"
        case .yearToDate: "This year"
        case .all: "All time"
        }
    }
}

struct ReportsView: View {
    let add: (EntryRequest) -> Void
    @Query(sort: \Checkpoint.date) private var storedCheckpoints: [Checkpoint]
    private var checkpoints: [Checkpoint] { SyncRecords.unique(storedCheckpoints) }
    @Query(sort: \OutsideCharge.date) private var storedCharges: [OutsideCharge]
    private var charges: [OutsideCharge] { SyncRecords.unique(storedCharges) }
    @Query(sort: \MonthlyMileage.month) private var storedMileage: [MonthlyMileage]
    private var mileage: [MonthlyMileage] { SyncRecords.unique(storedMileage) }
    @State private var mode = ReportMode.consumption
    @State private var range = ReportRange.sixMonths
    @State private var selectedCycleID: UUID?
    private var cycles: [PeriodSummary] {
        Ledger.cycles(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
            .filter { range.includes($0.end, through: .now) }
    }
    private var allMonths: [PeriodSummary] {
        Ledger.months(readings: checkpoints.map(\.reading), charges: charges.map(\.charge), mileage: mileage.map(\.record))
    }
    private var months: [PeriodSummary] {
        allMonths.filter { $0.month.map { range.includesMonth($0, through: .now) } == true && $0.end <= .now }
    }
    private var outside: [OutsideCharge] { charges.filter { range.includes($0.date, through: .now) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Report", selection: $mode) {
                    ForEach(ReportMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Date range", selection: $range) {
                    ForEach(ReportRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                switch mode {
                case .consumption: consumptionReport
                case .monthly: monthlyReport
                case .stations: brandReport
                }
            }
            .padding(16)
        }
        .background(LedgerStyle.background)
        .navigationTitle("Reports")
        .navigationDestination(item: $selectedCycleID) { id in
            PeriodDetailView(id: id, mode: .consumption, add: add)
        }
    }

    @ViewBuilder private var consumptionReport: some View {
        if cycles.isEmpty {
            ContentUnavailableView("No cycles in this range", systemImage: "chart.xyaxis.line",
                description: Text("Record two 100% checkpoints to complete a cycle, or choose a wider date range."))
        } else {
            if let statistics = ReportAnalytics.cycleStatistics(cycles) {
                let eligible = ReportAnalytics.eligibleCycles(cycles)
                ReportCard(title: "\(statistics.consumption.sampleCount) completed cycles",
                           note: "Cycles are grouped by completion date. Totals and statistics exclude pending home data and zero-distance cycles.") {
                    HStack {
                        Metric(title: "Distance", value: LedgerStyle.number(statistics.distance), unit: "km")
                        Metric(title: "Energy supplied", value: LedgerStyle.number(statistics.totalEnergy), unit: "kWh")
                    }
                    HStack {
                        Metric(title: "Home cost · estimated", value: LedgerStyle.number(statistics.homeCost), unit: "AMD")
                        Metric(title: "Outside paid", value: LedgerStyle.number(statistics.outsideCost), unit: "AMD")
                    }
                }
                CycleTrendChart(cycles: eligible, metric: .consumption, statistics: statistics.consumption) { selectedCycleID = $0.id }
                CycleTrendChart(cycles: eligible, metric: .cost, statistics: statistics.costPerKM) { selectedCycleID = $0.id }
                ChargingSourceChart(statistics: statistics)
            } else {
                ReportCard(title: "Consumption is not available yet") {
                    Text("Complete the home readings for a cycle with kilometres driven. Pending cycles remain listed below and automatically join the charts when completed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            let pending = cycles.filter { !$0.homeEnergyKnown }
            if !pending.isEmpty {
                Label("\(pending.count) cycle\(pending.count == 1 ? "" : "s") with home data pending",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(.orange)
                Text("Open a pending cycle below to add home data or confirm no home charging. It is excluded from averages, min/max and consumption charts until completed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            periodLinks(cycles, mode: .consumption)
        }
    }

    @ViewBuilder private var monthlyReport: some View {
        if months.isEmpty {
            ContentUnavailableView("No monthly records in this range", systemImage: "calendar",
                description: Text("Record the home meter on the 1st. Trip A kilometres are optional."))
        } else {
            let known = months.filter(\.homeEnergyKnown)
            ReportCard(title: "Monthly utility costs", note: "Home cost is estimated from saved prices. Outside payments do not affect your utility bill.") {
                HStack {
                    Metric(title: "Home energy · measured", value: LedgerStyle.number(known.isEmpty ? nil : known.reduce(0) { $0 + $1.homeEnergy }), unit: "kWh")
                    Metric(title: "Utility bill contribution", value: LedgerStyle.number(known.isEmpty ? nil : known.reduce(0) { $0 + $1.estimatedHomeCost }), unit: "AMD")
                }
                if let latest = months.last, let change = ReportAnalytics.monthlyCostChange(for: latest, reports: allMonths) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(LedgerStyle.month(latest.month!)) versus previous month").font(.caption).foregroundStyle(.secondary)
                        Text("\(change.amount > 0 ? "+" : "")\(LedgerStyle.number(change.amount)) AMD\(change.percent.map { " · \($0 > 0 ? "+" : "")\(LedgerStyle.number($0))%" } ?? "")")
                            .font(.headline).monospacedDigit()
                    }
                }
            }
            MonthlyRatioChart(months: months, metric: .consumption)
            MonthlyRatioChart(months: months, metric: .cost)
            ReportCard(title: "Home charging energy · kWh", note: "Two consecutive monthly meter readings are required. Late readings cover their actual dates, shown in the details.") {
                Chart(known) { summary in
                    BarMark(x: .value("Month", summary.month!), y: .value("kWh", Numbers.double(summary.homeEnergy)))
                        .foregroundStyle(LedgerStyle.accent)
                }
                .frame(height: 200)
            }
            ReportCard(title: "Home versus outside spending · AMD", note: "Missing home totals are omitted. Outside sessions use the measured interval when both monthly meter readings exist.") {
                Chart(months) { summary in
                    if summary.homeEnergyKnown {
                        BarMark(x: .value("Month", summary.month!), y: .value("AMD", Numbers.double(summary.estimatedHomeCost)))
                            .foregroundStyle(by: .value("Source", "Home"))
                    }
                    BarMark(x: .value("Month", summary.month!), y: .value("AMD", Numbers.double(summary.outsideCost)))
                        .foregroundStyle(by: .value("Source", "Outside"))
                }
                .chartForegroundStyleScale(["Home": LedgerStyle.accent, "Outside": LedgerStyle.outside])
                .frame(height: 200)
            }
            if months.contains(where: \.distanceKnown) {
                ReportCard(title: "Monthly mileage · km", note: "Recorded Trip A only. Months without mileage are omitted.") {
                    Chart(months.filter(\.distanceKnown)) { summary in
                        BarMark(x: .value("Month", summary.month!), y: .value("km", Numbers.double(summary.distance)))
                            .foregroundStyle(LedgerStyle.accent)
                    }
                    .frame(height: 180)
                }
            }
            periodLinks(months, mode: .monthly)
        }
    }

    @ViewBuilder private var brandReport: some View {
        let brands = ReportAnalytics.brands(charges: outside.map(\.charge))
        if brands.isEmpty {
            ContentUnavailableView("No outside sessions in this range", systemImage: "bolt.car",
                description: Text("Add outside sessions to a 100% cycle and enter or choose a charging brand."))
        } else {
            ReportCard(title: "Outside charging", note: "Sessions are filtered by charging date, including sessions in pending cycles. Old records without a brand remain under Unspecified.") {
                HStack {
                    Metric(title: "Sessions", value: String(outside.count), unit: "")
                    Metric(title: "Energy added", value: LedgerStyle.number(brands.reduce(0) { $0 + $1.energy }), unit: "kWh")
                }
                Metric(title: "Actual amount paid", value: LedgerStyle.number(brands.reduce(0) { $0 + $1.cost }), unit: "AMD")
            }
            BrandComparisonChart(brands: brands)
            Text("Brand details").font(.headline)
            ForEach(brands) { brand in
                NavigationLink {
                    BrandDetailView(brandID: brand.id, name: brand.name, range: range, add: add)
                } label: {
                    ReportCard(title: brand.name) {
                        HStack {
                            Metric(title: "Energy share", value: LedgerStyle.number(brand.energyShare), unit: "%")
                            Metric(title: "Average paid price", value: LedgerStyle.number(brand.pricePerKWh, digits: 2), unit: "AMD/kWh")
                        }
                        Text("\(brand.sessions) sessions · \(LedgerStyle.number(brand.energy)) kWh · \(LedgerStyle.number(brand.cost)) AMD")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func periodLinks(_ summaries: [PeriodSummary], mode: ReportMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .monthly ? "Month details" : "Cycle details").font(.headline)
            ForEach(summaries.reversed()) { summary in
                NavigationLink { PeriodDetailView(id: summary.id, mode: mode, add: add) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(summary.month.map(LedgerStyle.month) ?? summary.end.formatted(date: .abbreviated, time: .omitted))
                                .font(.headline).foregroundStyle(.primary)
                            if summary.distanceKnown { Text("\(LedgerStyle.number(summary.distance)) km").font(.caption).foregroundStyle(.secondary) }
                            if summary.homeEnergyKnown {
                                Text(mode == .monthly ? "Home: \(LedgerStyle.number(summary.homeEnergy)) kWh · \(LedgerStyle.number(summary.estimatedHomeCost)) AMD"
                                     : "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km · \(LedgerStyle.number(summary.costPerKM, digits: 2)) AMD/km")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label(mode == .monthly ? "Home cost pending" : "Home data pending", systemImage: "clock")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

private struct PeriodDetailView: View {
    let id: UUID
    let mode: ReportMode
    let add: (EntryRequest) -> Void
    @Query(sort: \Checkpoint.date) private var storedCheckpoints: [Checkpoint]
    private var checkpoints: [Checkpoint] { SyncRecords.unique(storedCheckpoints) }
    @Query(sort: \OutsideCharge.date) private var storedCharges: [OutsideCharge]
    private var charges: [OutsideCharge] { SyncRecords.unique(storedCharges) }
    @Query(sort: \MonthlyMileage.month) private var storedMileage: [MonthlyMileage]
    private var mileage: [MonthlyMileage] { SyncRecords.unique(storedMileage) }
    private var summary: PeriodSummary? { reports(mode: mode, checkpoints: checkpoints, charges: charges, mileage: mileage).first { $0.id == id } }

    var body: some View {
        Form {
            if let summary {
                if !summary.homeEnergyKnown && mode != .monthly {
                    Section {
                        Label("Home data pending", systemImage: "clock.badge.exclamationmark")
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
                let sessions = charges.filter {
                    if mode == .monthly && !summary.homeEnergyKnown {
                        return $0.date >= summary.start && $0.date < summary.end
                    }
                    return $0.date > summary.start && $0.date <= summary.end
                }
                if !sessions.isEmpty {
                    Section("Outside sessions") {
                        ForEach(sessions) { session in
                            Button { add(sessionRequest(session, checkpoints: checkpoints)) } label: {
                                OutsideSessionReportRow(session: session)
                            }
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
                ForEach(checkpoints.filter { $0.hasMeterReading && $0.closesCycle && ($0.id == id || summary.start == $0.date) }) { reading in
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

private struct BrandDetailView: View {
    let brandID: String
    let name: String
    let range: ReportRange
    let add: (EntryRequest) -> Void
    @Query(sort: \OutsideCharge.date, order: .reverse) private var storedCharges: [OutsideCharge]
    private var charges: [OutsideCharge] { SyncRecords.unique(storedCharges) }
    @Query private var storedCheckpoints: [Checkpoint]
    private var checkpoints: [Checkpoint] { SyncRecords.unique(storedCheckpoints) }
    private var sessions: [OutsideCharge] {
        charges.filter { StationBrands.key($0.stationBrand) == brandID && range.includes($0.date, through: .now) }
    }
    var body: some View {
        List {
            if let brand = ReportAnalytics.brands(charges: sessions.map(\.charge)).first {
                Section("\(range.label) · \(brand.sessions) sessions") {
                    LabeledContent("Energy added", value: "\(LedgerStyle.number(brand.energy)) kWh")
                    LabeledContent("Amount paid", value: "\(LedgerStyle.number(brand.cost)) AMD")
                    LabeledContent("Average price", value: "\(LedgerStyle.number(brand.pricePerKWh, digits: 2)) AMD/kWh")
                }
                Section("Sessions · tap to edit") {
                    ForEach(sessions) { session in
                        Button { add(sessionRequest(session, checkpoints: checkpoints)) } label: {
                            OutsideSessionReportRow(session: session)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No sessions for this brand", systemImage: "bolt.car")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OutsideSessionReportRow: View {
    let session: OutsideCharge
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.stationBrand ?? "Unspecified").font(.headline).foregroundStyle(.primary)
            Text("\(session.energyText) kWh · \(session.costText) AMD").foregroundStyle(.secondary)
            if !session.location.isEmpty { Text(session.location).font(.caption).foregroundStyle(.secondary) }
            Text(session.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func sessionRequest(_ session: OutsideCharge, checkpoints: [Checkpoint]) -> EntryRequest {
    if let checkpoint = checkpoints.first(where: { $0.linkedChargeID == session.id }) {
        return EntryRequest(kind: .cycle, checkpoint: checkpoint)
    }
    return EntryRequest(kind: .outside, charge: session)
}

private func reports(mode: ReportMode, checkpoints: [Checkpoint], charges: [OutsideCharge], mileage: [MonthlyMileage]) -> [PeriodSummary] {
    switch mode {
    case .consumption: return Ledger.cycles(readings: checkpoints.map(\.reading), charges: charges.map(\.charge))
    case .stations: return []
    case .monthly: return Ledger.months(readings: checkpoints.map(\.reading), charges: charges.map(\.charge), mileage: mileage.map(\.record))
    }
}
