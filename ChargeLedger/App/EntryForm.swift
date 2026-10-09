import SwiftUI
import SwiftData
import ChargeLedgerCore

struct EntryForm: View {
    let request: EntryRequest
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @AppStorage("averageRate") private var defaultRate = "47.5"
    @AppStorage("t1Rate") private var defaultT1 = "53.48"
    @AppStorage("t2Rate") private var defaultT2 = "43.48"
    @AppStorage("useTariffRates") private var defaultTariffs = false

    @State private var date = Date.now
    @State private var closedMonth = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @State private var t1 = ""
    @State private var t2 = ""
    @State private var tripA = ""
    @State private var tripB = ""
    @State private var batteryText = ""
    @State private var monthEnabled = false
    @State private var cycleEnabled = false
    @State private var outsideEnabled = false
    @State private var outsideEnergy = ""
    @State private var outsideCost = ""
    @State private var location = ""
    @State private var averageRate = "47.5"
    @State private var t1Rate = "53.48"
    @State private var t2Rate = "43.48"
    @State private var useTariffs = false
    @State private var initialized = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var isBaseline: Bool { request.kind == .baseline }
    private var isOutsideOnly: Bool { request.kind == .outside && !cycleEnabled }
    private var isEditing: Bool { request.checkpoint != nil || request.charge != nil }
    private var previous: Checkpoint? {
        checkpoints.last { $0.date < date && $0.id != request.checkpoint?.id }
    }
    private var linkedCharge: OutsideCharge? {
        if let id = request.checkpoint?.linkedChargeID { return charges.first { $0.id == id } }
        return request.charge
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Reading time", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                } footer: { Text("Use the time you read the counters, even when entering it later.") }

                if isBaseline {
                    Section {
                        Text("Enter your current meter readings to establish a starting point. Reports begin from here.")
                            .foregroundStyle(.secondary)
                        Toggle("Reset Trip A now", isOn: $monthEnabled)
                        Toggle("At 100% · reset Trip B now", isOn: $cycleEnabled)
                    } footer: {
                        Text("Only enable the counters you will reset now. A mid-month Trip A start produces a partial first month.")
                    }
                } else if request.kind == .month {
                    Section {
                        Toggle("Also reached 100%", isOn: $cycleEnabled)
                    }
                } else if request.kind == .outside && request.charge == nil {
                    Section { Toggle("Also reached 100% · close Trip B", isOn: $cycleEnabled) }
                }

                if monthEnabled && !isBaseline {
                    Section {
                        DatePicker("Month being closed", selection: $closedMonth, displayedComponents: .date)
                        DecimalField(title: "Trip A distance", unit: "km", text: $tripA)
                            .focused($fieldFocused)
                    } header: { Text("Monthly mileage") } footer: {
                        Text("Closing \(LedgerStyle.month(monthStart(closedMonth))). Trip B continues unless you also reached 100%.")
                    }
                }

                if cycleEnabled && !isBaseline {
                    Section("100% driving cycle") {
                        DecimalField(title: "Trip B distance", unit: "km", text: $tripB)
                            .focused($fieldFocused)
                        LabeledContent("Battery", value: "100%")
                    }
                }

                if !isOutsideOnly {
                    Section {
                        DecimalField(title: "T1 reading", unit: "kWh", text: $t1, previous: previous?.t1Text)
                            .focused($fieldFocused)
                        DecimalField(title: "T2 reading", unit: "kWh", text: $t2, previous: previous?.t2Text)
                            .focused($fieldFocused)
                        if let a = Numbers.parse(t1), let b = Numbers.parse(t2) {
                            LabeledContent("Total meter", value: "\(LedgerStyle.number(a + b, digits: 2)) kWh")
                        }
                        if !cycleEnabled {
                            DecimalField(title: "Battery level (optional)", unit: "%", text: $batteryText)
                                .focused($fieldFocused)
                        }
                    } header: { Text("Home meter") } footer: {
                        Text("Enter cumulative readings from your dedicated charger meter, including when charging outside.")
                    }

                    Section {
                        Picker("Pricing", selection: $useTariffs) {
                            Text("Single price").tag(false)
                            Text("T1 / T2 prices").tag(true)
                        }
                        if useTariffs {
                            DecimalField(title: "T1 price", unit: "AMD/kWh", text: $t1Rate).focused($fieldFocused)
                            DecimalField(title: "T2 price", unit: "AMD/kWh", text: $t2Rate).focused($fieldFocused)
                        } else {
                            DecimalField(title: "Home price", unit: "AMD/kWh", text: $averageRate).focused($fieldFocused)
                        }
                        Button("Use default prices") {
                            averageRate = defaultRate; t1Rate = defaultT1; t2Rate = defaultT2
                            useTariffs = defaultTariffs
                        }
                    } header: { Text("Home price for this record") } footer: {
                        Text("These prices apply to energy since the preceding meter reading. They are saved with this entry; defaults never change past reports. Use T1/T2 when your meter and grid time windows align.")
                    }
                }

                if cycleEnabled && request.kind != .outside && !isBaseline {
                    Section { Toggle("Include outside charging session", isOn: $outsideEnabled) }
                }

                if outsideEnabled || request.kind == .outside {
                    Section {
                        DecimalField(title: "Energy added", unit: "kWh", text: $outsideEnergy).focused($fieldFocused)
                        DecimalField(title: "Total paid", unit: "AMD", text: $outsideCost).focused($fieldFocused)
                        TextField("Location (optional)", text: $location)
                            .textInputAutocapitalization(.words).focused($fieldFocused)
                            .submitLabel(.done).onSubmit { fieldFocused = false }
                    } header: { Text("Outside charging") } footer: {
                        Text("Use the energy and total price from your charger app. Enter 0 for a free charge. Partial charges count too.")
                    }
                }

                if let summary = preview {
                    Section("Calculated summary") {
                        LabeledContent("Distance", value: "\(LedgerStyle.number(summary.distance)) km")
                        LabeledContent("Charging energy", value: "\(LedgerStyle.number(summary.totalEnergy, digits: 2)) kWh")
                        LabeledContent("Consumption", value: "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
                        LabeledContent("Estimated charging cost", value: "\(LedgerStyle.number(summary.estimatedTotalCost, digits: 2)) AMD")
                        LabeledContent("Estimated cost / km", value: "\(LedgerStyle.number(summary.costPerKM, digits: 2)) AMD")
                    }
                } else if !isBaseline && !isOutsideOnly {
                    Section {
                        Text("Your first checkpoint starts a measurement period if there is no matching earlier reset. A complete report appears after the next checkpoint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(isEditing ? "Save changes" : "Save entry", action: save)
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
            }
            .navigationTitle(isEditing ? "Edit entry" : request.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { fieldFocused = false }
                }
            }
            .onAppear(perform: load)
            .alert("Check your entry", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private func monthStart(_ value: Date) -> Date {
        var components = Calendar.current.dateComponents([.year, .month], from: value)
        // Noon UTC keeps the month label correct in every time zone, including UTC−12/+14.
        components.hour = 12
        return Ledger.monthCalendar.date(from: components)!
    }

    private func load() {
        guard !initialized else { return }; initialized = true
        monthEnabled = request.kind == .month
        cycleEnabled = request.kind == .cycle
        outsideEnabled = request.kind == .outside
        averageRate = defaultRate; t1Rate = defaultT1; t2Rate = defaultT2; useTariffs = defaultTariffs
        if let checkpoint = request.checkpoint {
            date = checkpoint.date; t1 = checkpoint.t1Text; t2 = checkpoint.t2Text
            monthEnabled = checkpoint.monthBoundary != nil; cycleEnabled = checkpoint.closesCycle
            tripA = checkpoint.tripAText ?? ""; tripB = checkpoint.tripBText ?? ""
            batteryText = checkpoint.battery.map(String.init) ?? ""
            averageRate = checkpoint.averageRateText; t1Rate = checkpoint.t1RateText
            t2Rate = checkpoint.t2RateText; useTariffs = checkpoint.useTariffRates
            if let boundary = checkpoint.monthBoundary {
                closedMonth = Ledger.monthCalendar.date(byAdding: .month, value: -1, to: boundary)!
            }
        }
        if let charge = linkedCharge {
            outsideEnabled = true; outsideEnergy = charge.energyText
            outsideCost = charge.costText; location = charge.location
            if request.checkpoint == nil { date = charge.date }
        }
    }

    private var candidateReading: Reading? {
        guard !isOutsideOnly,
              let first = Numbers.parse(t1), let second = Numbers.parse(t2),
              let rate = Numbers.parse(averageRate), let firstRate = Numbers.parse(t1Rate), let secondRate = Numbers.parse(t2Rate)
        else { return nil }
        var boundary: Date? = monthEnabled
            ? (isBaseline ? monthStart(date) : Ledger.monthCalendar.date(byAdding: .month, value: 1, to: monthStart(closedMonth)))
            : nil
        if isBaseline, monthEnabled, let original = request.checkpoint,
           original.date == date, let originalBoundary = original.monthBoundary {
            boundary = originalBoundary
        }
        return Reading(id: request.checkpoint?.id ?? UUID(), date: date, t1: first, t2: second,
                       averageRate: rate, t1Rate: firstRate, t2Rate: secondRate, useTariffRates: useTariffs,
                       monthBoundary: boundary, closesCycle: cycleEnabled, isBaseline: isBaseline,
                       tripA: monthEnabled && !isBaseline ? Numbers.parse(tripA) : nil,
                       tripB: cycleEnabled && !isBaseline ? Numbers.parse(tripB) : nil,
                       battery: cycleEnabled ? 100 : Int(batteryText.trimmingCharacters(in: .whitespaces)))
    }

    private var candidateCharge: Charge? {
        guard outsideEnabled || request.kind == .outside,
              let energy = Numbers.parse(outsideEnergy), energy > 0,
              let price = Numbers.parse(outsideCost) else { return nil }
        return Charge(id: linkedCharge?.id ?? UUID(), date: date, energy: energy, cost: price, location: location)
    }

    private var preview: PeriodSummary? {
        guard let candidate = candidateReading,
              Ledger.validate(candidate, against: checkpoints.map(\.reading)) == nil else { return nil }
        let readings = checkpoints.map(\.reading).filter { $0.id != candidate.id } + [candidate]
        var external = charges.map(\.charge).filter { $0.id != linkedCharge?.id }
        if let charge = candidateCharge { external.append(charge) }
        let summaries = cycleEnabled ? Ledger.cycles(readings: readings, charges: external)
            : Ledger.months(readings: readings, charges: external)
        return summaries.first { $0.id == candidate.id }
    }

    private func save() {
        guard date <= .now else { errorMessage = "Choose a reading time in the past or present."; return }
        if outsideEnabled || request.kind == .outside {
            guard candidateCharge != nil else { errorMessage = "Enter positive charging energy and a total price (0 for free)."; return }
        }
        if !isOutsideOnly {
            guard let candidate = candidateReading else {
                errorMessage = "Enter both meter readings and valid prices. Use digits and a decimal point or comma."; return
            }
            if !batteryText.isEmpty && !cycleEnabled && Int(batteryText.trimmingCharacters(in: .whitespaces)) == nil {
                errorMessage = "Enter battery level as a whole percentage, or leave it empty."; return
            }
            if let boundary = candidate.monthBoundary {
                let components = Ledger.monthCalendar.dateComponents([.year, .month], from: boundary)
                if let localMonthStart = Calendar.current.date(from: components), localMonthStart > date {
                    errorMessage = "The reading must be on or after the start of the new month."; return
                }
            }
            if let message = Ledger.validate(candidate, against: checkpoints.map(\.reading)) {
                errorMessage = message; return
            }
        }
        do {
            let charge = candidateCharge
            if let value = charge {
                if let existing = linkedCharge {
                    existing.date = value.date; existing.energyText = Numbers.string(value.energy)
                    existing.costText = Numbers.string(value.cost); existing.location = value.location
                } else { context.insert(OutsideCharge(charge: value)) }
            } else if let existing = linkedCharge { context.delete(existing) }
            if let candidate = candidateReading {
                if let existing = request.checkpoint {
                    existing.update(with: candidate); existing.linkedChargeID = charge?.id
                } else { context.insert(Checkpoint(reading: candidate, linkedChargeID: charge?.id)) }
            }
            try context.save()
            let reset: String?
            if isEditing { reset = nil }
            else if monthEnabled && cycleEnabled { reset = "Now reset Trip A and Trip B in your car." }
            else if monthEnabled { reset = "Now reset Trip A in your car. Trip B continues." }
            else if cycleEnabled { reset = "Now reset Trip B in your car." }
            else { reset = nil }
            onSaved(reset); dismiss()
        } catch {
            context.rollback()
            errorMessage = "Couldn’t save your entry. \(error.localizedDescription)"
        }
    }
}
