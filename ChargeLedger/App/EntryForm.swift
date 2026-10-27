import SwiftUI
import SwiftData
import ChargeLedgerCore

struct EntryForm: View {
    let request: EntryRequest
    let onSaved: (String?) -> Void
    var body: some View {
        if request.kind == .month {
            MileageForm(request: request, onSaved: onSaved)
        } else if request.kind == .homeData, let checkpoint = request.checkpoint {
            HomeDataForm(checkpoint: checkpoint)
        } else {
            ChargingForm(request: request, onSaved: onSaved)
        }
    }
}

private struct SessionDraft: Identifiable {
    let id = UUID()
    var date: Date
    var energy = ""
    var cost = ""
    var brand = ""
    var location = ""
    var charge: Charge? {
        guard let energy = Numbers.parse(energy), energy > 0, let cost = Numbers.parse(cost) else { return nil }
        return Charge(id: id, date: date, energy: energy, cost: cost, location: location, stationBrand: brand)
    }
}

private struct ChargingForm: View {
    let request: EntryRequest
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Checkpoint.date) private var storedCheckpoints: [Checkpoint]
    private var checkpoints: [Checkpoint] { SyncRecords.unique(storedCheckpoints) }
    @Query(sort: \OutsideCharge.date) private var storedCharges: [OutsideCharge]
    private var charges: [OutsideCharge] { SyncRecords.unique(storedCharges) }
    @Query private var storedMonthlyRecords: [MonthlyMileage]
    private var monthlyRecords: [MonthlyMileage] { SyncRecords.unique(storedMonthlyRecords) }
    @AppStorage("averageRate") private var defaultRate = "47.5"
    @AppStorage("t1Rate") private var defaultT1 = "53.48"
    @AppStorage("t2Rate") private var defaultT2 = "43.48"
    @AppStorage("useTariffRates") private var defaultTariffs = false
    @State private var recordID = UUID()
    @State private var sessionID = UUID()
    @State private var date = Date.now
    @State private var outsideFull = false
    @State private var baselineAt100 = false
    @State private var homeReadingAvailable = true
    @State private var prefilledValues = ["", "", ""]
    @State private var singleMeter = true
    @State private var pricingWithTariffs = false
    @State private var meter = ""
    @State private var t1 = ""
    @State private var t2 = ""
    @State private var tripB = ""
    @State private var tripBCalculation: TripBCalculation?
    @State private var calculationPreviousID: UUID?
    @State private var tripBCounterKnown = true
    @State private var rememberedCounter = ""
    @State private var calculationNeedsReview = false
    @State private var calculatorRequest: TripBCalculatorRequest?
    @State private var showingPreviousCycle = false
    @State private var energy = ""
    @State private var cost = ""
    @State private var brand = ""
    @State private var location = ""
    @State private var rate = "47.5"
    @State private var rateT1 = "53.48"
    @State private var rateT2 = "43.48"
    @State private var selectedSessionID: UUID?
    @State private var earlier: [SessionDraft] = []
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: InputField?

    private var isOutside: Bool { request.kind == .outside }
    private var isBaseline: Bool { request.kind == .baseline }
    private var closesCycle: Bool { isBaseline ? baselineAt100 : request.kind == .cycle || outsideFull }
    private var editing: Bool { request.checkpoint != nil || request.charge != nil }
    private var hasHomeData: Bool {
        isOutside ? (request.checkpoint?.hasMeterReading ?? false) : homeReadingAvailable
    }
    private var existingSession: OutsideCharge? {
        let id = selectedSessionID ?? request.checkpoint?.linkedChargeID ?? request.charge?.id
        return charges.first { $0.id == id }
    }
    private var previousFull: Checkpoint? {
        checkpoints.last { $0.closesCycle && $0.date < date && $0.id != request.checkpoint?.id }
    }
    private var previousMeter: Checkpoint? {
        let latest = Ledger.latestMeterReading(before: date, excludingID: request.checkpoint?.id, readings: checkpoints.map(\.reading))
        return checkpoints.first { $0.id == latest?.id }
    }
    private var cycleStart: Date? { previousFull?.date }
    private var effectiveCharges: [Charge] {
        CycleEntryContext.combining(saved: charges.map(\.charge), replacingID: existingSession?.id,
                                    replacement: outsideCharge, drafts: earlier.compactMap(\.charge))
    }
    private var cycleContext: CycleEntryContext {
        CycleEntryContext(endingAt: date, excludingCheckpointID: request.checkpoint?.id,
                          readings: checkpoints.map(\.reading), charges: effectiveCharges)
    }
    private var loggedSessions: [OutsideCharge] {
        let start = cycleStart
        return charges.filter { session in
            session.id != existingSession?.id && session.date <= date && (start.map { session.date > $0 } ?? true)
        }
    }
    private var manualTripB: Binding<String> {
        Binding(get: { tripB }, set: { tripB = $0; tripBCounterKnown = true; calculationNeedsReview = false })
    }
    private var preservingSavedCalculation: Bool {
        guard let saved = request.checkpoint, let calculation = tripBCalculation else { return false }
        return date == saved.date && calculationPreviousID == saved.tripBPreviousCheckpointID
            && calculation.currentCounter == saved.tripBCounterText.flatMap(Numbers.parse)
            && calculation.previousCounter == saved.tripBPreviousCounterText.flatMap(Numbers.parse)
            && calculation.distance == saved.tripBText.flatMap(Numbers.parse)
    }
    private var brandChoices: [String] {
        StationBrands.choices(charges.map(\.stationBrand) + earlier.map { Optional($0.brand) })
    }

    var body: some View {
        NavigationStack {
            KeyboardForm(focus: $focused) {
                Section {
                    DatePicker("Date and time", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                }
                if closesCycle && !isBaseline { previousCycleSection }
                if isOutside { outsideSessionSection }
                if closesCycle && !isBaseline {
                    tripBSection
                    earlierSessionsSection
                }
                if request.kind == .cycle {
                    Section {
                        Toggle("Home meter reading available", isOn: $homeReadingAvailable)
                    } footer: {
                        Text("Turn this off if you are away and cannot confirm the home counter. The cycle will show home data pending until you complete it.")
                    }
                }
                if !isOutside && hasHomeData { homeMeterSection }
                if isBaseline {
                    Section {
                        Toggle("Car is at 100% now", isOn: $baselineAt100)
                    } footer: {
                        Text("Starting readings establish the home meter baseline. If the car is at 100%, save and reset Trip B to start a complete cycle.")
                    }
                }
                if let summary = preview {
                    Section("This 100% cycle") {
                        LabeledContent("Distance", value: "\(LedgerStyle.number(summary.distance)) km")
                        if summary.homeEnergyKnown {
                            LabeledContent("Total energy", value: "\(LedgerStyle.number(summary.totalEnergy, digits: 2)) kWh")
                            LabeledContent("Consumption", value: "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
                            LabeledContent("Estimated cost", value: "\(LedgerStyle.number(summary.estimatedTotalCost, digits: 2)) AMD")
                        } else {
                            LabeledContent("Outside energy", value: "\(LedgerStyle.number(summary.outsideEnergy, digits: 2)) kWh")
                            LabeledContent("Outside cost", value: "\(LedgerStyle.number(summary.outsideCost, digits: 2)) AMD")
                            Text("Home energy is measured when you next enter a home meter reading.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    FormSaveButton(action: save)
                }
            }
            .navigationTitle(editing ? "Edit entry" : request.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear(perform: load)
            .onChange(of: date) { _, _ in prefillMeter() }
            .onChange(of: previousFull?.id) { _, id in
                if let calculation = tripBCalculation, calculationPreviousID != id, !preservingSavedCalculation {
                    rememberedCounter = Numbers.string(calculation.currentCounter)
                    tripBCalculation = nil; calculationPreviousID = nil; tripB = ""
                    calculationNeedsReview = true
                }
            }
            .sheet(isPresented: $showingPreviousCycle) {
                if let summary = cycleContext.previousCycle {
                    CycleReferenceView(summary: summary, sessions: cycleContext.previousCycleSessions,
                                       counterText: previousFull?.tripBCounterText)
                }
            }
            .sheet(item: $calculatorRequest) { calculator in
                TripBCalculatorForm(previousDate: calculator.previousDate,
                                    previousCycleDistance: calculator.previousCycleDistance,
                                    currentText: calculator.currentText, previousText: calculator.previousText) { calculation in
                    guard previousFull?.id == calculator.previousID, previousFull?.date == calculator.previousDate else {
                        calculationNeedsReview = true; return
                    }
                    tripBCalculation = calculation; calculationPreviousID = calculator.previousID
                    tripB = Numbers.string(calculation.distance); calculationNeedsReview = false
                    rememberedCounter = Numbers.string(calculation.currentCounter)
                }
            }
            .alert("Check your entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private var previousCycleSection: some View {
        let context = cycleContext
        return Section {
            if let previous = previousFull {
                VStack(alignment: .leading, spacing: 8) {
                    if let summary = context.previousCycle {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(LedgerStyle.number(summary.distance, digits: 2)) km").font(.title2.weight(.semibold))
                                Text("\(summary.start.formatted(date: .abbreviated, time: .omitted)) – \(summary.end.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View cycle") { focused = nil; showingPreviousCycle = true }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("Your first 100% checkpoint").font(.headline)
                    }
                    Text("Last 100%: \(previous.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let counter = previous.tripBCounterText {
                        Text("Car Trip B at that charge: \(counter) km").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No previous 100% charge. This entry starts your first cycle.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: { Text("Previous cycle") }
    }

    private var tripBSection: some View {
        Section {
            if let calculation = tripBCalculation {
                LabeledContent("Trip B · this cycle", value: "\(LedgerStyle.number(calculation.distance, digits: 2)) km")
                Text("Calculated: \(Numbers.string(calculation.currentCounter)) − \(Numbers.string(calculation.previousCounter)) km")
                    .font(.caption).foregroundStyle(.secondary)
                if previousFull != nil { Button("Edit calculation", action: openCalculator).buttonStyle(.borderless) }
                if calculationPreviousID != previousFull?.id {
                    Text("This saved calculation refers to an earlier checkpoint that has changed or was removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Enter Trip B directly") {
                    tripBCalculation = nil; calculationPreviousID = nil; tripB = ""
                    tripBCounterKnown = true; calculationNeedsReview = false; rememberedCounter = ""
                    focused = .tripB
                }
                .buttonStyle(.borderless)
            } else {
                DecimalField(title: "Trip B", unit: "km", text: manualTripB, focus: $focused, field: .tripB)
                if previousFull != nil { Button("Forgot to reset Trip B?", action: openCalculator).buttonStyle(.borderless) }
            }
            if calculationNeedsReview {
                Text("The previous 100% charge changed. Check Trip B or calculate the distance again.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("Kilometres since the last 100% charge") } footer: {
            Text(tripBCalculation == nil ? "Read Trip B before resetting it in your car. If it kept running after the last 100% charge, use the calculator."
                 : "Only the calculated distance is used in reports. The actual counter is kept for reference. Reset Trip B after saving.")
        }
    }

    private func openCalculator() {
        guard let previous = previousFull else { return }
        focused = nil
        calculatorRequest = TripBCalculatorRequest(previousID: previous.id, previousDate: previous.date,
            previousCycleDistance: cycleContext.previousCycle?.distance,
            currentText: tripBCalculation.map { Numbers.string($0.currentCounter) }
                ?? (tripBCounterKnown && !tripB.isEmpty ? tripB : rememberedCounter),
            previousText: tripBCalculation.map { Numbers.string($0.previousCounter) } ?? previous.tripBCounterText ?? "")
    }

    private var outsideSessionSection: some View {
        Section {
            DecimalField(title: "Energy added", unit: "kWh", text: $energy, focus: $focused, field: .energy)
            DecimalField(title: "Total paid", unit: "AMD", text: $cost, focus: $focused, field: .cost)
            StationBrandField(brand: $brand, choices: brandChoices, focus: $focused, field: .brand)
            TextField("Location (optional)", text: $location)
                .inputFocus(.location, focus: $focused).id(InputField.location)
            if isOutside { Toggle("Charged to 100%", isOn: $outsideFull).disabled(request.checkpoint != nil) }
        } header: { Text(existingSession == nil ? "Outside session" : "Outside session · editing saved entry") } footer: {
            Text(request.kind == .cycle ? "This saved session is included once in this cycle’s outside total."
                 : outsideFull ? "Record Trip B below to finish this cycle." : "Save this session now, or add it later when you next reach 100%. Trip B keeps running.")
        }
    }

    private var homeMeterSection: some View {
        Section {
            if singleMeter {
                DecimalField(title: "Meter counter", unit: "kWh", text: $meter, focus: $focused, field: .meter,
                             previous: previousMeter.map { Numbers.string($0.reading.total) })
            } else {
                DecimalField(title: "T1 counter", unit: "kWh", text: $t1, focus: $focused, field: .t1,
                             previous: previousMeter?.meterTotalText == nil ? previousMeter?.t1Text : nil)
                DecimalField(title: "T2 counter", unit: "kWh", text: $t2, focus: $focused, field: .t2,
                             previous: previousMeter?.meterTotalText == nil ? previousMeter?.t2Text : nil)
            }
            FormDisclosure("Price for this record") {
                if !pricingWithTariffs {
                    DecimalField(title: "Home price", unit: "AMD/kWh", text: $rate, focus: $focused, field: .homePrice)
                } else {
                    DecimalField(title: "T1 price", unit: "AMD/kWh", text: $rateT1, focus: $focused, field: .t1Price)
                    DecimalField(title: "T2 price", unit: "AMD/kWh", text: $rateT2, focus: $focused, field: .t2Price)
                }
                Button("Use default prices") { rate = defaultRate; rateT1 = defaultT1; rateT2 = defaultT2 }
            }
        } header: { Text("Home meter") } footer: {
            Text("The counter is prefilled from the latest home reading, including monthly records. Update it to the current value, or keep it unchanged only if there has been no home charging. Each record keeps its own price.")
        }
    }

    @ViewBuilder private var earlierSessionsSection: some View {
        let context = cycleContext
        Section {
            if let start = context.start {
                Text("\(start.formatted(date: .abbreviated, time: .shortened)) → \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Sessions recorded up to \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if context.outsideSessions.isEmpty {
                Text("No outside sessions recorded in this interval.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("\(context.outsideSessions.count) sessions · \(LedgerStyle.number(context.outsideEnergy, digits: 2)) kWh · \(LedgerStyle.number(context.outsideCost, digits: 2)) AMD")
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(loggedSessions) { session in CycleOutsideSessionRow(session: session.charge, status: "Saved") }
            if isOutside && existingSession == nil && !loggedSessions.isEmpty {
                Menu("Use a saved session as this 100% charge") {
                    ForEach(loggedSessions) { session in
                        Button("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.energyText) kWh") {
                            selectedSessionID = session.id; date = session.date
                            energy = session.energyText; cost = session.costText
                            brand = session.stationBrand ?? ""; location = session.location
                        }
                    }
                }
            }
            Button {
                focused = nil
                earlier.append(SessionDraft(date: date))
            } label: { Label("Add outside session", systemImage: "plus") }
            .buttonStyle(.borderless)
        } header: { Text("Outside charging this cycle") } footer: {
            Text("Saved sessions are included automatically. Totals also include completed sessions entered below, within this interval.")
        }
        if !isOutside && existingSession != nil { outsideSessionSection }
        ForEach($earlier) { $session in
            // Separate Form rows let ScrollViewReader reveal the actual input, even when
            // this session's full card is taller than the viewport above the keyboard.
            Section {
                DatePicker("Session date", selection: $session.date,
                           in: min(cycleStart ?? .distantPast, date)...date, displayedComponents: [.date, .hourAndMinute])
                DecimalField(title: "Energy added", unit: "kWh", text: $session.energy,
                             focus: $focused, field: .sessionEnergy(session.id))
                DecimalField(title: "Total paid", unit: "AMD", text: $session.cost,
                             focus: $focused, field: .sessionCost(session.id))
                StationBrandField(brand: $session.brand, choices: brandChoices,
                                  focus: $focused, field: .sessionBrand(session.id))
                TextField("Location (optional)", text: $session.location)
                    .inputFocus(.sessionLocation(session.id), focus: $focused)
                    .id(InputField.sessionLocation(session.id))
                Button("Remove session", role: .destructive) {
                    focused = nil
                    earlier.removeAll { $0.id == session.id }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("New outside session \((earlier.firstIndex(where: { $0.id == session.id }) ?? 0) + 1)")
            } footer: {
                if session.charge == nil {
                    Text("Complete energy and price to include this session in the total.")
                } else if !context.contains(session.date) {
                    Text("This date is outside the selected cycle. Update it before saving.").foregroundStyle(.orange)
                } else {
                    Text("Included in this entry’s outside total. Saved when you save the cycle.")
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        singleMeter = !defaultTariffs; pricingWithTariffs = defaultTariffs
        rate = defaultRate; rateT1 = defaultT1; rateT2 = defaultT2
        if let saved = request.checkpoint {
            recordID = saved.id; date = saved.date; tripB = saved.tripBText ?? ""
            tripBCounterKnown = saved.tripBCounterText != nil && saved.tripBPreviousCounterText == nil
            rememberedCounter = saved.tripBCounterText ?? ""
            if let current = saved.tripBCounterText, let previous = saved.tripBPreviousCounterText,
               let previousID = saved.tripBPreviousCheckpointID,
               let calculation = try? TripBCalculation(currentText: current, previousText: previous),
               calculation.distance == Numbers.parse(tripB) {
                tripBCalculation = calculation; calculationPreviousID = previousID
            }
            outsideFull = isOutside && saved.closesCycle; baselineAt100 = saved.closesCycle
            singleMeter = saved.meterTotalText != nil; meter = saved.meterTotalText ?? ""
            pricingWithTariffs = saved.useTariffRates
            t1 = saved.t1Text; t2 = saved.t2Text
            rate = saved.averageRateText; rateT1 = saved.t1RateText; rateT2 = saved.t2RateText
            homeReadingAvailable = saved.hasMeterReading
            if !saved.hasMeterReading { singleMeter = !defaultTariffs; pricingWithTariffs = defaultTariffs }
        }
        if let saved = existingSession {
            sessionID = saved.id; energy = saved.energyText; cost = saved.costText
            brand = saved.stationBrand ?? ""; location = saved.location
            if request.checkpoint == nil { date = saved.date }
        }
        prefillMeter()
    }

    private func prefillMeter() {
        guard !editing, [meter, t1, t2] == prefilledValues else { return }
        meter = ""; t1 = ""; t2 = ""
        if let previous = previousMeter {
            if singleMeter { meter = Numbers.string(previous.reading.total) }
            else if previous.meterTotalText == nil { t1 = previous.t1Text; t2 = previous.t2Text }
        }
        prefilledValues = [meter, t1, t2]
    }

    private var reading: Reading? {
        guard !isOutside || closesCycle else { return nil }
        let first: Decimal, second: Decimal, total: Decimal?
        if !hasHomeData || isOutside {
            let completed = request.checkpoint?.reading
            first = completed?.t1 ?? 0; second = completed?.t2 ?? 0; total = completed?.meterTotal
        }
        else if singleMeter {
            guard let value = Numbers.parse(meter) else { return nil }
            first = 0; second = 0; total = value
        } else {
            guard let a = Numbers.parse(t1), let b = Numbers.parse(t2) else { return nil }
            first = a; second = b; total = nil
        }
        guard let average = Numbers.parse(rate), let firstRate = Numbers.parse(rateT1), let secondRate = Numbers.parse(rateT2) else { return nil }
        return Reading(id: recordID, date: date, t1: first, t2: second, averageRate: average,
                       t1Rate: firstRate, t2Rate: secondRate, useTariffRates: pricingWithTariffs,
                       monthBoundary: request.checkpoint?.monthBoundary, closesCycle: closesCycle,
                       isBaseline: isBaseline, tripA: request.checkpoint?.reading.tripA,
                       tripB: closesCycle && !isBaseline ? Numbers.parse(tripB) : request.checkpoint?.reading.tripB,
                       battery: closesCycle ? 100 : request.checkpoint?.battery,
                       hasMeterReading: hasHomeData, meterTotal: total)
    }

    private var outsideCharge: Charge? {
        guard isOutside || (request.kind == .cycle && existingSession != nil),
              let value = Numbers.parse(energy), value > 0, let price = Numbers.parse(cost) else { return nil }
        return Charge(id: existingSession?.id ?? sessionID, date: date, energy: value, cost: price,
                      location: location, stationBrand: StationBrands.canonicalName(brand, choices: brandChoices))
    }

    private var preview: PeriodSummary? {
        guard let candidate = reading, closesCycle, !isBaseline,
              Ledger.validate(candidate, against: checkpoints.map(\.reading)) == nil,
              earlier.allSatisfy({ $0.charge != nil }) else { return nil }
        let readings = checkpoints.map(\.reading).filter { $0.id != candidate.id } + [candidate]
        return Ledger.cycles(readings: readings, charges: effectiveCharges).first { $0.id == candidate.id }
    }

    private func save() {
        guard date <= .now else { error = "Choose a date in the past or present."; return }
        if (isOutside || (request.kind == .cycle && existingSession != nil)) && outsideCharge == nil {
            error = "Enter charging energy and the total price (0 for free)."; return
        }
        if closesCycle && !isBaseline && Numbers.parse(tripB) == nil { error = "Enter Trip B or use the distance calculator."; return }
        if closesCycle && !isBaseline && calculationNeedsReview {
            error = "The previous 100% charge changed. Check Trip B or calculate the distance again."; return
        }
        if closesCycle && !isBaseline && tripBCalculation != nil && calculationPreviousID != previousFull?.id && !preservingSavedCalculation {
            error = "The previous 100% charge changed. Calculate the distance again."; return
        }
        if !isOutside || closesCycle {
            guard let candidate = reading else { error = "Enter the meter counter and valid prices."; return }
            if let message = Ledger.validate(candidate, against: checkpoints.map(\.reading)) { error = message; return }
        }
        for draft in earlier {
            guard draft.charge != nil else { error = "Complete the energy and price for each earlier session."; return }
            guard draft.date <= date, cycleStart.map({ draft.date > $0 }) ?? true else {
                error = "Earlier sessions must be after the previous 100% charge and before this cycle ends."; return
            }
        }
        do {
            if let charge = outsideCharge {
                if let saved = existingSession {
                    saved.date = charge.date; saved.energyText = Numbers.string(charge.energy)
                    saved.costText = Numbers.string(charge.cost)
                    saved.stationBrand = charge.stationBrand; saved.location = charge.location
                    // Old optional partial Trip B readings remain preserved, but are no longer requested.
                } else { context.insert(OutsideCharge(charge: charge)) }
            }
            for draft in earlier {
                if let charge = draft.charge { context.insert(OutsideCharge(charge: charge)) }
            }
            if let candidate = reading {
                let previousHomeData = request.checkpoint?.reading
                let saved: Checkpoint
                if let existing = request.checkpoint { existing.update(with: candidate); saved = existing }
                else { saved = Checkpoint(reading: candidate); context.insert(saved) }
                if closesCycle && !isBaseline {
                    saved.tripBCounterText = tripBCalculation.map { Numbers.string($0.currentCounter) }
                        ?? (tripBCounterKnown ? Numbers.parse(tripB).map(Numbers.string) : nil)
                    saved.tripBPreviousCounterText = tripBCalculation.map { Numbers.string($0.previousCounter) }
                    saved.tripBPreviousCheckpointID = tripBCalculation == nil ? nil : calculationPreviousID
                }
                saved.endedOutside = request.checkpoint?.endedOutside ?? (isOutside || !hasHomeData)
                let sameMeter = previousHomeData.map {
                    $0.hasMeterReading && $0.t1 == candidate.t1 && $0.t2 == candidate.t2 && $0.meterTotal == candidate.meterTotal
                } ?? false
                if !saved.hasMeterReading { saved.homeDataStatus = "pending"; saved.homeDataAddedAt = nil }
                else if !sameMeter || saved.homeDataStatus == nil || saved.homeDataStatus == "pending" {
                    saved.homeDataStatus = "entered"; saved.homeDataAddedAt = .now
                }
                if outsideCharge != nil { saved.linkedChargeID = outsideCharge?.id }
                if let monthly = monthlyRecords.first(where: { $0.id == candidate.id }) { monthly.date = candidate.date }
            }
            try JournalStore.save(context)
            onSaved(request.checkpoint == nil && closesCycle ? "Now reset Trip B in your car. Trip A keeps running." : nil)
            dismiss()
        } catch {
            context.rollback(); self.error = "Couldn’t save your entry. \(error.localizedDescription)"
        }
    }
}
