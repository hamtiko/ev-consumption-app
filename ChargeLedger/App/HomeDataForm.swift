import SwiftUI
import SwiftData
import ChargeLedgerCore

struct HomeDataForm: View {
    let checkpoint: Checkpoint
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @AppStorage("useTariffRates") private var defaultTariffs = false
    @State private var single = true
    @State private var pricingWithTariffs = false
    @State private var total = ""
    @State private var t1 = ""
    @State private var t2 = ""
    @State private var rate = ""
    @State private var rateT1 = ""
    @State private var rateT2 = ""
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var previous: Checkpoint? {
        checkpoints.last { $0.id != checkpoint.id && $0.date < checkpoint.date && $0.hasMeterReading }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("100% charge on \(checkpoint.date.formatted(date: .abbreviated, time: .shortened))")
                    if !checkpoint.hasMeterReading {
                        Label("Partial data", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Add the home counter for this checkpoint. If reading it after returning home, use a reading taken before any further home charging.")
                }
                Section {
                    if single {
                        DecimalField(title: "Meter counter", unit: "kWh", text: $total,
                                     previous: previous.map { Numbers.string($0.reading.total) }).focused($focused)
                    } else {
                        DecimalField(title: "T1 counter", unit: "kWh", text: $t1).focused($focused)
                        DecimalField(title: "T2 counter", unit: "kWh", text: $t2).focused($focused)
                    }
                    DisclosureGroup("Price for this record") {
                        if !pricingWithTariffs {
                            DecimalField(title: "Home price", unit: "AMD/kWh", text: $rate).focused($focused)
                        } else {
                            DecimalField(title: "T1 price", unit: "AMD/kWh", text: $rateT1).focused($focused)
                            DecimalField(title: "T2 price", unit: "AMD/kWh", text: $rateT2).focused($focused)
                        }
                    }
                    Button("Save home data") { save(carryForward: false) }
                } header: { Text("Add home meter reading") }
                if let previous {
                    Section {
                        LabeledContent("Latest known meter", value: "\(LedgerStyle.number(previous.reading.total, digits: 2)) kWh")
                        Text(previous.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Button("No home charging since this reading") { save(carryForward: true) }
                    } footer: {
                        Text("This confirms no home energy was added since the latest known meter reading. Its values will complete this checkpoint and any pending checkpoints since that reading.")
                    }
                } else {
                    Section {
                        Text("No earlier home meter reading is available to carry forward. Enter the counter above.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Complete home data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                single = !defaultTariffs
                pricingWithTariffs = defaultTariffs
                if checkpoint.hasMeterReading { single = checkpoint.meterTotalText != nil }
                if checkpoint.hasMeterReading { pricingWithTariffs = checkpoint.useTariffRates }
                total = checkpoint.meterTotalText ?? ""
                t1 = checkpoint.hasMeterReading ? checkpoint.t1Text : ""
                t2 = checkpoint.hasMeterReading ? checkpoint.t2Text : ""
                rate = checkpoint.averageRateText; rateT1 = checkpoint.t1RateText; rateT2 = checkpoint.t2RateText
            }
            .alert("Check home data", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private func save(carryForward: Bool) {
        let original = checkpoint.reading
        if carryForward {
            guard let completed = Ledger.confirmingNoHomeCharging(through: original, readings: checkpoints.map(\.reading)) else {
                error = "There is no previous home meter reading to use."; return
            }
            persist(completed, status: "unchanged")
            return
        }
        let first: Decimal, second: Decimal, meterTotal: Decimal?
        if single {
            guard let value = Numbers.parse(total) else { error = "Enter the meter counter."; return }
            first = 0; second = 0; meterTotal = value
        } else {
            guard let a = Numbers.parse(t1), let b = Numbers.parse(t2) else { error = "Enter both tariff counters."; return }
            first = a; second = b; meterTotal = nil
        }
        guard let average = Numbers.parse(rate), let priceT1 = Numbers.parse(rateT1), let priceT2 = Numbers.parse(rateT2) else {
            error = "Enter valid prices."; return
        }
        let completed = Reading(id: original.id, date: original.date, t1: first, t2: second,
                                averageRate: average, t1Rate: priceT1, t2Rate: priceT2,
                                useTariffRates: pricingWithTariffs, monthBoundary: original.monthBoundary,
                                closesCycle: original.closesCycle, isBaseline: original.isBaseline,
                                tripA: original.tripA, tripB: original.tripB, battery: original.battery,
                                hasMeterReading: true, meterTotal: meterTotal)
        persist([completed], status: "entered")
    }

    private func persist(_ completed: [Reading], status: String) {
        let ids = Set(completed.map(\.id))
        let updated = checkpoints.map(\.reading).filter { !ids.contains($0.id) } + completed
        for reading in completed {
            if let message = Ledger.validate(reading, against: updated) { error = message; return }
        }
        do {
            for reading in completed {
                if let saved = checkpoints.first(where: { $0.id == reading.id }) {
                    saved.update(with: reading); saved.homeDataStatus = status; saved.homeDataAddedAt = .now
                }
            }
            try context.save(); dismiss()
        } catch {
            context.rollback(); self.error = error.localizedDescription
        }
    }
}
