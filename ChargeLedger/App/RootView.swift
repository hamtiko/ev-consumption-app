import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.modelContext) private var context
    @State private var entry: EntryRequest?
    @State private var resetMessage: String?
    @State private var showReset = false
    @State private var storageError: String?
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("reminderHour") private var reminderHour = 9
    @AppStorage("reminderMinute") private var reminderMinute = 0

    var body: some View {
        TabView {
            NavigationStack {
                OverviewView { entry = $0 }
            }
            .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
            NavigationStack {
                JournalView { entry = $0 }
            }
            .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
            NavigationStack { ReportsView { entry = $0 } }
                .tabItem { Label("Reports", systemImage: "chart.xyaxis.line") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(item: $entry, onDismiss: {
            if resetMessage != nil { showReset = true }
            else { openRequestedMonth() }
        }) { request in
            EntryForm(request: request) { message in resetMessage = message }
        }
        .alert(storageError == nil ? "Saved" : "Couldn’t update the journal",
               isPresented: Binding(get: { showReset || storageError != nil }, set: { shown in
            if !shown { showReset = false; storageError = nil }
        })) {
            Button(storageError == nil ? "Done" : "OK") {
                resetMessage = nil; storageError = nil; showReset = false; openRequestedMonth()
            }
        } message: { Text(storageError ?? resetMessage ?? "") }
        .onAppear { openRequestedMonth() }
        .onChange(of: reminders.monthRequested) { _, _ in openRequestedMonth() }
        .task {
            do { try LegacyMileageMigration.run(in: context) }
            catch { context.rollback(); storageError = error.localizedDescription }
            if reminderEnabled {
                // Refresh time-zone behavior on launch; permission is requested only in Settings.
                try? await reminders.schedule(hour: reminderHour, minute: reminderMinute, requestPermission: false)
            }
        }
    }

    private func openRequestedMonth() {
        guard reminders.monthRequested, entry == nil, !showReset, storageError == nil else { return }
        reminders.monthRequested = false
        entry = EntryRequest(kind: .month)
    }
}
