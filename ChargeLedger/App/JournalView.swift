import SwiftUI
import SwiftData
import ChargeLedgerCore

private enum JournalItem: Identifiable {
    case checkpoint(Checkpoint)
    case charge(OutsideCharge)
    var id: UUID {
        switch self { case .checkpoint(let item): item.id; case .charge(let item): item.id }
    }
    var date: Date {
        switch self { case .checkpoint(let item): item.date; case .charge(let item): item.date }
    }
}

struct JournalView: View {
    let edit: (EntryRequest) -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \Checkpoint.date, order: .reverse) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date, order: .reverse) private var charges: [OutsideCharge]
    @State private var pendingDelete: JournalItem?
    @State private var error: String?
    private var items: [JournalItem] {
        (checkpoints.map(JournalItem.checkpoint) + charges.map(JournalItem.charge))
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Your journal is empty", systemImage: "list.bullet.rectangle",
                                       description: Text("Set starting readings from Overview, then add checkpoints and outside charging."))
            }
            ForEach(items) { item in
                Button { open(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = item }
                    }
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Start new month", systemImage: EntryKind.month.icon) { edit(EntryRequest(kind: .month)) }
                    Button("Reached 100%", systemImage: EntryKind.cycle.icon) { edit(EntryRequest(kind: .cycle)) }
                    Button("Outside charging", systemImage: EntryKind.outside.icon) { edit(EntryRequest(kind: .outside)) }
                } label: { Image(systemName: "plus") }
                .disabled(checkpoints.isEmpty)
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete entry", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Reports will be recalculated. Deleting a checkpoint keeps its outside charging session.")
        }
        .alert("Couldn’t delete entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func row(_ item: JournalItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item)).foregroundStyle(LedgerStyle.accent)
                .frame(width: 26).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                switch item {
                case .checkpoint(let checkpoint):
                    Text(checkpoint.title).font(.headline)
                    Text("T1 \(checkpoint.t1Text) · T2 \(checkpoint.t2Text) kWh").font(.subheadline).foregroundStyle(.secondary)
                    if let a = checkpoint.tripAText { Text("Trip A: \(a) km").font(.caption).foregroundStyle(.secondary) }
                    if let b = checkpoint.tripBText { Text("Trip B: \(b) km").font(.caption).foregroundStyle(.secondary) }
                    if let boundary = checkpoint.monthBoundary, !checkpoint.isBaseline,
                       let month = Ledger.monthCalendar.date(byAdding: .month, value: -1, to: boundary) {
                        Text("Closes \(LedgerStyle.month(month))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(checkpoint.useTariffRates ? "T1 \(checkpoint.t1RateText) · T2 \(checkpoint.t2RateText) AMD/kWh" : "Home price: \(checkpoint.averageRateText) AMD/kWh")
                        .font(.caption).foregroundStyle(.secondary)
                case .charge(let charge):
                    Text(charge.location.isEmpty ? "Outside charging" : charge.location).font(.headline)
                    Text("\(charge.energyText) kWh · \(charge.costText) AMD").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func icon(_ item: JournalItem) -> String {
        switch item {
        case .charge: return EntryKind.outside.icon
        case .checkpoint(let checkpoint):
            return checkpoint.isBaseline ? EntryKind.baseline.icon : checkpoint.monthBoundary != nil ? EntryKind.month.icon : EntryKind.cycle.icon
        }
    }

    private func open(_ item: JournalItem) {
        switch item {
        case .checkpoint(let checkpoint):
            edit(EntryRequest(kind: checkpoint.isBaseline ? .baseline : checkpoint.monthBoundary != nil ? .month : .cycle, checkpoint: checkpoint))
        case .charge(let charge):
            if let checkpoint = checkpoints.first(where: { $0.linkedChargeID == charge.id }) {
                open(.checkpoint(checkpoint))
            } else { edit(EntryRequest(kind: .outside, charge: charge)) }
        }
    }

    private func delete() {
        guard let item = pendingDelete else { return }
        do {
            switch item {
            case .checkpoint(let checkpoint): context.delete(checkpoint)
            case .charge(let charge):
                for checkpoint in checkpoints where checkpoint.linkedChargeID == charge.id { checkpoint.linkedChargeID = nil }
                context.delete(charge)
            }
            try context.save(); pendingDelete = nil
        } catch {
            context.rollback(); self.error = error.localizedDescription; pendingDelete = nil
        }
    }
}
