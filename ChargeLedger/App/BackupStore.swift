import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import ChargeLedgerCore

struct LedgerBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError("Choose a JSON backup file.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum BackupStore {
    static func meterSettings(defaults: UserDefaults = .standard) -> BackupMeterSettings {
        BackupMeterSettings(averageRate: defaults.string(forKey: "averageRate") ?? "47.5",
                            t1Rate: defaults.string(forKey: "t1Rate") ?? "53.48",
                            t2Rate: defaults.string(forKey: "t2Rate") ?? "43.48",
                            useTariffRates: defaults.bool(forKey: "useTariffRates"))
    }

    static func applySettings(_ settings: BackupMeterSettings, defaults: UserDefaults = .standard) {
        defaults.set(settings.averageRate, forKey: "averageRate"); defaults.set(settings.t1Rate, forKey: "t1Rate")
        defaults.set(settings.t2Rate, forKey: "t2Rate"); defaults.set(settings.useTariffRates, forKey: "useTariffRates")
    }

    static var safetyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChargeLedger/Backups", isDirectory: true)
    }

    static var upgradeBackupURL: URL { safetyDirectory.appendingPathComponent("before-icloud-upgrade.json") }

    static func writeSafetyCopy(_ backup: JournalBackup, named name: String) throws {
        try FileManager.default.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
        let url = safetyDirectory.appendingPathComponent(name + ".json")
        // Preserve the original pre-migration copy if a migration needs to be retried.
        if name == "before-icloud-upgrade", FileManager.default.fileExists(atPath: url.path) { return }
        try backup.encoded().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    @MainActor
    static func snapshot(in context: ModelContext) throws -> JournalBackup {
        JournalBackup(
            checkpoints: SyncRecords.unique(try context.fetch(FetchDescriptor<Checkpoint>())).map(\.backupRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            outsideCharges: SyncRecords.unique(try context.fetch(FetchDescriptor<OutsideCharge>())).map(\.backupRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            monthlyMileage: SyncRecords.unique(try context.fetch(FetchDescriptor<MonthlyMileage>())).map(\.backupRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            meterSettings: meterSettings())
    }

    static func read(from url: URL) throws -> JournalBackup {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw BackupError("Choose a Charge Ledger backup under 20 MB.") }
        return try JournalBackup.decode(Data(contentsOf: url))
    }

    @MainActor
    static func restore(_ backup: JournalBackup, in context: ModelContext, restoreSettings: Bool) throws -> BackupMergeResult {
        // Recompute at confirmation time: iCloud may have delivered changes since the preview.
        let current = try snapshot(in: context)
        let result = try backup.merging(into: current)
        try writeSafetyCopy(current, named: "before-last-import")
        do {
            let readings = Dictionary(uniqueKeysWithValues: SyncRecords.unique(try context.fetch(FetchDescriptor<Checkpoint>())).map { ($0.id, $0) })
            let charges = Dictionary(uniqueKeysWithValues: SyncRecords.unique(try context.fetch(FetchDescriptor<OutsideCharge>())).map { ($0.id, $0) })
            let mileage = Dictionary(uniqueKeysWithValues: SyncRecords.unique(try context.fetch(FetchDescriptor<MonthlyMileage>())).map { ($0.id, $0) })
            for record in result.journal.checkpoints {
                if let existing = readings[record.id] {
                    if existing.backupRecord != record { existing.apply(record) }
                } else { context.insert(Checkpoint(backup: record)) }
            }
            for record in result.journal.outsideCharges {
                if let existing = charges[record.id] {
                    if existing.backupRecord != record { existing.apply(record) }
                } else { context.insert(OutsideCharge(backup: record)) }
            }
            for record in result.journal.monthlyMileage {
                if let existing = mileage[record.id] {
                    if existing.backupRecord != record { existing.apply(record) }
                } else { context.insert(MonthlyMileage(backup: record)) }
            }
            // Retain original edit stamps so an older backup cannot replace newer edits on another device.
            try context.save()
        } catch { context.rollback(); throw error }
        if restoreSettings, let settings = backup.meterSettings { applySettings(settings) }
        return result
    }
}

struct BackupImportPreview: Identifiable {
    let id = UUID()
    let backup: JournalBackup
    let result: BackupMergeResult
}

struct BackupImportView: View {
    let preview: BackupImportPreview
    let restore: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var restoreSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Backup") {
                    LabeledContent("Created", value: preview.backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Meter / cycle readings", value: String(preview.backup.checkpoints.count))
                    LabeledContent("Outside sessions", value: String(preview.backup.outsideCharges.count))
                    LabeledContent("Monthly records", value: String(preview.backup.monthlyMileage.count))
                }
                Section {
                    LabeledContent("New entries", value: String(preview.result.added))
                    LabeledContent("Newer edits to restore", value: String(preview.result.updated))
                    LabeledContent("Matching entries kept", value: String(preview.result.kept))
                } header: { Text("Import preview") } footer: {
                    Text("Matching IDs keep the latest edit. Other entries stay in your journal. Imported entries will also sync to iCloud when available.")
                }
                if preview.backup.meterSettings != nil {
                    Section {
                        Toggle("Restore meter defaults and prices", isOn: $restoreSettings)
                    } footer: { Text("Notification preferences stay specific to this device.") }
                }
                Section {
                    Button("Import backup") { restore(restoreSettings) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } footer: { Text("A local copy of the current journal is saved before importing. You can export this copy from Settings.") }
            }
            .navigationTitle("Import backup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
