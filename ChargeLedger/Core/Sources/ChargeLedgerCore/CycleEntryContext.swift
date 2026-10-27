import Foundation

/// Context for the cycle being entered, independent of monthly home-meter checkpoints.
public struct CycleEntryContext: Sendable {
    public let end: Date
    public let previousCheckpoint: Reading?
    public let previousCycle: PeriodSummary?
    public let outsideSessions: [Charge]
    public let previousCycleSessions: [Charge]
    public var start: Date? { previousCheckpoint?.date }
    public var outsideEnergy: Decimal { outsideSessions.reduce(0) { $0 + $1.energy } }
    public var outsideCost: Decimal { outsideSessions.reduce(0) { $0 + $1.cost } }

    public init(endingAt end: Date, excludingCheckpointID: UUID? = nil, readings: [Reading], charges: [Charge]) {
        self.end = end
        let previous = readings.filter {
            $0.id != excludingCheckpointID && $0.closesCycle && $0.date < end
        }.max { $0.date < $1.date }
        previousCheckpoint = previous
        let completed = previous.flatMap { checkpoint in
            let start = readings.filter {
                $0.id != excludingCheckpointID && $0.closesCycle && $0.date < checkpoint.date
            }.max { $0.date < $1.date }
            guard let start else { return nil as PeriodSummary? }
            return Ledger.cycles(readings: readings.filter {
                $0.id != excludingCheckpointID && $0.date >= start.date && $0.date <= checkpoint.date
            }, charges: charges).first { $0.id == checkpoint.id }
        }
        previousCycle = completed
        outsideSessions = charges.filter { session in
            session.date <= end && (previous.map { session.date > $0.date } ?? true)
        }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        previousCycleSessions = completed.map { cycle in
            charges.filter { $0.date > cycle.start && $0.date <= cycle.end }.sorted { $0.date < $1.date }
        } ?? []
    }

    public func contains(_ date: Date) -> Bool { date <= end && (start.map { date > $0 } ?? true) }

    public static func combining(saved: [Charge], replacingID: UUID? = nil, replacement: Charge? = nil,
                                 drafts: [Charge] = []) -> [Charge] {
        var records: [UUID: Charge] = [:]
        for session in saved where session.id != replacingID { records[session.id] = session }
        if let replacement { records[replacement.id] = replacement }
        for draft in drafts { records[draft.id] = draft }
        return records.values.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
    }
}

public struct TripBCalculation: Equatable, Sendable {
    public let currentCounter: Decimal
    public let previousCounter: Decimal
    public var distance: Decimal { currentCounter - previousCounter }

    public init(currentCounter: Decimal, previousCounter: Decimal) throws {
        guard !currentCounter.isNaN, !previousCounter.isNaN, currentCounter >= 0, previousCounter >= 0 else {
            throw TripBCalculationError("Enter valid Trip B readings of zero or greater.")
        }
        guard currentCounter >= previousCounter else {
            throw TripBCalculationError("The current counter is below the previous reading. If Trip B was reset, enter its current value directly in the cycle form.")
        }
        self.currentCounter = currentCounter; self.previousCounter = previousCounter
    }

    public init(currentText: String, previousText: String) throws {
        guard let current = Numbers.parse(currentText), let previous = Numbers.parse(previousText) else {
            throw TripBCalculationError("Enter the car’s current Trip B and its actual reading at the previous 100% charge.")
        }
        try self.init(currentCounter: current, previousCounter: previous)
    }
}

public struct TripBCalculationError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
