import Foundation

public struct JournalBackup: Codable, Equatable, Sendable {
    public var format = "charge-ledger-backup"
    public var version = 2
    public var createdAt: Date
    public var checkpoints: [BackupCheckpoint]
    public var outsideCharges: [BackupOutsideCharge]
    public var monthlyMileage: [BackupMonthlyMileage]
    public var meterSettings: BackupMeterSettings?

    public init(createdAt: Date = .now, checkpoints: [BackupCheckpoint] = [],
                outsideCharges: [BackupOutsideCharge] = [], monthlyMileage: [BackupMonthlyMileage] = [],
                meterSettings: BackupMeterSettings? = nil) {
        self.createdAt = createdAt; self.checkpoints = checkpoints
        self.outsideCharges = outsideCharges; self.monthlyMileage = monthlyMileage
        self.meterSettings = meterSettings
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 20 * 1024 * 1024 else {
            throw BackupError("This backup is too large. Choose a Charge Ledger JSON backup under 20 MB.")
        }
        // Check the envelope before decoding a future version's different record layout.
        struct Header: Decodable { let format: String; let version: Int }
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.format == "charge-ledger-backup" else { throw BackupError("This is not a Charge Ledger backup.") }
            guard (1...2).contains(header.version) else { throw BackupError("This backup needs a different app version. Update Charge Ledger and try again.") }
            let backup = try decoder.decode(Self.self, from: data)
            try backup.validate()
            return backup
        } catch let error as BackupError { throw error }
        catch { throw BackupError("The backup is incomplete or damaged. No entries were imported.") }
    }

    public func validate() throws {
        guard format == "charge-ledger-backup", (1...2).contains(version) else { throw BackupError("Unsupported backup format.") }
        func number(_ text: String?, required: Bool = false) throws {
            guard let text else {
                if required { throw BackupError("A required numeric value is missing.") }
                return
            }
            guard Numbers.parse(text) != nil else { throw BackupError("The backup contains an invalid numeric value.") }
        }
        func date(_ value: Date?) throws {
            if let value, !value.timeIntervalSinceReferenceDate.isFinite { throw BackupError("The backup contains an invalid date.") }
        }
        func unique(_ ids: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw BackupError("The backup contains duplicate entries.") }
        }
        func month(_ value: Date) throws {
            let parts = Ledger.monthCalendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: value)
            guard parts.day == 1, parts.hour == 12, parts.minute == 0, parts.second == 0, parts.nanosecond == 0 else {
                throw BackupError("The backup contains an invalid completed month.")
            }
        }
        try date(createdAt)
        // A monthly record deliberately shares its UUID with its meter checkpoint.
        try unique(checkpoints.map(\.id)); try unique(outsideCharges.map(\.id)); try unique(monthlyMileage.map(\.id))
        for record in checkpoints {
            for value in [record.t1Text, record.t2Text, record.averageRateText, record.t1RateText, record.t2RateText] {
                try number(value, required: true)
            }
            for value in [record.tripAText, record.tripBText, record.meterTotalText,
                          record.tripBCounterText, record.tripBPreviousCounterText] { try number(value) }
            if let previous = record.tripBPreviousCounterText {
                guard let current = record.tripBCounterText, let previousID = record.tripBPreviousCheckpointID,
                      previousID != record.id,
                      let calculation = try? TripBCalculation(currentText: current, previousText: previous),
                      calculation.distance == record.tripBText.flatMap(Numbers.parse) else {
                    throw BackupError("The backup contains an inconsistent Trip B calculation.")
                }
            } else if record.tripBPreviousCheckpointID != nil {
                throw BackupError("The backup is missing a previous Trip B counter.")
            } else if let counter = record.tripBCounterText, record.closesCycle, !record.isBaseline,
                      Numbers.parse(counter) != record.tripBText.flatMap(Numbers.parse) {
                throw BackupError("The backup contains an inconsistent Trip B counter.")
            }
            for value in [record.date, record.recordedAt, record.monthBoundary, record.homeDataAddedAt, record.modifiedAt] { try date(value) }
            if let boundary = record.monthBoundary { try month(boundary) }
            guard record.battery.map({ (0...100).contains($0) }) ?? true,
                  record.homeDataStatus.map({ ["pending", "entered", "unchanged"].contains($0) }) ?? true else {
                throw BackupError("The backup contains an invalid checkpoint status.")
            }
        }
        for record in outsideCharges {
            try number(record.energyText, required: true); try number(record.costText, required: true)
            try number(record.tripBText); try date(record.date); try date(record.modifiedAt)
        }
        for record in monthlyMileage {
            if !record.distanceText.isEmpty { try number(record.distanceText) }
            try date(record.date); try date(record.month); try date(record.modifiedAt)
            try month(record.month)
        }
        if let settings = meterSettings {
            try number(settings.averageRate); try number(settings.t1Rate); try number(settings.t2Rate)
        }
    }
}

public struct BackupError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum RecordRevision {
    /// Stable ordering resolves simultaneous edits and repeated imports the same way on every device.
    public static func isNewer(date: Date, revision: String, than otherDate: Date, revision otherRevision: String) -> Bool {
        date == otherDate ? revision > otherRevision : date > otherDate
    }
}

public struct BackupMergeResult: Sendable {
    public let journal: JournalBackup
    public let added: Int
    public let updated: Int
    public let kept: Int
}

extension JournalBackup {
    public func merging(into current: JournalBackup) throws -> BackupMergeResult {
        try validate(); try current.validate()
        var added = 0, updated = 0, kept = 0
        func merge<T: Identifiable>(_ incoming: [T], _ existing: [T],
                                   stamp: (T) -> (Date, String)) -> [T] where T.ID == UUID {
            var records = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for record in incoming {
                if let old = records[record.id] {
                    let (date, revision) = stamp(record), (oldDate, oldRevision) = stamp(old)
                    if RecordRevision.isNewer(date: date, revision: revision, than: oldDate, revision: oldRevision) {
                        records[record.id] = record; updated += 1
                    } else { kept += 1 }
                } else { records[record.id] = record; added += 1 }
            }
            return records.values.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let journal = JournalBackup(createdAt: .now,
            checkpoints: merge(checkpoints, current.checkpoints) { ($0.modifiedAt, $0.revision) },
            outsideCharges: merge(outsideCharges, current.outsideCharges) { ($0.modifiedAt, $0.revision) },
            monthlyMileage: merge(monthlyMileage, current.monthlyMileage) { ($0.modifiedAt, $0.revision) },
            meterSettings: current.meterSettings)
        let readings = journal.checkpoints.map { record in
            Reading(id: record.id, date: record.date, t1: Numbers.parse(record.t1Text)!, t2: Numbers.parse(record.t2Text)!,
                    averageRate: Numbers.parse(record.averageRateText)!, t1Rate: Numbers.parse(record.t1RateText)!,
                    t2Rate: Numbers.parse(record.t2RateText)!, useTariffRates: record.useTariffRates,
                    monthBoundary: record.monthBoundary, closesCycle: record.closesCycle, isBaseline: record.isBaseline,
                    tripA: record.tripAText.flatMap(Numbers.parse), tripB: record.tripBText.flatMap(Numbers.parse),
                    battery: record.battery, hasMeterReading: record.hasMeterReading,
                    meterTotal: record.meterTotalText.flatMap(Numbers.parse))
        }
        for reading in readings {
            if let issue = Ledger.validate(reading, against: readings) {
                throw BackupError("The backup conflicts with the journal: \(issue) No entries were imported.")
            }
        }
        guard Set(journal.monthlyMileage.map(\.month)).count == journal.monthlyMileage.count else {
            throw BackupError("The backup has a different entry for a month already in the journal. No entries were imported.")
        }
        return BackupMergeResult(journal: journal, added: added, updated: updated, kept: kept)
    }
}

extension BackupCheckpoint: Identifiable {}
extension BackupOutsideCharge: Identifiable {}
extension BackupMonthlyMileage: Identifiable {}

// Decimal inputs stay as text, preserving precision, optional mileage and original meter formats.
public struct BackupCheckpoint: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var recordedAt: Date
    public var t1Text: String
    public var t2Text: String
    public var averageRateText: String
    public var t1RateText: String
    public var t2RateText: String
    public var useTariffRates: Bool
    public var monthBoundary: Date?
    public var closesCycle: Bool
    public var isBaseline: Bool
    public var tripAText: String?
    public var tripBText: String?
    public var tripBCounterText: String?
    public var tripBPreviousCounterText: String?
    public var tripBPreviousCheckpointID: UUID?
    public var battery: Int?
    public var linkedChargeID: UUID?
    public var hasMeterReading: Bool
    public var meterTotalText: String?
    public var endedOutside: Bool
    public var monthMileageMigrated: Bool
    public var homeDataStatus: String?
    public var homeDataAddedAt: Date?
    public var modifiedAt: Date
    public var revision: String

    public init(id: UUID,
                date: Date,
                recordedAt: Date,
                t1Text: String = "0",
                t2Text: String = "0",
                averageRateText: String = "47.5",
                t1RateText: String = "53.48",
                t2RateText: String = "43.48",
                useTariffRates: Bool = false,
                monthBoundary: Date? = nil,
                closesCycle: Bool = false,
                isBaseline: Bool = false,
                tripAText: String? = nil,
                tripBText: String? = nil,
                tripBCounterText: String? = nil,
                tripBPreviousCounterText: String? = nil,
                tripBPreviousCheckpointID: UUID? = nil,
                battery: Int? = nil,
                linkedChargeID: UUID? = nil,
                hasMeterReading: Bool = true,
                meterTotalText: String? = nil,
                endedOutside: Bool = false,
                monthMileageMigrated: Bool = true,
                homeDataStatus: String? = nil,
                homeDataAddedAt: Date? = nil,
                modifiedAt: Date = Date(timeIntervalSince1970: 0),
                revision: String = "") {
        self.id = id
        self.date = date
        self.recordedAt = recordedAt
        self.t1Text = t1Text
        self.t2Text = t2Text
        self.averageRateText = averageRateText
        self.t1RateText = t1RateText
        self.t2RateText = t2RateText
        self.useTariffRates = useTariffRates
        self.monthBoundary = monthBoundary
        self.closesCycle = closesCycle
        self.isBaseline = isBaseline
        self.tripAText = tripAText
        self.tripBText = tripBText
        self.tripBCounterText = tripBCounterText
        self.tripBPreviousCounterText = tripBPreviousCounterText
        self.tripBPreviousCheckpointID = tripBPreviousCheckpointID
        self.battery = battery
        self.linkedChargeID = linkedChargeID
        self.hasMeterReading = hasMeterReading
        self.meterTotalText = meterTotalText
        self.endedOutside = endedOutside
        self.monthMileageMigrated = monthMileageMigrated
        self.homeDataStatus = homeDataStatus
        self.homeDataAddedAt = homeDataAddedAt
        self.modifiedAt = modifiedAt
        self.revision = revision
    }
}

public struct BackupOutsideCharge: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var energyText: String
    public var costText: String
    public var location: String
    public var tripBText: String?
    public var stationBrand: String?
    public var modifiedAt: Date
    public var revision: String

    public init(id: UUID,
                date: Date,
                energyText: String,
                costText: String,
                location: String = "",
                tripBText: String? = nil,
                stationBrand: String? = nil,
                modifiedAt: Date = Date(timeIntervalSince1970: 0),
                revision: String = "") {
        self.id = id
        self.date = date
        self.energyText = energyText
        self.costText = costText
        self.location = location
        self.tripBText = tripBText
        self.stationBrand = stationBrand
        self.modifiedAt = modifiedAt
        self.revision = revision
    }
}

public struct BackupMonthlyMileage: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var month: Date
    public var distanceText: String
    public var modifiedAt: Date
    public var revision: String

    public init(id: UUID,
                date: Date,
                month: Date,
                distanceText: String,
                modifiedAt: Date = Date(timeIntervalSince1970: 0),
                revision: String = "") {
        self.id = id
        self.date = date
        self.month = month
        self.distanceText = distanceText
        self.modifiedAt = modifiedAt
        self.revision = revision
    }
}

public struct BackupMeterSettings: Codable, Equatable, Sendable {
    public var averageRate: String
    public var t1Rate: String
    public var t2Rate: String
    public var useTariffRates: Bool

    public init(averageRate: String = "47.5",
                t1Rate: String = "53.48",
                t2Rate: String = "43.48",
                useTariffRates: Bool = false) {
        self.averageRate = averageRate
        self.t1Rate = t1Rate
        self.t2Rate = t2Rate
        self.useTariffRates = useTariffRates
    }
}

