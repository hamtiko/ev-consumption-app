import SwiftUI
import SwiftData
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Install the notification delegate before launch finishes, including a cold notification tap.
        _ = ReminderService.shared
        application.registerForRemoteNotifications()
        return true
    }
}

@main
@MainActor
struct ChargeLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var reminders = ReminderService.shared
    @StateObject private var cloudSync = CloudSyncService()
    private let storage: Result<ModelContainer, Error>

    init() {
        storage = Result { try JournalStore.makeContainer() }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let container):
                RootView()
                    .environmentObject(reminders)
                    .environmentObject(cloudSync)
                    .modelContainer(container)
                    .tint(LedgerStyle.accent)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Couldn’t open your journal", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your stored data has not been replaced. Restart the app and try again.\n\(error.localizedDescription)")
                } actions: {
                    if FileManager.default.fileExists(atPath: BackupStore.upgradeBackupURL.path) {
                        ShareLink("Export pre-upgrade safety copy", item: BackupStore.upgradeBackupURL)
                    }
                }
            }
        }
    }
}
