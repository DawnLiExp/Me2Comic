//
//  NotificationManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import Foundation
import UserNotifications

/// Manages user notifications for the application.
class NotificationManager {
    /// Requests authorization for user notifications.
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            #if DEBUG
                if granted {
                    print("Notification authorization granted.")
                } else if let error = error {
                    print("Notification authorization denied: \(error.localizedDescription)")
                }
            #endif
        }
    }

    /// Sends a local user notification.
    /// - Parameters:
    ///   - title: The title of the notification.
    ///   - subtitle: The subtitle of the notification.
    ///   - body: The main content of the notification.
    func sendNotification(title: String, subtitle: String, body: String) {
        if Thread.isMainThread {
            createNotification(title: title, subtitle: subtitle, body: body)
        } else {
            DispatchQueue.main.async {
                self.createNotification(title: title, subtitle: subtitle, body: body)
            }
        }
    }

    /// Creates and schedules a local notification with the specified content.
    /// - Parameters:
    ///   - title: The notification title
    ///   - subtitle: The notification subtitle
    ///   - body: The notification body text
    private func createNotification(title: String, subtitle: String, body: String) {
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

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
                if let error = error {
                    print("Failed to send notification: \(error.localizedDescription)")
                }
            #endif
        }
    }
}
