import Foundation
import SwiftData
import ChargeLedgerCore

protocol JournalRecord: PersistentModel {
    var id: UUID { get set }
    var modifiedAt: Date { get set }
    var revision: String { get set }
    var instanceID: String { get set }
}

enum SyncRecords {
    static func unique<T: JournalRecord>(_ records: [T]) -> [T] {
        var winners: [UUID: T] = [:]
        for record in records {
            if let previous = winners[record.id] {
                let newer = RecordRevision.isNewer(date: record.modifiedAt, revision: record.revision,
                                                  than: previous.modifiedAt, revision: previous.revision)
                let tied = record.modifiedAt == previous.modifiedAt && record.revision == previous.revision
                if newer || (tied && record.instanceID > previous.instanceID) { winners[record.id] = record }
            } else { winners[record.id] = record }
        }
        // Preserve each caller's date/month ordering.
        return records.filter { winners[$0.id]?.persistentModelID == $0.persistentModelID }
    }
}

enum JournalSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Checkpoint.self, OutsideCharge.self, MonthlyMileage.self] }
}

enum JournalMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LegacyJournalSchema.self, JournalSchema.self] }
    static var stages: [MigrationStage] {
        [.custom(fromVersion: LegacyJournalSchema.self, toVersion: JournalSchema.self,
                 willMigrate: { context in
            // SwiftData supplies the old schema here, before removing local uniqueness constraints.
            let backup = JournalBackup(
                checkpoints: try context.fetch(FetchDescriptor<LegacyJournalSchema.Checkpoint>()).map(\.backupRecord),
                outsideCharges: try context.fetch(FetchDescriptor<LegacyJournalSchema.OutsideCharge>()).map(\.backupRecord),
                monthlyMileage: try context.fetch(FetchDescriptor<LegacyJournalSchema.MonthlyMileage>()).map(\.backupRecord),
                meterSettings: BackupStore.meterSettings())
            try BackupStore.writeSafetyCopy(backup, named: "before-icloud-upgrade")
        }, didMigrate: nil)]
    }
}

@MainActor
enum JournalStore {
    static var cloudContainerIdentifier: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String
        return value.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
    }

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: JournalSchema.self)
        // Keep the default configuration name and URL used by the original on-device store.
        let container: ModelContainer
        if let identifier = cloudContainerIdentifier {
            // The legacy schema has uniqueness constraints and no CloudKit defaults. Upgrade it
            // locally before attaching mirroring, so the old schema is never opened with CloudKit.
            // Drain/release this temporary container before reopening the same store for sync.
            try autoreleasepool {
                _ = try ModelContainer(for: schema, migrationPlan: JournalMigration.self,
                    configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .none)])
            }
            container = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .private(identifier))])
        } else {
            container = try ModelContainer(for: schema, migrationPlan: JournalMigration.self,
                configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .none)])
        }
        container.mainContext.autosaveEnabled = false
        return container
    }

    static func save(_ context: ModelContext) throws {
        let now = Date.now
        let revision = UUID().uuidString
        for case let record as any JournalRecord in context.insertedModelsArray + context.changedModelsArray {
            record.modifiedAt = now; record.revision = revision
        }
        try context.save()
    }

    static func reconcile(_ context: ModelContext) throws {
        // A restore on two offline devices can create two CloudKit rows with the same logical UUID.
        // Use persisted tie breakers so both devices keep the same row; never deduplicate across types.
        guard !context.hasChanges else { return }
        func prune<T: JournalRecord>(_ type: T.Type) throws {
            let records = try context.fetch(FetchDescriptor<T>())
            let winners = Set(SyncRecords.unique(records).map(\.persistentModelID))
            for record in records where !winners.contains(record.persistentModelID) { context.delete(record) }
        }
        try prune(Checkpoint.self); try prune(OutsideCharge.self); try prune(MonthlyMileage.self)
        if context.hasChanges { try context.save() }
        try LegacyMileageMigration.run(in: context)
    }

    static func delete<T: JournalRecord>(_ record: T, in context: ModelContext) throws {
        let id = record.id
        for matching in try context.fetch(FetchDescriptor<T>()) where matching.id == id { context.delete(matching) }
    }
}
