import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class ReminderService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderService()
    static let identifier = "chargeledger.monthly-checkpoint"
    @Published var monthRequested = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func schedule(hour: Int, minute: Int, requestPermission: Bool) async throws {
        let center = UNUserNotificationCenter.current()
        if requestPermission {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw ReminderError.permissionDenied }
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderError.permissionDenied
        }
        let content = UNMutableNotificationContent()
        content.title = "Time for your monthly readings"
        content.body = "Record last month’s mileage, meter readings, and battery level, then reset Trip A."
        content.sound = .default
        content.userInfo = ["flow": "month"]
        // No fixed time zone: follow the user's local wall clock, including DST.
        var components = DateComponents()
        components.day = 1; components.hour = hour; components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        // Reusing this identifier replaces the old time without duplicate reminders.
        try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }

    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "chargeledger.monthly-checkpoint" {
            Task { @MainActor in self.monthRequested = true }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum ReminderError: LocalizedError {
    case permissionDenied
    var errorDescription: String? {
        "Notifications are disabled. Allow notifications for Charge Ledger in iPhone Settings, then enable the reminder again."
    }
}
