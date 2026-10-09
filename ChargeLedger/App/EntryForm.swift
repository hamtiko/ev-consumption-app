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
    var charge: Charge? {
        guard let energy = Numbers.parse(energy), energy > 0, let cost = Numbers.parse(cost) else { return nil }
        return Charge(id: id, date: date, energy: energy, cost: cost)
    }
}

private struct ChargingForm: View {
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
    @State private var recordID = UUID()
    @State private var sessionID = UUID()
    @State private var date = Date.now
    @State private var outsideFull = false
    @State private var baselineAt100 = false
    @State private var singleMeter = true
    @State private var pricingWithTariffs = false
    @State private var meter = ""
    @State private var t1 = ""
    @State private var t2 = ""
    @State private var tripB = ""
    @State private var energy = ""
    @State private var cost = ""
    @State private var rate = "47.5"
    @State private var rateT1 = "53.48"
    @State private var rateT2 = "43.48"
    @State private var selectedSessionID: UUID?
    @State private var earlier: [SessionDraft] = []
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var isOutside: Bool { request.kind == .outside }
    private var isBaseline: Bool { request.kind == .baseline }
    private var closesCycle: Bool { isBaseline ? baselineAt100 : request.kind == .cycle || outsideFull }
    private var editing: Bool { request.checkpoint != nil || request.charge != nil }
    private var existingSession: OutsideCharge? {
        let id = selectedSessionID ?? request.checkpoint?.linkedChargeID ?? request.charge?.id
        return charges.first { $0.id == id }
    }
    private var previousFull: Checkpoint? {
        checkpoints.last { $0.closesCycle && $0.date < date && $0.id != request.checkpoint?.id }
    }
    private var previousMeter: Checkpoint? {
        checkpoints.last { $0.hasMeterReading && $0.date < date && $0.id != request.checkpoint?.id }
    }
    private var cycleStart: Date? { previousFull?.date ?? checkpoints.first(where: \.isBaseline)?.date }
    private var loggedSessions: [OutsideCharge] {
        charges.filter { session in
            session.id != existingSession?.id && session.date <= date && (cycleStart.map { $0 < session.date } ?? true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date and time", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                }
                if isOutside {
                    Section {
                        DecimalField(title: "Energy added", unit: "kWh", text: $energy).focused($focused)
                        DecimalField(title: "Total paid", unit: "AMD", text: $cost).focused($focused)
                        Toggle("Charged to 100%", isOn: $outsideFull).disabled(request.checkpoint != nil)
                    } footer: {
                        Text(outsideFull ? "Record Trip B below to finish this cycle." : "Save this session now, or add it later when you next reach 100%. Trip B keeps running.")
                    }
                }
                if closesCycle && !isBaseline {
                    Section {
                        DecimalField(title: "Trip B", unit: "km", text: $tripB).focused($focused)
                    } header: { Text("Kilometres since the last 100% charge") } footer: {
                        Text("Read Trip B before resetting it in your car.")
                    }
                }
                if !isOutside { homeMeterSection }
                if isBaseline {
                    Section {
                        Toggle("Car is at 100% now", isOn: $baselineAt100)
                    } footer: {
                        Text("Starting readings establish the home meter baseline. If the car is at 100%, save and reset Trip B to start a complete cycle.")
                    }
                }
                if closesCycle && !isBaseline { earlierSessionsSection }
                if let summary = preview {
                    Section(summary.homeEnergyKnown ? "Energy since the last home reading" : "This 100% cycle") {
                        LabeledContent("Distance", value: "\(LedgerStyle.number(summary.distance)) km")
                        if summary.homeEnergyKnown {
                            if summary.cycleCount > 1 { LabeledContent("100% cycles covered", value: String(summary.cycleCount)) }
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
                    Button(editing ? "Save changes" : "Save entry", action: save)
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
            }
            .navigationTitle(editing ? "Edit entry" : request.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .onAppear(perform: load)
            .alert("Check your entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private var homeMeterSection: some View {
        Section {
            if singleMeter {
                DecimalField(title: "Meter counter", unit: "kWh", text: $meter,
                             previous: previousMeter.map { Numbers.string($0.reading.total) }).focused($focused)
            } else {
                DecimalField(title: "T1 counter", unit: "kWh", text: $t1,
                             previous: previousMeter?.meterTotalText == nil ? previousMeter?.t1Text : nil).focused($focused)
                DecimalField(title: "T2 counter", unit: "kWh", text: $t2,
                             previous: previousMeter?.meterTotalText == nil ? previousMeter?.t2Text : nil).focused($focused)
            }
            DisclosureGroup("Price for this record") {
                if !pricingWithTariffs {
                    DecimalField(title: "Home price", unit: "AMD/kWh", text: $rate).focused($focused)
                } else {
                    DecimalField(title: "T1 price", unit: "AMD/kWh", text: $rateT1).focused($focused)
                    DecimalField(title: "T2 price", unit: "AMD/kWh", text: $rateT2).focused($focused)
                }
                Button("Use default prices") { rate = defaultRate; rateT1 = defaultT1; rateT2 = defaultT2 }
            }
        } header: { Text("Home meter") } footer: {
            Text("Enter the cumulative counter from your dedicated charger meter. The meter format and prices come from Settings; each record keeps its own price.")
        }
    }

    private var earlierSessionsSection: some View {
        Section {
            ForEach(loggedSessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(session.energyText) kWh · \(session.costText) AMD")
                    Text("Already saved · \(session.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isOutside && existingSession == nil && !loggedSessions.isEmpty {
                Menu("Use a saved session as this 100% charge") {
                    ForEach(loggedSessions) { session in
                        Button("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.energyText) kWh") {
                            selectedSessionID = session.id; date = session.date
                            energy = session.energyText; cost = session.costText
                        }
                    }
                }
            }
            ForEach($earlier) { $session in
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Session date", selection: $session.date,
                               in: min(cycleStart ?? .distantPast, date)...date, displayedComponents: [.date, .hourAndMinute])
                    DecimalField(title: "Energy added", unit: "kWh", text: $session.energy).focused($focused)
                    DecimalField(title: "Total paid", unit: "AMD", text: $session.cost).focused($focused)
                    Button("Remove session", role: .destructive) { earlier.removeAll { $0.id == session.id } }
                        // Prevent Form's automatic button style from making the entire session row tappable.
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 5)
            }
            Button {
                let start = cycleStart ?? date.addingTimeInterval(-3600)
                earlier.append(SessionDraft(date: Date(timeIntervalSince1970: (start.timeIntervalSince1970 + date.timeIntervalSince1970) / 2)))
            } label: { Label("Add earlier outside session", systemImage: "plus") }
        } header: { Text("Outside sessions in this cycle") } footer: {
            Text("Add any partial outside charges you haven’t logged yet. Already saved sessions are included automatically. Home partial charges need no entry.")
        }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        singleMeter = !defaultTariffs; pricingWithTariffs = defaultTariffs
        rate = defaultRate; rateT1 = defaultT1; rateT2 = defaultT2
        if let saved = request.checkpoint {
            recordID = saved.id; date = saved.date; tripB = saved.tripBText ?? ""
            outsideFull = isOutside && saved.closesCycle; baselineAt100 = saved.closesCycle
            singleMeter = saved.meterTotalText != nil; meter = saved.meterTotalText ?? ""
            pricingWithTariffs = saved.useTariffRates
            t1 = saved.t1Text; t2 = saved.t2Text
            rate = saved.averageRateText; rateT1 = saved.t1RateText; rateT2 = saved.t2RateText
        }
        if let saved = existingSession {
            sessionID = saved.id; energy = saved.energyText; cost = saved.costText
            if request.checkpoint == nil { date = saved.date }
        }
    }

    private var reading: Reading? {
        guard !isOutside || closesCycle else { return nil }
        let first: Decimal, second: Decimal, total: Decimal?
        if isOutside {
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
                       hasMeterReading: !isOutside || (request.checkpoint?.hasMeterReading ?? false), meterTotal: total)
    }

    private var outsideCharge: Charge? {
        guard isOutside, let value = Numbers.parse(energy), value > 0, let price = Numbers.parse(cost) else { return nil }
        return Charge(id: existingSession?.id ?? sessionID, date: date, energy: value, cost: price,
                      location: existingSession?.location ?? "")
    }

    private var preview: PeriodSummary? {
        guard let candidate = reading, closesCycle, !isBaseline,
              Ledger.validate(candidate, against: checkpoints.map(\.reading)) == nil,
              earlier.allSatisfy({ $0.charge != nil }) else { return nil }
        let readings = checkpoints.map(\.reading).filter { $0.id != candidate.id } + [candidate]
        var outside = charges.map(\.charge).filter { $0.id != outsideCharge?.id }
        if let charge = outsideCharge { outside.append(charge) }
        outside += earlier.compactMap(\.charge)
        return (candidate.hasMeterReading ? Ledger.measurements(readings: readings, charges: outside)
                : Ledger.cycles(readings: readings, charges: outside)).first { $0.id == candidate.id }
    }

    private func save() {
        guard date <= .now else { error = "Choose a date in the past or present."; return }
        if isOutside && outsideCharge == nil { error = "Enter charging energy and the total price (0 for free)."; return }
        if closesCycle && !isBaseline && Numbers.parse(tripB) == nil { error = "Enter the kilometres shown on Trip B."; return }
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
                    // Old optional partial Trip B readings remain preserved, but are no longer requested.
                } else { context.insert(OutsideCharge(charge: charge)) }
            }
            for draft in earlier {
                if let charge = draft.charge { context.insert(OutsideCharge(charge: charge)) }
            }
            if let candidate = reading {
                let saved: Checkpoint
                if let existing = request.checkpoint { existing.update(with: candidate); saved = existing }
                else { saved = Checkpoint(reading: candidate); context.insert(saved) }
                saved.endedOutside = isOutside
                if isOutside && !saved.hasMeterReading { saved.homeDataStatus = "pending" }
                if isOutside { saved.linkedChargeID = outsideCharge?.id }
            }
            try context.save()
            onSaved(request.checkpoint == nil && closesCycle ? "Now reset Trip B in your car. Trip A keeps running." : nil)
            dismiss()
        } catch {
            context.rollback(); self.error = "Couldn’t save your entry. \(error.localizedDescription)"
        }
    }
}
