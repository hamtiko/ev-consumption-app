import Foundation

public enum StationBrands {
    public static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func key(_ name: String?) -> String {
        guard let cleaned = clean(name) else { return "unspecified" }
        return "brand:" + cleaned.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func choices(_ names: [String?]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            guard let cleaned = clean(name), seen.insert(key(cleaned)).inserted else { return nil }
            return cleaned
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func canonicalName(_ name: String?, choices: [String]) -> String? {
        guard let cleaned = clean(name) else { return nil }
        return choices.first { key($0) == key(cleaned) } ?? cleaned
    }
}

public struct MetricStatistics: Sendable {
    public let average: Decimal
    public let minimum: Decimal
    public let maximum: Decimal
    public let sampleCount: Int
}

public struct CycleStatistics: Sendable {
    public let consumption: MetricStatistics
    public let costPerKM: MetricStatistics
    public let distance: Decimal
    public let homeEnergy: Decimal
    public let outsideEnergy: Decimal
    public let homeCost: Decimal
    public let outsideCost: Decimal
    public var totalEnergy: Decimal { homeEnergy + outsideEnergy }
    public var totalCost: Decimal { homeCost + outsideCost }
    public var outsideEnergyShare: Decimal? { totalEnergy > 0 ? outsideEnergy / totalEnergy * 100 : nil }
    public var outsideCostShare: Decimal? { totalCost > 0 ? outsideCost / totalCost * 100 : nil }
    public var homePricePerKWh: Decimal? { homeEnergy > 0 ? homeCost / homeEnergy : nil }
    public var outsidePricePerKWh: Decimal? { outsideEnergy > 0 ? outsideCost / outsideEnergy : nil }
}

public struct BrandSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let energy: Decimal
    public let cost: Decimal
    public let sessions: Int
    public let energyShare: Decimal?
    public var pricePerKWh: Decimal? { energy > 0 ? cost / energy : nil }
}

public struct MonthlyCostChange: Sendable {
    public let amount: Decimal
    public let percent: Decimal?
}

public enum ReportRange: String, CaseIterable, Sendable {
    case threeMonths, sixMonths, twelveMonths, yearToDate, all

    public func start(through now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .all: return nil
        case .yearToDate: return calendar.dateInterval(of: .year, for: now)?.start
        default:
            let count = self == .threeMonths ? 3 : self == .sixMonths ? 6 : 12
            guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
            return calendar.date(byAdding: .month, value: -(count - 1), to: monthStart)
        }
    }

    public func includes(_ date: Date, through now: Date, calendar: Calendar = .current) -> Bool {
        date <= now && (start(through: now, calendar: calendar).map { date >= $0 } ?? true)
    }

    /// Stable UTC month identifiers are compared as local calendar months, not UTC timestamps.
    public func includesMonth(_ month: Date, through now: Date, calendar: Calendar = .current) -> Bool {
        let parts = Ledger.monthCalendar.dateComponents([.year, .month], from: month)
        guard let localMonth = calendar.date(from: parts) else { return false }
        return includes(localMonth, through: now, calendar: calendar)
    }
}

public enum ReportAnalytics {
    public static func eligibleCycles(_ cycles: [PeriodSummary]) -> [PeriodSummary] {
        cycles.filter { $0.homeEnergyKnown && $0.distanceKnown && $0.distance > 0 }
    }

    public static func cycleStatistics(_ cycles: [PeriodSummary]) -> CycleStatistics? {
        let eligible = eligibleCycles(cycles)
        guard !eligible.isEmpty else { return nil }
        let distance = eligible.reduce(Decimal.zero) { $0 + $1.distance }
        let homeEnergy = eligible.reduce(Decimal.zero) { $0 + $1.homeEnergy }
        let outsideEnergy = eligible.reduce(Decimal.zero) { $0 + $1.outsideEnergy }
        let homeCost = eligible.reduce(Decimal.zero) { $0 + $1.estimatedHomeCost }
        let outsideCost = eligible.reduce(Decimal.zero) { $0 + $1.outsideCost }
        let efficiency = eligible.compactMap(\.energyPer100KM)
        let cost = eligible.compactMap(\.costPerKM)
        return CycleStatistics(
            consumption: MetricStatistics(average: (homeEnergy + outsideEnergy) / distance * 100,
                                          minimum: efficiency.min()!, maximum: efficiency.max()!, sampleCount: eligible.count),
            costPerKM: MetricStatistics(average: (homeCost + outsideCost) / distance,
                                       minimum: cost.min()!, maximum: cost.max()!, sampleCount: eligible.count),
            distance: distance, homeEnergy: homeEnergy, outsideEnergy: outsideEnergy, homeCost: homeCost, outsideCost: outsideCost)
    }

    public static func brands(charges: [Charge]) -> [BrandSummary] {
        let sorted = charges.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let groups = Dictionary(grouping: sorted) { StationBrands.key($0.stationBrand) }
        let totalEnergy = charges.reduce(Decimal.zero) { $0 + $1.energy }
        return groups.map { key, sessions in
            let energy = sessions.reduce(Decimal.zero) { $0 + $1.energy }
            return BrandSummary(id: key, name: StationBrands.clean(sessions[0].stationBrand) ?? "Unspecified",
                                energy: energy, cost: sessions.reduce(Decimal.zero) { $0 + $1.cost }, sessions: sessions.count,
                                energyShare: totalEnergy > 0 ? energy / totalEnergy * 100 : nil)
        }.sorted { $0.energy == $1.energy ? $0.id < $1.id : $0.energy > $1.energy }
    }

    public static func monthlyCostChange(for current: PeriodSummary, reports: [PeriodSummary]) -> MonthlyCostChange? {
        guard current.homeEnergyKnown, let month = current.month,
              let previousMonth = Ledger.monthCalendar.date(byAdding: .month, value: -1, to: month),
              let previous = reports.first(where: {
                  $0.homeEnergyKnown && $0.month.map { Ledger.monthCalendar.isDate($0, equalTo: previousMonth, toGranularity: .month) } == true
              }) else { return nil }
        let change = current.estimatedHomeCost - previous.estimatedHomeCost
        return MonthlyCostChange(amount: change, percent: previous.estimatedHomeCost > 0 ? change / previous.estimatedHomeCost * 100 : nil)
    }
}
