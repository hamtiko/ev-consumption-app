import SwiftUI
import SwiftData
import ChargeLedgerCore

struct OverviewView: View {
    let add: (EntryRequest) -> Void
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @Query(sort: \MonthlyMileage.month) private var mileage: [MonthlyMileage]
    private var readings: [Reading] { checkpoints.map(\.reading) }
    private var external: [Charge] { charges.map(\.charge) }
    private var pending: [Checkpoint] { Array(checkpoints.filter { $0.closesCycle && !$0.hasMeterReading }.reversed()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    action(.cycle, detail: "Trip B, home meter and outside sessions")
                    action(.month, detail: "Home meter · optional Trip A on the 1st")
                }
                if checkpoints.first(where: \.hasMeterReading) == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Start tracking home energy").font(.headline)
                        Text("Set a starting meter reading, or start with your next 100% cycle or monthly reading.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Set starting meter") { add(EntryRequest(kind: .baseline)) }
                    }
                    .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                if !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Home data to complete", systemImage: "exclamationmark.circle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        ForEach(pending) { checkpoint in
                            Button {
                                add(EntryRequest(kind: .homeData, checkpoint: checkpoint))
                            } label: {
                                HStack {
                                    Text(checkpoint.date.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text("Add home data").font(.subheadline.weight(.medium))
                                }
                            }
                        }
                    }
                    .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                let cycle = Ledger.cycles(readings: readings, charges: external).last
                SummaryCard(title: "Last 100% cycle", subtitle: "Trip B", summary: cycle,
                            emptyMessage: "The first 100% record starts a cycle. The next one closes it.")
                let measurement = Ledger.measurements(readings: readings, charges: external).last
                SummaryCard(title: "Latest complete energy report",
                            subtitle: measurement.map { "\($0.cycleCount) cycle\($0.cycleCount == 1 ? "" : "s") between home readings" } ?? "Home and outside energy",
                            summary: measurement,
                            emptyMessage: "Complete home readings let you compare all energy supplied with the distance driven.")
                let month = Ledger.months(readings: readings, charges: external, mileage: mileage.map(\.record)).last
                if let month {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(LedgerStyle.month(month.month!)).font(.headline)
                        HStack {
                            Metric(title: "Home energy", value: LedgerStyle.number(month.homeEnergyKnown ? month.homeEnergy : nil), unit: "kWh")
                            Metric(title: "Utility bill contribution", value: LedgerStyle.number(month.homeEnergyKnown ? month.estimatedHomeCost : nil), unit: "AMD")
                        }
                        if month.distanceKnown {
                            Text("Trip A: \(LedgerStyle.number(month.distance)) km").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(month.homeEnergyKnown ? "Home cost uses saved prices and the interval between monthly meter readings. Outside charging is separate."
                             : "Add two consecutive monthly meter readings to measure the home charging cost.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                Text("Partial home charges need no entry. Add outside sessions when you log a 100% cycle. Monthly meter readings measure the car’s contribution to your utility bill.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(LedgerStyle.background)
        .navigationTitle("Charge Ledger")
    }

    private func action(_ kind: EntryKind, detail: String) -> some View {
        Button { add(EntryRequest(kind: kind)) } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.icon).font(.title3)
                    .frame(width: 42, height: 42)
                    .background(LedgerStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus").font(.headline)
            }
            .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}
