import SwiftUI
import SwiftData
import ChargeLedgerCore

struct OverviewView: View {
    let add: (EntryKind) -> Void
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    private var readings: [Reading] { checkpoints.map(\.reading) }
    private var external: [Charge] { charges.map(\.charge) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if checkpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "bolt.car.fill").font(.largeTitle).foregroundStyle(LedgerStyle.accent)
                        Text("Your car, in numbers.").font(.title2.bold())
                        Text("A few readings. A clearer picture of your charging energy and costs.")
                            .foregroundStyle(.secondary)
                        Button { add(.baseline) } label: {
                            Label("Set starting readings", systemImage: "plus")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(22).background(.background, in: RoundedRectangle(cornerRadius: 22))
                } else {
                    VStack(spacing: 10) {
                        action(.month, detail: "Trip A · monthly meter readings")
                        action(.cycle, detail: "Trip B · full-charge cycle")
                        action(.outside, detail: "Energy and actual price · partial or full")
                    }
                    currentMonthCard
                    let month = Ledger.months(readings: readings, charges: external).last
                    SummaryCard(title: "Latest completed month",
                                subtitle: month?.month.map(LedgerStyle.month) ?? "Trip A",
                                summary: month,
                                emptyMessage: "Record consecutive monthly checkpoints to see distance, consumption, and cost here.")
                    let cycle = Ledger.cycles(readings: readings, charges: external).last
                    SummaryCard(title: "Last 100% cycle",
                                subtitle: cycle.map { "\($0.start.formatted(date: .abbreviated, time: .omitted)) – \($0.end.formatted(date: .abbreviated, time: .omitted))" } ?? "Trip B",
                                summary: cycle,
                                emptyMessage: "Two full-charge checkpoints establish a complete driving cycle. Monthly readings keep Trip B running.")
                    Text("Home costs use your saved prices. Charging energy includes losses; it measures electricity supplied, rather than the car’s dashboard consumption.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(LedgerStyle.background)
        .navigationTitle("Charge Ledger")
    }

    private func action(_ kind: EntryKind, detail: String) -> some View {
        Button { add(kind) } label: {
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

    private var currentMonthCard: some View {
        let month = Calendar.current.dateInterval(of: .month, for: .now)!
        let current = external.filter { $0.date >= month.start && $0.date < month.end }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("This month").font(.headline)
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.abbreviated).year())).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Metric(title: "Outside charging logged", value: LedgerStyle.number(current.reduce(0) { $0 + $1.energy }), unit: "kWh")
                Metric(title: "Outside cost", value: LedgerStyle.number(current.reduce(0) { $0 + $1.cost }), unit: "AMD")
            }
            Text("Monthly distance and total consumption arrive when you record Trip A and the next month’s meter readings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}
