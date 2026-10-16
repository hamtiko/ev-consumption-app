import Foundation
import SwiftData
import ChargeLedgerCore

extension Checkpoint {
    var backupRecord: BackupCheckpoint {
        BackupCheckpoint(id: id,
            date: date,
            recordedAt: recordedAt,
            t1Text: t1Text,
            t2Text: t2Text,
            averageRateText: averageRateText,
            t1RateText: t1RateText,
            t2RateText: t2RateText,
            useTariffRates: useTariffRates,
            monthBoundary: monthBoundary,
            closesCycle: closesCycle,
            isBaseline: isBaseline,
            tripAText: tripAText,
            tripBText: tripBText,
            battery: battery,
            linkedChargeID: linkedChargeID,
            hasMeterReading: hasMeterReading,
            meterTotalText: meterTotalText,
            endedOutside: endedOutside,
            monthMileageMigrated: monthMileageMigrated,
            homeDataStatus: homeDataStatus,
            homeDataAddedAt: homeDataAddedAt,
            modifiedAt: modifiedAt,
            revision: revision)
    }

    convenience init(backup: BackupCheckpoint) {
        self.init(reading: Reading(id: backup.id, date: backup.date, t1: 0, t2: 0))
        apply(backup)
    }

    func apply(_ backup: BackupCheckpoint) {
        id = backup.id
        date = backup.date
        recordedAt = backup.recordedAt
        t1Text = backup.t1Text
        t2Text = backup.t2Text
        averageRateText = backup.averageRateText
        t1RateText = backup.t1RateText
        t2RateText = backup.t2RateText
        useTariffRates = backup.useTariffRates
        monthBoundary = backup.monthBoundary
        closesCycle = backup.closesCycle
        isBaseline = backup.isBaseline
        tripAText = backup.tripAText
        tripBText = backup.tripBText
        battery = backup.battery
        linkedChargeID = backup.linkedChargeID
        hasMeterReading = backup.hasMeterReading
        meterTotalText = backup.meterTotalText
        endedOutside = backup.endedOutside
        monthMileageMigrated = backup.monthMileageMigrated
        homeDataStatus = backup.homeDataStatus
        homeDataAddedAt = backup.homeDataAddedAt
        modifiedAt = backup.modifiedAt
        revision = backup.revision
    }
}

extension LegacyJournalSchema.Checkpoint {
    var backupRecord: BackupCheckpoint {
        BackupCheckpoint(id: id,
            date: date,
            recordedAt: recordedAt,
            t1Text: t1Text,
            t2Text: t2Text,
            averageRateText: averageRateText,
            t1RateText: t1RateText,
            t2RateText: t2RateText,
            useTariffRates: useTariffRates,
            monthBoundary: monthBoundary,
            closesCycle: closesCycle,
            isBaseline: isBaseline,
            tripAText: tripAText,
            tripBText: tripBText,
            battery: battery,
            linkedChargeID: linkedChargeID,
            hasMeterReading: hasMeterReading,
            meterTotalText: meterTotalText,
            endedOutside: endedOutside,
            monthMileageMigrated: monthMileageMigrated,
            homeDataStatus: homeDataStatus,
            homeDataAddedAt: homeDataAddedAt)
    }
}

extension OutsideCharge {
    var backupRecord: BackupOutsideCharge {
        BackupOutsideCharge(id: id,
            date: date,
            energyText: energyText,
            costText: costText,
            location: location,
            tripBText: tripBText,
            stationBrand: stationBrand,
            modifiedAt: modifiedAt,
            revision: revision)
    }

    convenience init(backup: BackupOutsideCharge) {
        self.init(charge: Charge(id: backup.id, date: backup.date, energy: 0, cost: 0))
        apply(backup)
    }

    func apply(_ backup: BackupOutsideCharge) {
        id = backup.id
        date = backup.date
        energyText = backup.energyText
        costText = backup.costText
        location = backup.location
        tripBText = backup.tripBText
        stationBrand = backup.stationBrand
        modifiedAt = backup.modifiedAt
        revision = backup.revision
    }
}

extension LegacyJournalSchema.OutsideCharge {
    var backupRecord: BackupOutsideCharge {
        BackupOutsideCharge(id: id,
            date: date,
            energyText: energyText,
            costText: costText,
            location: location,
            tripBText: tripBText,
            stationBrand: stationBrand)
    }
}

extension MonthlyMileage {
    var backupRecord: BackupMonthlyMileage {
        BackupMonthlyMileage(id: id,
            date: date,
            month: month,
            distanceText: distanceText,
            modifiedAt: modifiedAt,
            revision: revision)
    }

    convenience init(backup: BackupMonthlyMileage) {
        self.init(record: MileageRecord(id: backup.id, date: backup.date, month: backup.month, distance: 0))
        apply(backup)
    }

    func apply(_ backup: BackupMonthlyMileage) {
        id = backup.id
        date = backup.date
        month = backup.month
        distanceText = backup.distanceText
        modifiedAt = backup.modifiedAt
        revision = backup.revision
    }
}

extension LegacyJournalSchema.MonthlyMileage {
    var backupRecord: BackupMonthlyMileage {
        BackupMonthlyMileage(id: id,
            date: date,
            month: month,
            distanceText: distanceText)
    }
}

