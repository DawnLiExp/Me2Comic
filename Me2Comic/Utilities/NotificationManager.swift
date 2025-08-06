//
//  NotificationManager.swift
//  Me2Comic
//
//  Created by me2 on 2025/8/6.
//

import Foundation
import UserNotifications

/// Manages user notifications for the application.
class NotificationManager {
    /// Requests authorization for user notifications.
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                #if DEBUG
                    print("Notification authorization granted.")
                #endif
            } else if let error = error {
                #if DEBUG
                    print("Notification authorization denied: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Sends a local user notification.
    /// - Parameters:
    ///   - title: The title of the notification.
    ///   - subtitle: The subtitle of the notification.
    ///   - body: The main content of the notification.
    func sendNotification(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                #if DEBUG
                    print("Failed to send notification: \(error.localizedDescription)")
                #endif
            }
        }
    }
}
