import SwiftUI
import SwiftData
import ChargeLedgerCore

struct MileageForm: View {
    let request: EntryRequest
    let onSaved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var records: [MonthlyMileage]
    @State private var date = Date.now
    @State private var month = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @State private var distance = ""
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Reading date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    DatePicker("Month completed", selection: $month, displayedComponents: .date)
                    DecimalField(title: "Trip A", unit: "km", text: $distance).focused($focused)
                } footer: {
                    Text("Enter the kilometres shown on Trip A, then reset Trip A in your car. Trip B keeps running.")
                }
                Section {
                    Button(request.mileage == nil ? "Save monthly mileage" : "Save changes", action: save)
                        .font(.headline).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Monthly mileage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                if let saved = request.mileage {
                    date = saved.date; month = saved.month; distance = saved.distanceText
                }
            }
            .alert("Check your mileage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        guard let kilometres = Numbers.parse(distance) else { error = "Enter the Trip A kilometres."; return }
        let selectedMonth = MonthIdentity.from(month)
        let parts = Ledger.monthCalendar.dateComponents([.year, .month], from: selectedMonth)
        let start = Calendar.current.date(from: parts)!
        guard let next = Calendar.current.date(byAdding: .month, value: 1, to: start), date >= next else {
            error = "Select a completed month and its actual reset date."; return
        }
        guard date <= .now else { error = "Choose a reading date in the past or present."; return }
        guard !records.contains(where: { $0.id != request.mileage?.id && $0.month == selectedMonth }) else {
            error = "Mileage for this month already exists. Edit it in the journal."; return
        }
        do {
            if let saved = request.mileage {
                if saved.month != selectedMonth,
                   let legacy = try context.fetch(FetchDescriptor<Checkpoint>()).first(where: { $0.id == saved.id }) {
                    legacy.tripAText = nil
                }
                saved.date = date; saved.month = selectedMonth; saved.distanceText = Numbers.string(kilometres)
            } else {
                context.insert(MonthlyMileage(record: MileageRecord(date: date, month: selectedMonth, distance: kilometres)))
            }
            try context.save()
            onSaved(request.mileage == nil ? "Now reset Trip A in your car. Trip B keeps running." : nil)
            dismiss()
        } catch {
            context.rollback(); self.error = error.localizedDescription
        }
    }
}

enum MonthIdentity {
    static func from(_ date: Date) -> Date {
        var parts = Calendar.current.dateComponents([.year, .month], from: date)
        parts.hour = 12
        return Ledger.monthCalendar.date(from: parts)!
    }
}
