import Foundation

public enum Numbers {
    /// Accept either decimal separator from the numeric keyboard; never interpret grouping.
    public static func parse(_ text: String) -> Decimal? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty,
              normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }

    public static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    public static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

public struct Reading: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let t1: Decimal
    public let t2: Decimal
    public let averageRate: Decimal
    public let t1Rate: Decimal
    public let t2Rate: Decimal
    public let useTariffRates: Bool
    public let monthBoundary: Date?
    public let closesCycle: Bool
    public let isBaseline: Bool
    public let tripA: Decimal?
    public let tripB: Decimal?
    public let battery: Int?
    public let hasMeterReading: Bool
    public let meterTotal: Decimal?
    public var usesSingleMeter: Bool { meterTotal != nil }
    public var total: Decimal { meterTotal ?? (t1 + t2) }

    public init(id: UUID = UUID(), date: Date, t1: Decimal, t2: Decimal,
                averageRate: Decimal = Decimal(string: "47.5")!,
                t1Rate: Decimal = Decimal(string: "53.48")!,
                t2Rate: Decimal = Decimal(string: "43.48")!,
                useTariffRates: Bool = false,
                monthBoundary: Date? = nil, closesCycle: Bool = false,
                isBaseline: Bool = false, tripA: Decimal? = nil,
                tripB: Decimal? = nil, battery: Int? = nil,
                hasMeterReading: Bool = true, meterTotal: Decimal? = nil) {
        self.id = id; self.date = date; self.t1 = t1; self.t2 = t2
        self.averageRate = averageRate; self.t1Rate = t1Rate; self.t2Rate = t2Rate
        self.useTariffRates = useTariffRates
        self.monthBoundary = monthBoundary; self.closesCycle = closesCycle
        self.isBaseline = isBaseline; self.tripA = tripA; self.tripB = tripB
        self.battery = battery
        self.hasMeterReading = hasMeterReading; self.meterTotal = meterTotal
    }
}

public struct MileageRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let month: Date
    public let distance: Decimal
    public let distanceKnown: Bool
    public init(id: UUID = UUID(), date: Date, month: Date, distance: Decimal, distanceKnown: Bool = true) {
        self.id = id; self.date = date; self.month = month; self.distance = distance
        self.distanceKnown = distanceKnown
    }
}

public struct Charge: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let energy: Decimal
    public let cost: Decimal
    public let location: String
    /// Optional counter reading at a partial charge. It does not reset or close Trip B.
    public let tripB: Decimal?

    public init(id: UUID = UUID(), date: Date, energy: Decimal, cost: Decimal, location: String = "", tripB: Decimal? = nil) {
        self.id = id; self.date = date; self.energy = energy; self.cost = cost; self.location = location
        self.tripB = tripB
    }
}

public struct PeriodSummary: Identifiable, Sendable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let month: Date?
    public let distance: Decimal
    public let homeEnergy: Decimal
    public let outsideEnergy: Decimal
    public let estimatedHomeCost: Decimal
    public let tariffComparisonCost: Decimal?
    public let outsideCost: Decimal
    public let startBattery: Int?
    public let endBattery: Int?
    public let homeEnergyKnown: Bool
    public let cycleCount: Int
    public let missingHomeReadingIDs: [UUID]
    public var distanceKnown: Bool = true
    public var totalEnergy: Decimal? { homeEnergyKnown ? homeEnergy + outsideEnergy : nil }
    public var estimatedTotalCost: Decimal? { homeEnergyKnown ? estimatedHomeCost + outsideCost : nil }
    public var energyPer100KM: Decimal? {
        guard distanceKnown, distance > 0, let totalEnergy else { return nil }
        return totalEnergy / distance * 100
    }
    public var costPerKM: Decimal? {
        guard distanceKnown, distance > 0, let estimatedTotalCost else { return nil }
        return estimatedTotalCost / distance
    }
}

public enum Ledger {
    /// Month identifiers use a stable Gregorian UTC calendar, independent of travel or DST.
    public static var monthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Monthly readings and cycle readings share the same cumulative home counter.
    public static func latestMeterReading(before date: Date, excludingID: UUID? = nil, readings: [Reading]) -> Reading? {
        readings.filter { $0.id != excludingID && $0.hasMeterReading && $0.date < date }
            .max(by: { $0.date < $1.date })
    }
    /// Prevent invalid backdated edits by checking BOTH neighboring meter readings.
    public static func validate(_ candidate: Reading, against readings: [Reading]) -> String? {
        guard candidate.t1 >= 0, candidate.t2 >= 0,
              candidate.meterTotal.map({ $0 >= 0 }) ?? true,
              candidate.averageRate >= 0, candidate.t1Rate >= 0, candidate.t2Rate >= 0 else {
            return "Meter readings and prices must be zero or greater."
        }
        if let battery = candidate.battery, !(0...100).contains(battery) {
            return "Battery level must be between 0 and 100%."
        }
        if candidate.closesCycle && candidate.battery != 100 {
            return "A full-charge checkpoint must have a battery level of 100%."
        }
        if let value = candidate.tripA, value < 0 { return "Trip A cannot be negative." }
        if let value = candidate.tripB, value < 0 { return "Trip B cannot be negative." }
        if !candidate.isBaseline {
            if candidate.closesCycle && candidate.tripB == nil { return "Enter the Trip B distance." }
        }
        let others = readings.filter { $0.id != candidate.id }.sorted { $0.date < $1.date }
        if others.contains(where: { $0.date == candidate.date }) {
            return "A meter reading already exists at this time. Edit it or choose a different time."
        }
        if let month = candidate.monthBoundary,
           others.contains(where: { $0.monthBoundary == month }) {
            return "A checkpoint for this month already exists. Edit the existing entry."
        }
        if candidate.hasMeterReading {
            if let previous = others.last(where: { $0.date < candidate.date && $0.hasMeterReading }),
               candidate.total < previous.total || (!candidate.usesSingleMeter && !previous.usesSingleMeter &&
                    (candidate.t1 < previous.t1 || candidate.t2 < previous.t2)) {
                return "The meter readings must be at least as high as the previous readings."
            }
            if let next = others.first(where: { $0.date > candidate.date && $0.hasMeterReading }),
               candidate.total > next.total || (!candidate.usesSingleMeter && !next.usesSingleMeter &&
                    (candidate.t1 > next.t1 || candidate.t2 > next.t2)) {
                return "The meter readings cannot exceed the next recorded readings."
            }
        }
        let combined = (others + [candidate]).sorted { $0.date < $1.date }
        if combined.filter(\.isBaseline).count > 1 { return "Only one starting checkpoint is allowed." }
        let boundaries = combined.compactMap(\.monthBoundary)
        if zip(boundaries, boundaries.dropFirst()).contains(where: { previous, next in previous >= next }) {
            return "Monthly checkpoints must follow calendar order."
        }
        return nil
    }

    public static func carryingForwardMeter(for reading: Reading, readings: [Reading]) -> Reading? {
        guard let previous = readings.filter({ $0.id != reading.id && $0.date < reading.date && $0.hasMeterReading })
            .max(by: { $0.date < $1.date }) else { return nil }
        return Reading(id: reading.id, date: reading.date, t1: previous.t1, t2: previous.t2,
                       averageRate: reading.averageRate, t1Rate: reading.t1Rate, t2Rate: reading.t2Rate,
                       useTariffRates: reading.useTariffRates, monthBoundary: reading.monthBoundary,
                       closesCycle: reading.closesCycle, isBaseline: reading.isBaseline,
                       tripA: reading.tripA, tripB: reading.tripB, battery: reading.battery,
                       hasMeterReading: true, meterTotal: previous.meterTotal)
    }

    /// Confirmation covers the entire interval since the latest known meter reading.
    public static func confirmingNoHomeCharging(through reading: Reading, readings: [Reading]) -> [Reading]? {
        guard let previous = readings.filter({ $0.id != reading.id && $0.date < reading.date && $0.hasMeterReading })
            .max(by: { $0.date < $1.date }) else { return nil }
        var pending = readings.filter {
            $0.id != reading.id && !$0.hasMeterReading && $0.date > previous.date && $0.date < reading.date
        }
        pending.append(reading)
        return pending.compactMap { carryingForwardMeter(for: $0, readings: readings) }.sorted { $0.date < $1.date }
    }

    public static func cycles(readings: [Reading], charges: [Charge]) -> [PeriodSummary] {
        let sorted = readings.sorted { $0.date < $1.date }
        let endpoints = sorted.filter(\.closesCycle)
        return zip(endpoints, endpoints.dropFirst()).compactMap { start, end in
            guard let distance = end.tripB, !end.isBaseline else { return nil }
            return summary(from: start, to: end, distance: distance, month: nil,
                           readings: sorted, charges: charges)
        }
    }

    /// Full energy windows can span several Trip B resets at outside chargers.
    public static func measurements(readings: [Reading], charges: [Charge]) -> [PeriodSummary] {
        let sorted = readings.sorted { $0.date < $1.date }
        let endpoints = sorted.filter { $0.closesCycle && $0.hasMeterReading }
        return zip(endpoints, endpoints.dropFirst()).compactMap { start, end in
            let cycles = sorted.filter { $0.closesCycle && $0.date > start.date && $0.date <= end.date }
            guard cycles.allSatisfy({ $0.tripB != nil }), !end.isBaseline else { return nil }
            let distance = cycles.reduce(Decimal.zero) { $0 + ($1.tripB ?? 0) }
            return summary(from: start, to: end, distance: distance, month: nil,
                           readings: sorted, charges: charges, cycleCount: cycles.count)
        }
    }

    public static func months(readings: [Reading], charges: [Charge], mileage: [MileageRecord] = [],
                              calendar: Calendar = Ledger.monthCalendar, sessionCalendar: Calendar = .current) -> [PeriodSummary] {
        let sorted = readings.sorted { $0.date < $1.date }
        let endpoints = sorted.filter { $0.monthBoundary != nil }
        var reports: [PeriodSummary] = zip(endpoints, endpoints.dropFirst()).compactMap { start, end in
            guard let startMonth = start.monthBoundary, let endMonth = end.monthBoundary,
                  calendar.date(byAdding: .month, value: 1, to: startMonth) == endMonth,
                  !end.isBaseline else { return nil }
            var report = summary(from: start, to: end, distance: end.tripA ?? 0, month: startMonth,
                                 readings: sorted, charges: charges, cycleCount: 0)
            report.distanceKnown = end.tripA != nil
            return report
        }
        for record in mileage {
            let legacy = reports.first { $0.month == record.month }
            reports.removeAll { $0.month == record.month }
            if let legacy {
                reports.append(PeriodSummary(id: record.id, start: legacy.start, end: legacy.end, month: record.month,
                    distance: record.distance, homeEnergy: legacy.homeEnergy, outsideEnergy: legacy.outsideEnergy,
                    estimatedHomeCost: legacy.estimatedHomeCost, tariffComparisonCost: legacy.tariffComparisonCost,
                    outsideCost: legacy.outsideCost, startBattery: legacy.startBattery, endBattery: legacy.endBattery,
                    homeEnergyKnown: legacy.homeEnergyKnown, cycleCount: 0, missingHomeReadingIDs: legacy.missingHomeReadingIDs,
                    distanceKnown: record.distanceKnown))
            } else {
                let parts = monthCalendar.dateComponents([.year, .month], from: record.month)
                let start = sessionCalendar.date(from: parts)!
                let end = sessionCalendar.date(byAdding: .month, value: 1, to: start)!
                let outside = charges.filter { $0.date >= start && $0.date < end }
                reports.append(PeriodSummary(id: record.id, start: start, end: end, month: record.month,
                    distance: record.distance, homeEnergy: 0, outsideEnergy: outside.reduce(0) { $0 + $1.energy },
                    estimatedHomeCost: 0, tariffComparisonCost: nil, outsideCost: outside.reduce(0) { $0 + $1.cost },
                    startBattery: nil, endBattery: nil, homeEnergyKnown: false, cycleCount: 0, missingHomeReadingIDs: [],
                    distanceKnown: record.distanceKnown))
            }
        }
        return reports.sorted { ($0.month ?? $0.end) < ($1.month ?? $1.end) }
    }

    /// Every consecutive meter segment uses the rate saved at its endpoint. Intermediate
    /// monthly readings do not reset Trip B; their segments still contribute to its cycle.
    private static func summary(from start: Reading, to end: Reading, distance: Decimal,
                                month: Date?, readings: [Reading], charges: [Charge], cycleCount: Int = 1) -> PeriodSummary {
        let known = start.hasMeterReading && end.hasMeterReading
        let inside = readings.filter { $0.hasMeterReading && $0.date >= start.date && $0.date <= end.date }
        var cost: Decimal = 0
        var comparison: Decimal = 0
        var comparisonKnown = known
        for (previous, current) in zip(inside, inside.dropFirst()) {
            let dual = !previous.usesSingleMeter && !current.usesSingleMeter
            let tariffCost = (current.t1 - previous.t1) * current.t1Rate
                + (current.t2 - previous.t2) * current.t2Rate
            if dual { comparison += tariffCost } else { comparisonKnown = false }
            cost += current.useTariffRates && dual ? tariffCost : (current.total - previous.total) * current.averageRate
        }
        // A charge saved alongside a 100% checkpoint belongs to the ENDING cycle.
        let external = charges.filter { $0.date > start.date && $0.date <= end.date }
        return PeriodSummary(id: end.id, start: start.date, end: end.date, month: month,
                             distance: distance, homeEnergy: known ? end.total - start.total : 0,
                             outsideEnergy: external.reduce(0) { $0 + $1.energy },
                             estimatedHomeCost: known ? cost : 0, tariffComparisonCost: comparisonKnown ? comparison : nil,
                             outsideCost: external.reduce(0) { $0 + $1.cost },
                             startBattery: start.battery, endBattery: end.battery,
                             homeEnergyKnown: known, cycleCount: cycleCount,
                             missingHomeReadingIDs: [start, end].filter { !$0.hasMeterReading }.map(\.id))
    }

    public static func weightedEfficiency(_ summaries: [PeriodSummary]) -> Decimal? {
        let complete = summaries.filter { $0.totalEnergy != nil && $0.distanceKnown }
        let distance = complete.reduce(Decimal.zero) { $0 + $1.distance }
        guard distance > 0 else { return nil }
        return complete.reduce(Decimal.zero) { $0 + ($1.totalEnergy ?? 0) } / distance * 100
    }
}
