import SwiftUI
import SwiftData
import ChargeLedgerCore

struct MileageForm: View {
    let request: EntryRequest
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var records: [MonthlyMileage]
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @AppStorage("averageRate") private var defaultRate = "47.5"
    @AppStorage("t1Rate") private var defaultT1 = "53.48"
    @AppStorage("t2Rate") private var defaultT2 = "43.48"
    @AppStorage("useTariffRates") private var defaultTariffs = false
    @State private var recordID = UUID()
    @State private var date = Date.now
    @State private var month = MonthIdentity.previous(to: .now)
    @State private var useAutomaticMonth = true
    @State private var distance = ""
    @State private var includeMeter = true
    @State private var singleMeter = true
    @State private var pricingWithTariffs = false
    @State private var meter = ""
    @State private var t1 = ""
    @State private var t2 = ""
    @State private var rate = ""
    @State private var rateT1 = ""
    @State private var rateT2 = ""
    @State private var prefilledValues = ["", "", ""]
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Reading date", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("Month completed", value: MonthIdentity.label(selectedMonth))
                } footer: {
                    Text("Record your dedicated charger meter on the 1st to measure the car’s contribution to your utility bill. Late readings cover the actual reading dates.")
                }
                if request.mileage != nil && savedMeter == nil {
                    Section {
                        Toggle("Add home meter reading", isOn: $includeMeter)
                    } footer: { Text("This older record contains mileage only. You can add a meter reading if you have one for that date.") }
                }
                if includeMeter {
                    Section {
                        if singleMeter {
                            DecimalField(title: "Meter counter", unit: "kWh", text: $meter,
                                         previous: previousMeter.map { Numbers.string($0.reading.total) }).focused($focused)
                        } else {
                            DecimalField(title: "T1 counter", unit: "kWh", text: $t1).focused($focused)
                            DecimalField(title: "T2 counter", unit: "kWh", text: $t2).focused($focused)
                        }
                        DisclosureGroup("Price for this record") {
                            if pricingWithTariffs {
                                DecimalField(title: "T1 price", unit: "AMD/kWh", text: $rateT1).focused($focused)
                                DecimalField(title: "T2 price", unit: "AMD/kWh", text: $rateT2).focused($focused)
                            } else {
                                DecimalField(title: "Home price", unit: "AMD/kWh", text: $rate).focused($focused)
                            }
                        }
                    } header: { Text("Home meter") } footer: {
                        Text("Prefilled from the latest known reading. Update to the current counter, or leave unchanged only if there has been no home charging. Two consecutive monthly meter readings establish a monthly home-energy report.")
                    }
                }
                Section {
                    DecimalField(title: "Trip A (optional)", unit: "km", text: $distance).focused($focused)
                } footer: {
                    Text("Leave blank if you don’t need monthly mileage. If entered, read and reset Trip A in your car. Trip B keeps running.")
                }
                Section {
                    DisclosureGroup("Change completed month") {
                        Toggle("Use previous month automatically", isOn: Binding(
                            get: { useAutomaticMonth }, set: { automatic in
                                if !automatic { month = MonthIdentity.previous(to: date) }
                                useAutomaticMonth = automatic
                            }))
                        if !useAutomaticMonth {
                            Picker("Month", selection: monthComponent(.month)) {
                                ForEach(1...12, id: \.self) { number in
                                    Text(Ledger.monthCalendar.monthSymbols[number - 1]).tag(number)
                                }
                            }
                            Stepper("Year: \(Ledger.monthCalendar.component(.year, from: month))",
                                    value: monthComponent(.year), in: 1...9999)
                        }
                    }
                } footer: {
                    Text(useAutomaticMonth
                         ? "The completed month is the month before the reading date."
                         : "Using the selected month. Change it only when recording an older month.")
                }
                Section {
                    Button(request.mileage == nil ? "Save monthly readings" : "Save changes", action: save)
                        .font(.headline).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Monthly readings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                singleMeter = !defaultTariffs; pricingWithTariffs = defaultTariffs
                rate = defaultRate; rateT1 = defaultT1; rateT2 = defaultT2
                if let saved = request.mileage {
                    recordID = saved.id; date = saved.date; month = saved.month; distance = saved.distanceText
                    useAutomaticMonth = false
                    includeMeter = savedMeter != nil
                    if let reading = savedMeter {
                        singleMeter = reading.meterTotalText != nil; pricingWithTariffs = reading.useTariffRates
                        meter = reading.meterTotalText ?? ""; t1 = reading.t1Text; t2 = reading.t2Text
                        rate = reading.averageRateText; rateT1 = reading.t1RateText; rateT2 = reading.t2RateText
                    }
                }
                prefillMeter()
            }
            .onChange(of: date) { _, _ in prefillMeter() }
            .alert("Check your readings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private var selectedMonth: Date {
        useAutomaticMonth ? MonthIdentity.previous(to: date) : month
    }

    private var savedMeter: Checkpoint? {
        checkpoints.first { $0.id == request.mileage?.id }
    }

    private var previousMeter: Checkpoint? {
        let latest = Ledger.latestMeterReading(before: date, excludingID: recordID, readings: checkpoints.map(\.reading))
        return checkpoints.first { $0.id == latest?.id }
    }

    private func prefillMeter() {
        guard savedMeter == nil, [meter, t1, t2] == prefilledValues else { return }
        meter = ""; t1 = ""; t2 = ""
        if let previous = previousMeter {
            if singleMeter { meter = Numbers.string(previous.reading.total) }
            else if previous.meterTotalText == nil { t1 = previous.t1Text; t2 = previous.t2Text }
        }
        prefilledValues = [meter, t1, t2]
    }

    private func monthComponent(_ component: Calendar.Component) -> Binding<Int> {
        Binding(get: { Ledger.monthCalendar.component(component, from: month) }, set: { value in
            var parts = Ledger.monthCalendar.dateComponents([.year, .month], from: month)
            parts.setValue(value, for: component)
            parts.day = 1; parts.hour = 12
            month = Ledger.monthCalendar.date(from: parts)!
        })
    }

    private func save() {
        let kilometres = Numbers.parse(distance)
        guard distance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kilometres != nil else {
            error = "Enter valid Trip A kilometres, or leave the field blank."; return
        }
        guard includeMeter || kilometres != nil else { error = "Add a home meter reading or Trip A kilometres."; return }
        let selectedMonth = self.selectedMonth
        let parts = Ledger.monthCalendar.dateComponents([.year, .month], from: selectedMonth)
        let start = Calendar.current.date(from: parts)!
        guard let next = Calendar.current.date(byAdding: .month, value: 1, to: start), date >= next else {
            error = "Select a completed month and its actual reset date."; return
        }
        guard date <= .now else { error = "Choose a reading date in the past or present."; return }
        guard !records.contains(where: { $0.id != request.mileage?.id && $0.month == selectedMonth }) else {
            error = "A record for this month already exists. Edit it in the journal."; return
        }
        var reading: Reading?
        if includeMeter {
            let first: Decimal, second: Decimal, total: Decimal?
            if singleMeter {
                guard let counter = Numbers.parse(meter) else { error = "Enter the meter counter."; return }
                first = 0; second = 0; total = counter
            } else {
                guard let a = Numbers.parse(t1), let b = Numbers.parse(t2) else { error = "Enter both tariff counters."; return }
                first = a; second = b; total = nil
            }
            guard let average = Numbers.parse(rate), let priceT1 = Numbers.parse(rateT1), let priceT2 = Numbers.parse(rateT2) else {
                error = "Enter valid prices."; return
            }
            let original = savedMeter?.reading
            let candidate = Reading(id: recordID, date: date, t1: first, t2: second, averageRate: average,
                                    t1Rate: priceT1, t2Rate: priceT2, useTariffRates: pricingWithTariffs,
                                    monthBoundary: Ledger.monthCalendar.date(byAdding: .month, value: 1, to: selectedMonth),
                                    closesCycle: original?.closesCycle ?? false, isBaseline: original?.isBaseline ?? false,
                                    tripA: kilometres, tripB: original?.tripB, battery: original?.battery, meterTotal: total)
            if let message = Ledger.validate(candidate, against: checkpoints.map(\.reading)) { error = message; return }
            reading = candidate
        }
        do {
            if let saved = request.mileage {
                saved.date = date; saved.month = selectedMonth; saved.distanceText = kilometres.map(Numbers.string) ?? ""
            } else {
                context.insert(MonthlyMileage(record: MileageRecord(id: recordID, date: date, month: selectedMonth,
                                                                  distance: kilometres ?? 0, distanceKnown: kilometres != nil)))
            }
            if let reading {
                let saved: Checkpoint
                if let existing = savedMeter { existing.update(with: reading); saved = existing }
                else { saved = Checkpoint(reading: reading); context.insert(saved) }
                saved.homeDataStatus = "entered"; saved.homeDataAddedAt = .now
            }
            try context.save()
            onSaved(request.mileage == nil && kilometres != nil ? "Now reset Trip A in your car. Trip B keeps running." : nil)
            dismiss()
        } catch {
            context.rollback(); self.error = error.localizedDescription
        }
    }
}

enum MonthIdentity {
    static func from(_ date: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month], from: date)
        parts.day = 1; parts.hour = 12
        return Ledger.monthCalendar.date(from: parts)!
    }

    static func previous(to readingDate: Date, calendar: Calendar = .current) -> Date {
        Ledger.monthCalendar.date(byAdding: .month, value: -1, to: from(readingDate, calendar: calendar))!
    }

    static func label(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Ledger.monthCalendar
        formatter.timeZone = Ledger.monthCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month)
    }
}
