//
//  NotificationManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import Foundation
import UserNotifications

/// Manages user notifications for the application.
final class NotificationManager: Sendable {
    /// Requests authorization for user notifications.
    /// - Returns: `true` if authorization was granted, `false` otherwise.
    /// - Throws: An error if the authorization request failed.
    func requestNotificationAuthorization() async throws -> Bool {
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Sends a local user notification.
    /// - Parameters:
    ///   - title: The title of the notification.
    ///   - subtitle: The subtitle of the notification.
    ///   - body: The main content of the notification.
    /// - Throws: An error if the notification could not be added.

    func sendNotification(title: String, subtitle: String, body: String) async throws {
        // Notification identifier for managing duplicate notifications
        let identifier = "me2.comic.me2comic.processing.complete"

        // Remove previously delivered notifications with same identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        try await UNUserNotificationCenter.current().add(request)
    }
}
