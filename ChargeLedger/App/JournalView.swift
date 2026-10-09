import SwiftUI
import SwiftData
import ChargeLedgerCore

private enum JournalItem: Identifiable {
    case checkpoint(Checkpoint)
    case charge(OutsideCharge)
    case mileage(MonthlyMileage)
    var id: String {
        switch self {
        case .checkpoint(let item): "reading-\(item.id)"
        case .charge(let item): "charge-\(item.id)"
        case .mileage(let item): "mileage-\(item.id)"
        }
    }
    var date: Date {
        switch self { case .checkpoint(let item): item.date; case .charge(let item): item.date; case .mileage(let item): item.date }
    }
}

struct JournalView: View {
    let edit: (EntryRequest) -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \Checkpoint.date, order: .reverse) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date, order: .reverse) private var charges: [OutsideCharge]
    @Query(sort: \MonthlyMileage.date, order: .reverse) private var mileage: [MonthlyMileage]
    @State private var pendingDelete: JournalItem?
    @State private var error: String?
    private var items: [JournalItem] {
        (checkpoints.map(JournalItem.checkpoint) + charges.map(JournalItem.charge) + mileage.map(JournalItem.mileage))
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Your journal is empty", systemImage: "list.bullet.rectangle",
                                       description: Text("Log an outside charge, a full home charge, or your monthly Trip A mileage."))
            }
            ForEach(items) { item in
                Button { open(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = item }
                    }
                    .swipeActions(edge: .leading) {
                        if case .checkpoint(let checkpoint) = item, checkpoint.closesCycle,
                           checkpoint.endedOutside || checkpoint.linkedChargeID != nil {
                            Button(checkpoint.hasMeterReading ? "Edit home data" : "Add home data") {
                                edit(EntryRequest(kind: .homeData, checkpoint: checkpoint))
                            }
                            .tint(LedgerStyle.accent)
                        }
                    }
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(EntryKind.outside.title, systemImage: EntryKind.outside.icon) { edit(EntryRequest(kind: .outside)) }
                    Button(EntryKind.cycle.title, systemImage: EntryKind.cycle.icon) { edit(EntryRequest(kind: .cycle)) }
                    Button(EntryKind.month.title, systemImage: EntryKind.month.icon) { edit(EntryRequest(kind: .month)) }
                } label: { Image(systemName: "plus") }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete entry", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Reports will be recalculated. Deleting a checkpoint keeps its outside sessions. If you reset Trip B at that checkpoint, later trip distances may need correction.")
        }
        .alert("Couldn’t delete entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func row(_ item: JournalItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item)).foregroundStyle(LedgerStyle.accent).frame(width: 26).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                switch item {
                case .checkpoint(let checkpoint):
                    Text(checkpoint.title).font(.headline)
                    if checkpoint.hasMeterReading {
                        Text(checkpoint.meterTotalText.map { "Meter: \($0) kWh" } ?? "T1 \(checkpoint.t1Text) · T2 \(checkpoint.t2Text) kWh")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label("Partial data · home reading missing", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let distance = checkpoint.tripBText { Text("Trip B: \(distance) km").font(.caption).foregroundStyle(.secondary) }
                    if checkpoint.homeDataStatus == "unchanged" {
                        Text("No home charging · latest meter carried forward").font(.caption).foregroundStyle(.secondary)
                    }
                case .charge(let charge):
                    Text(charge.location.isEmpty ? "Outside charging" : charge.location).font(.headline)
                    Text("\(charge.energyText) kWh · \(charge.costText) AMD").font(.subheadline).foregroundStyle(.secondary)
                case .mileage(let record):
                    Text("Monthly mileage · \(LedgerStyle.month(record.month))").font(.headline)
                    Text("Trip A: \(record.distanceText) km").font(.subheadline).foregroundStyle(.secondary)
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
        case .mileage: return EntryKind.month.icon
        case .checkpoint(let checkpoint): return checkpoint.endedOutside ? EntryKind.outside.icon : checkpoint.isBaseline ? EntryKind.baseline.icon : EntryKind.cycle.icon
        }
    }

    private func open(_ item: JournalItem) {
        switch item {
        case .mileage(let record): edit(EntryRequest(kind: .month, mileage: record))
        case .checkpoint(let checkpoint):
            let kind: EntryKind = checkpoint.isBaseline ? .baseline : !checkpoint.closesCycle ? .legacyMeter
                : checkpoint.endedOutside || checkpoint.linkedChargeID != nil ? .outside : .cycle
            edit(EntryRequest(kind: kind, checkpoint: checkpoint))
        case .charge(let charge):
            if let checkpoint = checkpoints.first(where: { $0.linkedChargeID == charge.id }) { open(.checkpoint(checkpoint)) }
            else { edit(EntryRequest(kind: .outside, charge: charge)) }
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
            case .mileage(let record):
                if let legacy = checkpoints.first(where: { $0.id == record.id }) { legacy.tripAText = nil }
                context.delete(record)
            }
            try context.save(); pendingDelete = nil
        } catch {
            context.rollback(); self.error = error.localizedDescription; pendingDelete = nil
        }
    }
}
