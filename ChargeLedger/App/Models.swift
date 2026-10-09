import Foundation
import SwiftData
import ChargeLedgerCore

@Model
final class Checkpoint {
    @Attribute(.unique) var id: UUID
    var date: Date
    var recordedAt: Date
    var t1Text: String
    var t2Text: String
    var averageRateText: String
    var t1RateText: String
    var t2RateText: String
    var useTariffRates: Bool
    var monthBoundary: Date?
    var closesCycle: Bool
    var isBaseline: Bool
    var tripAText: String?
    var tripBText: String?
    var battery: Int?
    // A combined outside-charge + checkpoint entry stays linked when edited.
    var linkedChargeID: UUID?

    init(reading: Reading, linkedChargeID: UUID? = nil) {
        id = reading.id; date = reading.date; recordedAt = .now
        t1Text = Numbers.string(reading.t1); t2Text = Numbers.string(reading.t2)
        averageRateText = Numbers.string(reading.averageRate)
        t1RateText = Numbers.string(reading.t1Rate); t2RateText = Numbers.string(reading.t2Rate)
        useTariffRates = reading.useTariffRates
        monthBoundary = reading.monthBoundary; closesCycle = reading.closesCycle
        isBaseline = reading.isBaseline
        tripAText = reading.tripA.map(Numbers.string); tripBText = reading.tripB.map(Numbers.string)
        battery = reading.battery; self.linkedChargeID = linkedChargeID
    }

    var reading: Reading {
        Reading(id: id, date: date, t1: Numbers.parse(t1Text) ?? 0, t2: Numbers.parse(t2Text) ?? 0,
                averageRate: Numbers.parse(averageRateText) ?? 0,
                t1Rate: Numbers.parse(t1RateText) ?? 0, t2Rate: Numbers.parse(t2RateText) ?? 0,
                useTariffRates: useTariffRates,
                monthBoundary: monthBoundary, closesCycle: closesCycle, isBaseline: isBaseline,
                tripA: tripAText.flatMap(Numbers.parse), tripB: tripBText.flatMap(Numbers.parse), battery: battery)
    }

    func update(with value: Reading) {
        date = value.date; t1Text = Numbers.string(value.t1); t2Text = Numbers.string(value.t2)
        monthBoundary = value.monthBoundary; closesCycle = value.closesCycle
        tripAText = value.tripA.map(Numbers.string); tripBText = value.tripB.map(Numbers.string)
        battery = value.battery
        averageRateText = Numbers.string(value.averageRate)
        t1RateText = Numbers.string(value.t1Rate); t2RateText = Numbers.string(value.t2Rate)
        useTariffRates = value.useTariffRates
    }

    var title: String {
        if isBaseline { return "Starting readings" }
        if monthBoundary != nil && closesCycle { return "New month · 100% charge" }
        return monthBoundary != nil ? "New month" : "100% charge"
    }
}

@Model
final class OutsideCharge {
    @Attribute(.unique) var id: UUID
    var date: Date
    var energyText: String
    var costText: String
    var location: String
    var tripBText: String? = nil

    init(charge: Charge) {
        id = charge.id; date = charge.date
        energyText = Numbers.string(charge.energy); costText = Numbers.string(charge.cost)
        location = charge.location
        tripBText = charge.tripB.map(Numbers.string)
    }

    var charge: Charge {
        Charge(id: id, date: date, energy: Numbers.parse(energyText) ?? 0,
               cost: Numbers.parse(costText) ?? 0, location: location,
               tripB: tripBText.flatMap(Numbers.parse))
    }
}

enum EntryKind: String, Identifiable {
    case baseline, month, cycle, outside
    var id: String { rawValue }
    var title: String {
        switch self {
        case .baseline: "Starting readings"
        case .month: "Start new month"
        case .cycle: "Reached 100%"
        case .outside: "Outside charging"
        }
    }
    var icon: String {
        switch self {
        case .baseline: "flag.fill"
        case .month: "calendar.badge.plus"
        case .cycle: "battery.100percent"
        case .outside: "bolt.car.fill"
        }
    }
}

struct EntryRequest: Identifiable {
    let id = UUID()
    let kind: EntryKind
    var checkpoint: Checkpoint? = nil
    var charge: OutsideCharge? = nil
}
