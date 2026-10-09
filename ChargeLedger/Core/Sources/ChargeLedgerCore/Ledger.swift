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
    public var total: Decimal { t1 + t2 }

    public init(id: UUID = UUID(), date: Date, t1: Decimal, t2: Decimal,
                averageRate: Decimal = Decimal(string: "47.5")!,
                t1Rate: Decimal = Decimal(string: "53.48")!,
                t2Rate: Decimal = Decimal(string: "43.48")!,
                useTariffRates: Bool = false,
                monthBoundary: Date? = nil, closesCycle: Bool = false,
                isBaseline: Bool = false, tripA: Decimal? = nil,
                tripB: Decimal? = nil, battery: Int? = nil) {
        self.id = id; self.date = date; self.t1 = t1; self.t2 = t2
        self.averageRate = averageRate; self.t1Rate = t1Rate; self.t2Rate = t2Rate
        self.useTariffRates = useTariffRates
        self.monthBoundary = monthBoundary; self.closesCycle = closesCycle
        self.isBaseline = isBaseline; self.tripA = tripA; self.tripB = tripB
        self.battery = battery
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
    public let tariffComparisonCost: Decimal
    public let outsideCost: Decimal
    public let startBattery: Int?
    public let endBattery: Int?
    public var totalEnergy: Decimal { homeEnergy + outsideEnergy }
    public var estimatedTotalCost: Decimal { estimatedHomeCost + outsideCost }
    public var energyPer100KM: Decimal? { distance > 0 ? totalEnergy / distance * 100 : nil }
    public var costPerKM: Decimal? { distance > 0 ? estimatedTotalCost / distance : nil }
}

public enum Ledger {
    /// Month identifiers use a stable Gregorian UTC calendar, independent of travel or DST.
    public static var monthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    /// Prevent invalid backdated edits by checking BOTH neighboring meter readings.
    public static func validate(_ candidate: Reading, against readings: [Reading]) -> String? {
        guard candidate.t1 >= 0, candidate.t2 >= 0,
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
            if candidate.monthBoundary != nil && candidate.tripA == nil { return "Enter the Trip A distance." }
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
        if let previous = others.last(where: { $0.date < candidate.date }),
           candidate.t1 < previous.t1 || candidate.t2 < previous.t2 {
            return "The meter readings must be at least as high as the previous readings."
        }
        if let next = others.first(where: { $0.date > candidate.date }),
           candidate.t1 > next.t1 || candidate.t2 > next.t2 {
            return "The meter readings cannot exceed the next recorded readings."
        }
        let combined = (others + [candidate]).sorted { $0.date < $1.date }
        if let baseline = combined.first(where: \.isBaseline), baseline.id != combined.first?.id {
            return "The starting readings must remain the earliest checkpoint."
        }
        if combined.filter(\.isBaseline).count > 1 { return "Only one starting checkpoint is allowed." }
        let boundaries = combined.compactMap(\.monthBoundary)
        if zip(boundaries, boundaries.dropFirst()).contains(where: { previous, next in previous >= next }) {
            return "Monthly checkpoints must follow calendar order."
        }
        return nil
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

    public static func months(readings: [Reading], charges: [Charge], calendar: Calendar = Ledger.monthCalendar) -> [PeriodSummary] {
        let sorted = readings.sorted { $0.date < $1.date }
        let endpoints = sorted.filter { $0.monthBoundary != nil }
        return zip(endpoints, endpoints.dropFirst()).compactMap { start, end in
            guard let startMonth = start.monthBoundary, let endMonth = end.monthBoundary,
                  calendar.date(byAdding: .month, value: 1, to: startMonth) == endMonth,
                  let distance = end.tripA, !end.isBaseline else { return nil }
            return summary(from: start, to: end, distance: distance, month: startMonth,
                           readings: sorted, charges: charges)
        }
    }

    /// Every consecutive meter segment uses the rate saved at its endpoint. Intermediate
    /// monthly readings do not reset Trip B; their segments still contribute to its cycle.
    private static func summary(from start: Reading, to end: Reading, distance: Decimal,
                                month: Date?, readings: [Reading], charges: [Charge]) -> PeriodSummary {
        let inside = readings.filter { $0.date >= start.date && $0.date <= end.date }
        var cost: Decimal = 0
        var comparison: Decimal = 0
        for (previous, current) in zip(inside, inside.dropFirst()) {
            let tariffCost = (current.t1 - previous.t1) * current.t1Rate
                + (current.t2 - previous.t2) * current.t2Rate
            comparison += tariffCost
            cost += current.useTariffRates ? tariffCost : (current.total - previous.total) * current.averageRate
        }
        // A charge saved alongside a 100% checkpoint belongs to the ENDING cycle.
        let external = charges.filter { $0.date > start.date && $0.date <= end.date }
        return PeriodSummary(id: end.id, start: start.date, end: end.date, month: month,
                             distance: distance, homeEnergy: end.total - start.total,
                             outsideEnergy: external.reduce(0) { $0 + $1.energy },
                             estimatedHomeCost: cost, tariffComparisonCost: comparison,
                             outsideCost: external.reduce(0) { $0 + $1.cost },
                             startBattery: start.battery, endBattery: end.battery)
    }

    public static func weightedEfficiency(_ summaries: [PeriodSummary]) -> Decimal? {
        let distance = summaries.reduce(Decimal.zero) { $0 + $1.distance }
        guard distance > 0 else { return nil }
        return summaries.reduce(Decimal.zero) { $0 + $1.totalEnergy } / distance * 100
    }
}
