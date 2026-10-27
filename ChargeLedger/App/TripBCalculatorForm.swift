import SwiftUI
import ChargeLedgerCore

struct TripBCalculatorRequest: Identifiable {
    let id = UUID()
    let previousID: UUID
    let previousDate: Date
    let previousCycleDistance: Decimal?
    let currentText: String
    let previousText: String
}

struct TripBCalculatorForm: View {
    let previousDate: Date
    let previousCycleDistance: Decimal?
    let onUse: (TripBCalculation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: String
    @State private var previous: String
    @FocusState private var focused: InputField?

    init(previousDate: Date, previousCycleDistance: Decimal?, currentText: String,
         previousText: String, onUse: @escaping (TripBCalculation) -> Void) {
        self.previousDate = previousDate; self.previousCycleDistance = previousCycleDistance
        self.onUse = onUse
        _current = State(initialValue: currentText); _previous = State(initialValue: previousText)
    }

    private var result: Result<TripBCalculation, Error> {
        Result { try TripBCalculation(currentText: current, previousText: previous) }
    }

    var body: some View {
        NavigationStack {
            KeyboardForm(focus: $focused) {
                Section {
                    Text("Use this if Trip B has kept running since the last 100% charge.")
                    LabeledContent("Last 100%", value: previousDate.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    DecimalField(title: "Trip B now", unit: "km", text: $current,
                                 focus: $focused, field: .tripBCounter)
                    DecimalField(title: "Trip B at last 100%", unit: "km", text: $previous,
                                 focus: $focused, field: .tripBPreviousCounter)
                } footer: {
                    Text("Use the actual car counter at that charge. If it wasn’t recorded, enter it yourself. A calculated cycle distance can be different.")
                }
                if let distance = previousCycleDistance {
                    Section {
                        LabeledContent("Last cycle distance", value: "\(LedgerStyle.number(distance, digits: 2)) km")
                    } footer: { Text("For reference when checking the previous counter.") }
                }
                switch result {
                case .success(let calculation):
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Distance for this cycle").font(.caption).foregroundStyle(.secondary)
                            Text("\(LedgerStyle.number(calculation.distance, digits: 2)) km")
                                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                            Text("\(Numbers.string(calculation.currentCounter)) − \(Numbers.string(calculation.previousCounter))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button {
                            focused = nil; onUse(calculation); dismiss()
                        } label: {
                            Text("Use \(LedgerStyle.number(calculation.distance, digits: 2)) km")
                                .font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } footer: {
                        Text("Returns the distance to the cycle form. Reset Trip B in your car after saving the cycle.")
                    }
                case .failure(let error):
                    Section {
                        Text(error.localizedDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Calculate distance").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
