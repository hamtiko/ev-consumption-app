import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var reminders: ReminderService
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @State private var entry: EntryRequest?
    @State private var resetMessage: String?
    @State private var showReset = false
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("reminderHour") private var reminderHour = 9
    @AppStorage("reminderMinute") private var reminderMinute = 0

    var body: some View {
        TabView {
            NavigationStack {
                OverviewView { entry = EntryRequest(kind: $0) }
            }
            .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
            NavigationStack {
                JournalView { entry = $0 }
            }
            .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
            NavigationStack { ReportsView() }
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
        .alert("Checkpoint saved", isPresented: $showReset) {
            Button("Done") { resetMessage = nil; openRequestedMonth() }
        } message: { Text(resetMessage ?? "") }
        .onAppear { openRequestedMonth() }
        .onChange(of: reminders.monthRequested) { _, _ in openRequestedMonth() }
        .task {
            if reminderEnabled {
                // Refresh time-zone behavior on launch; permission is requested only in Settings.
                try? await reminders.schedule(hour: reminderHour, minute: reminderMinute, requestPermission: false)
            }
        }
    }

    private func openRequestedMonth() {
        guard reminders.monthRequested, entry == nil, !showReset else { return }
        reminders.monthRequested = false
        entry = EntryRequest(kind: checkpoints.isEmpty ? .baseline : .month)
    }
}
