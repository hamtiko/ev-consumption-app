import SwiftUI
import SwiftData
import CloudKit
import CoreData

@MainActor
final class CloudSyncService: ObservableObject {
    @Published private(set) var accountMessage = "Checking iCloud…"
    @Published private(set) var accountAvailable = false
    @Published private(set) var activity: String?
    @Published private(set) var lastTransfer: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var journalError: String?
    private var activeEvents: [UUID: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var reconciliation: Task<Void, Never>?
    private var context: ModelContext?
    private var entryPresented = false

    var status: String { activity ?? (syncError == nil ? accountMessage : "iCloud needs attention") }

    func start(context: ModelContext) async {
        self.context = context
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                object: nil, queue: .main) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { return }
                Task { @MainActor [weak self] in self?.receive(event) }
            })
            for name in [Notification.Name.NSPersistentStoreRemoteChange, ModelContext.didSave] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.reconcileSoon() }
                })
            }
            observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAccount() }
            })
        }
        reconcileSoon()
        await refreshAccount()
    }

    func refreshAccount() async {
        guard let identifier = JournalStore.cloudContainerIdentifier else {
            accountAvailable = false; accountMessage = "On-device storage"
            return
        }
        do {
            let status = try await CKContainer(identifier: identifier).accountStatus()
            accountAvailable = status == .available
            switch status {
            case .available: accountMessage = "iCloud available"
            case .noAccount: accountMessage = "Sign in to iCloud in device Settings"
            case .restricted: accountMessage = "iCloud access is restricted"
            case .temporarilyUnavailable: accountMessage = "iCloud temporarily unavailable"
            case .couldNotDetermine: accountMessage = "Couldn’t check iCloud"
            @unknown default: accountMessage = "Couldn’t check iCloud"
            }
        } catch {
            accountAvailable = false; accountMessage = "Couldn’t check iCloud"
            syncError = error.localizedDescription
        }
    }

    private func receive(_ event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            switch event.type {
            case .setup: activeEvents[event.identifier] = "Preparing iCloud…"
            case .import: activeEvents[event.identifier] = "Receiving from iCloud…"
            case .export: activeEvents[event.identifier] = "Sending to iCloud…"
            @unknown default: activeEvents[event.identifier] = "Syncing with iCloud…"
            }
        } else {
            activeEvents.removeValue(forKey: event.identifier)
            if let error = event.error { syncError = error.localizedDescription }
            else if event.succeeded {
                syncError = nil
                if event.type == .import || event.type == .export { lastTransfer = event.endDate }
                reconcileSoon()
            }
        }
        activity = activeEvents.values.sorted().first
    }

    func reconcileSoon() {
        reconciliation?.cancel()
        reconciliation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.entryPresented, let context = self.context else { return }
            do { try JournalStore.reconcile(context); journalError = nil }
            catch { context.rollback(); journalError = error.localizedDescription }
        }
    }

    func setEntryPresented(_ presented: Bool) {
        entryPresented = presented
        if presented { reconciliation?.cancel() }
        else { reconcileSoon() }
    }
}
