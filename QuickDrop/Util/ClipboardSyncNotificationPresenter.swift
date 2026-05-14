//
//  ClipboardSyncNotificationPresenter.swift
//  QuickDrop
//

#if os(macOS) && !EXTENSION

import Foundation
import UserNotifications
import LUI

final class ClipboardSyncNotificationPresenter {

    static let shared = ClipboardSyncNotificationPresenter()
    static let notificationIdentifier = "quickdrop-clipboard-sync"

    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "ClipboardSyncNotificationPresenter")
    private var pendingNotifications: [(String, String?)] = []
    private var authorizationRequestInFlight = false

    private init() {}

    func present(clipboardText: String, senderDeviceName: String?) {
        queue.async {
            self.postNotificationIfAuthorized(
                clipboardText: clipboardText,
                senderDeviceName: senderDeviceName
            )
        }
    }

    private func postNotificationIfAuthorized(clipboardText: String, senderDeviceName: String?) {
        center.getNotificationSettings { settings in
            self.queue.async {
                self.handleAuthorizationStatus(
                    settings.authorizationStatus,
                    clipboardText: clipboardText,
                    senderDeviceName: senderDeviceName
                )
            }
        }
    }

    private func handleAuthorizationStatus(
        _ status: UNAuthorizationStatus,
        clipboardText: String,
        senderDeviceName: String?
    ) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            post(clipboardText: clipboardText, senderDeviceName: senderDeviceName)
        case .notDetermined:
            pendingNotifications.append((clipboardText, senderDeviceName))
            requestAuthorizationIfNeeded()
        case .denied:
            log("[ClipboardSyncNotificationPresenter] Notifications are denied in system settings; cannot show clipboard sync notification.")
        @unknown default:
            log("[ClipboardSyncNotificationPresenter] Unknown notification authorization status; skipping clipboard sync notification.")
        }
    }

    private func requestAuthorizationIfNeeded() {
        if authorizationRequestInFlight {
            return
        }

        authorizationRequestInFlight = true

        DispatchQueue.main.async {
            self.center.requestAuthorization(options: [.alert, .badge]) { granted, error in
                self.queue.async {
                    self.authorizationRequestInFlight = false

                    if let error = error {
                        log("[ClipboardSyncNotificationPresenter] Authorization request failed: \(error.localizedDescription)")
                    }

                    guard granted else {
                        log("[ClipboardSyncNotificationPresenter] Authorization request not granted; dropping queued clipboard sync notifications.")
                        self.pendingNotifications.removeAll()
                        return
                    }

                    let queued = self.pendingNotifications
                    self.pendingNotifications.removeAll()
                    for (queuedText, queuedSender) in queued {
                        self.post(clipboardText: queuedText, senderDeviceName: queuedSender)
                    }
                }
            }
        }
    }

    private func post(clipboardText: String, senderDeviceName: String?) {
        let senderName = senderDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = "CopiedToClipboard".localized()
        content.body = preview(for: clipboardText)
        content.subtitle = senderName?.isEmpty == false ? senderName! : "QuickDrop"
        content.threadIdentifier = Self.notificationIdentifier
        content.interruptionLevel = .active

        let identifier = Self.notificationIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                log("[ClipboardSyncNotificationPresenter] Could not post notification: \(error.localizedDescription)")
            } else {
                log("[ClipboardSyncNotificationPresenter] Posted clipboard sync notification (\(identifier)).")
            }
        }
    }

    private func preview(for clipboardText: String) -> String {
        clipboardText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
