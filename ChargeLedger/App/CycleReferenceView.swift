import SwiftUI
import ChargeLedgerCore

struct CycleOutsideSessionRow: View {
    let session: Charge
    var status: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.stationBrand ?? (session.location.isEmpty ? "Outside charging" : session.location))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Text(session.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            Text("\(LedgerStyle.number(session.energy, digits: 2)) kWh · \(LedgerStyle.number(session.cost, digits: 2)) AMD")
                .font(.subheadline).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Read-only reference keeps the new entry open while reviewing the preceding cycle.
struct CycleReferenceView: View {
    let summary: PeriodSummary
    let sessions: [Charge]
    let counterText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Previous cycle") {
                    LabeledContent("Started", value: summary.start.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last 100%", value: summary.end.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Cycle distance", value: "\(LedgerStyle.number(summary.distance, digits: 2)) km")
                    LabeledContent("Car Trip B at that charge", value: counterText.map { "\($0) km" } ?? "Not recorded")
                }
                Section("Energy and cost") {
                    if summary.homeEnergyKnown {
                        LabeledContent("Energy supplied", value: "\(LedgerStyle.number(summary.totalEnergy, digits: 2)) kWh")
                        LabeledContent("Consumption", value: "\(LedgerStyle.number(summary.energyPer100KM, digits: 2)) kWh/100 km")
                        LabeledContent("Estimated total cost", value: "\(LedgerStyle.number(summary.estimatedTotalCost, digits: 2)) AMD")
                        LabeledContent("Estimated cost per km", value: "\(LedgerStyle.number(summary.costPerKM, digits: 2)) AMD/km")
                    } else {
                        Label("Home data pending", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                        LabeledContent("Outside energy logged", value: "\(LedgerStyle.number(summary.outsideEnergy, digits: 2)) kWh")
                        LabeledContent("Outside paid", value: "\(LedgerStyle.number(summary.outsideCost, digits: 2)) AMD")
                    }
                }
                Section("Outside sessions in the previous cycle") {
                    if sessions.isEmpty { Text("No outside sessions recorded.").foregroundStyle(.secondary) }
                    ForEach(sessions) { session in CycleOutsideSessionRow(session: session, status: "Saved") }
                }
            }
            .navigationTitle("Previous cycle").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
