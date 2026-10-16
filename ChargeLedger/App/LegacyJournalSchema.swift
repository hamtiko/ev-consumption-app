import Foundation
import SwiftData
import ChargeLedgerCore

// Frozen schema of the last local-only release. Do not edit these stored properties.
enum LegacyJournalSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Checkpoint.self, OutsideCharge.self, MonthlyMileage.self] }

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
        var hasMeterReading: Bool = true
        var meterTotalText: String? = nil
        var endedOutside: Bool = false
        var monthMileageMigrated: Bool = false
        var homeDataStatus: String? = nil
        var homeDataAddedAt: Date? = nil

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
            hasMeterReading = reading.hasMeterReading
            meterTotalText = reading.meterTotal.map(Numbers.string)
            monthMileageMigrated = true
        }

        var reading: Reading {
            Reading(id: id, date: date, t1: Numbers.parse(t1Text) ?? 0, t2: Numbers.parse(t2Text) ?? 0,
                    averageRate: Numbers.parse(averageRateText) ?? 0,
                    t1Rate: Numbers.parse(t1RateText) ?? 0, t2Rate: Numbers.parse(t2RateText) ?? 0,
                    useTariffRates: useTariffRates,
                    monthBoundary: monthBoundary, closesCycle: closesCycle, isBaseline: isBaseline,
                    tripA: tripAText.flatMap(Numbers.parse), tripB: tripBText.flatMap(Numbers.parse), battery: battery,
                    hasMeterReading: hasMeterReading, meterTotal: meterTotalText.flatMap(Numbers.parse))
        }

        func update(with value: Reading) {
            date = value.date; t1Text = Numbers.string(value.t1); t2Text = Numbers.string(value.t2)
            monthBoundary = value.monthBoundary; closesCycle = value.closesCycle
            tripAText = value.tripA.map(Numbers.string); tripBText = value.tripB.map(Numbers.string)
            battery = value.battery
            averageRateText = Numbers.string(value.averageRate)
            t1RateText = Numbers.string(value.t1Rate); t2RateText = Numbers.string(value.t2Rate)
            useTariffRates = value.useTariffRates
            hasMeterReading = value.hasMeterReading
            meterTotalText = value.meterTotal.map(Numbers.string)
        }

        var title: String {
            if isBaseline { return "Starting readings" }
            if !closesCycle { return "Home meter reading" }
            return "100% cycle"
        }
    }

    @Model
    final class MonthlyMileage {
        @Attribute(.unique) var id: UUID
        var date: Date
        var month: Date
        var distanceText: String

        init(record: MileageRecord) {
            id = record.id; date = record.date; month = record.month
            distanceText = record.distanceKnown ? Numbers.string(record.distance) : ""
        }

        var record: MileageRecord {
            MileageRecord(id: id, date: date, month: month, distance: Numbers.parse(distanceText) ?? 0,
                          distanceKnown: Numbers.parse(distanceText) != nil)
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
        var stationBrand: String? = nil

        init(charge: Charge) {
            id = charge.id; date = charge.date
            energyText = Numbers.string(charge.energy); costText = Numbers.string(charge.cost)
            location = charge.location
            tripBText = charge.tripB.map(Numbers.string)
            stationBrand = charge.stationBrand
        }

        var charge: Charge {
            Charge(id: id, date: date, energy: Numbers.parse(energyText) ?? 0,
                   cost: Numbers.parse(costText) ?? 0, location: location,
                   tripB: tripBText.flatMap(Numbers.parse), stationBrand: stationBrand)
        }
    }
}
