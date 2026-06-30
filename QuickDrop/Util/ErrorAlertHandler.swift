//
//  ErrorAlertHandler.swift
//  QuickDrop
//
//  Created by Leon Böttger on 25.07.25.
//

import AudioToolbox
import Network
import StoreKit
import SwiftUI
import UserNotifications
import LUI

#if os(macOS)
import BezelNotification
import Cocoa
#endif

class ErrorAlertHandler {

    private init() {}
    static let shared = ErrorAlertHandler()
    
    private var isAlertShown = false
    #if os(macOS)
    private var firewallAlertWindow: NSWindow?
    private var apIsolationAlertWindow: NSWindow?
    private var networkFilterAlertWindow: NSWindow?
    private var androidAirDropModeAlertWindow: NSWindow?
    #endif
    
    /// Resource key for the recoverable-error suffix ("if this keeps happening…") appended to most
    /// transfer errors.
    ///
    /// `Error.FixInstructions` suggests downloading the QuickDrop Android app from Google Play, which
    /// is pointless for a peer that already runs QuickDrop. For such a peer (`isQuickDropPeer == true`)
    /// the `Error.FixInstructionsAppInstalled` variant — the same advice without the download
    /// suggestion — is used instead.
    static func fixInstructionsKey(isQuickDropPeer: Bool) -> String {
        isQuickDropPeer ? "Error.FixInstructionsAppInstalled" : "Error.FixInstructions"
    }

    /// Presents the transfer-error alert for `deviceName`.
    ///
    /// - Parameter isQuickDropPeer: whether the other device runs the QuickDrop app. When `true`, the
    ///   "download the app from Google Play" suggestion is omitted from the fix instructions (see
    ///   `fixInstructionsKey(isQuickDropPeer:)`). Defaults to `false` so callers without device context
    ///   keep the full hint.
    func showErrorAlert(for deviceName: String, error: Error, isQuickDropPeer: Bool = false) {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif

        var description = ""
        let fixInstructions = " " + Self.fixInstructionsKey(isQuickDropPeer: isQuickDropPeer).localized()
        if let ne = (error as? NearbyError) {
            switch ne {
            case .inputOutput:
                description = "I/O Error." + fixInstructions
            case .protocolError(errorMessage: let errorMessage):
                description = errorMessage + fixInstructions
            case .packetFilterError:
                #if os(macOS)
                openAlert(type: .NetworkFilter)
                return
                #else
                description = error.localizedDescription
                #endif
            case .firewallError:
                #if os(macOS)
                openAlert(type: .Firewall)
                return
                #else
                description = error.localizedDescription
                #endif
            case .requiredFieldMissing(errorMessage: let errorMessage):
                description = errorMessage + fixInstructions
            case .ukey2:
                description = "Error.Crypto".localized() + ": \(ne.localizedDescription)" + fixInstructions
            case .notificationSyncNotTrusted:
                description = "NotificationSyncNotTrustedMessage".localized()
            case .canceled(reason: let reason):
                if reason == .timedOut {
                    description = reason.localizedDescription() + fixInstructions
                }
                else {
                    description = reason.localizedDescription()
                }
            }
        } else {
            description = error.localizedDescription
        }
        
        // Prevent multiple alerts at the same time
        if self.isAlertShown {
            log("Skipping alert for error \(error.localizedDescription) because one is already shown")
            return
        }
        else {
            AudioManager.playErrorSound()
            
            let title = String(format: "TransferError".localized(), arguments: [deviceName])
            log("Showing alert with title: \"\(title)\" and description: \"\(description)\"")
            log("Unsuccessful transmission. Already successful transmissions: \(Settings.sharedInstance.incomingTransmissionCount)")
            
            #if os(macOS)
            
            // Shown modelessly (the native NSAlert panel via makeKeyAndOrderFront) rather than
            // runModal(), which blocks the main run loop and would freeze the next incoming transfer's
            // consent prompt until dismissed. Same window runModal() uses, so it looks identical.
            self.isAlertShown = true
            presentTransferErrorAlert(title: title, description: description)
            #else
            showAlert(title: title, message: description)
            #endif
        }
    }
    

    #if os(macOS)
    func openAlert(type: AlertType) {
        log("Opening Alert for \(type)")
        AudioManager.playErrorSound()

        DispatchQueue.main.async { [self] in
            if let existingWindow = alertWindow(for: type), existingWindow.isVisible {
                bringAlertWindowToFront(existingWindow)
                return
            }

            // Create an NSWindow to host the SwiftUI view
            let alertWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: issueViewWidth, height: issueViewHeight),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )

            switch type {
            case .ApIsolation:
                apIsolationAlertWindow = alertWindow
                alertWindow.contentView = NSHostingView(rootView: ApIsolationIssueView(closeView: { self.apIsolationAlertWindow?.close() }))
            case .NetworkFilter:
                networkFilterAlertWindow = alertWindow
                alertWindow.contentView = NSHostingView(rootView: NetworkFilterIssueView())
            case .Firewall:
                firewallAlertWindow = alertWindow
                alertWindow.contentView = NSHostingView(rootView: FirewallIssueView())
            case .AndroidAirDropMode:
                androidAirDropModeAlertWindow = alertWindow
                alertWindow.contentView = NSHostingView(rootView: AndroidAirDropModeIssueView())
            }

            alertWindow.title = "QuickDrop"
            alertWindow.center()
            alertWindow.isReleasedWhenClosed = false
            alertWindow.setFrameAutosaveName(type.rawValue)

            alertWindow.level = .normal
            bringAlertWindowToFront(alertWindow)
        }
    }
    
    
    func closeApIsolationAlert() {
        log("Closing AP Isolation Alert")
        DispatchQueue.main.async {
            self.apIsolationAlertWindow?.close()
            self.apIsolationAlertWindow = nil
        }
    }

    private func alertWindow(for type: AlertType) -> NSWindow? {
        switch type {
        case .ApIsolation:
            return apIsolationAlertWindow
        case .NetworkFilter:
            return networkFilterAlertWindow
        case .Firewall:
            return firewallAlertWindow
        case .AndroidAirDropMode:
            return androidAirDropModeAlertWindow
        }
    }

    private func bringAlertWindowToFront(_ window: NSWindow) {
        // Keep the app a menu-bar (.accessory) app: do NOT switch to .regular,
        // which would add a dock icon that lingers after the alert closes.
        // orderFrontRegardless() brings the window to the front even though the
        // app stays inactive in the background.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }


    /// Shows the transfer-error alert as the native `NSAlert` panel, but presented modelessly
    /// (`makeKeyAndOrderFront`) instead of `runModal()`, so it does NOT block the main run loop — an
    /// incoming transfer's consent prompt can still appear while it's on screen. It's the same
    /// `_NSAlertPanel` window `runModal()` would show, so it looks identical; we just route the button
    /// clicks ourselves (there's no modal session to end) and reset state on dismissal.
    private func presentTransferErrorAlert(title: String, description: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = description
        alert.addButton(withTitle: "InformDeveloper".localized())   // tag == .alertFirstButtonReturn
        alert.addButton(withTitle: "CloseAlert".localized())        // tag == .alertSecondButtonReturn
        alert.buttons.first?.keyEquivalent = "\r"                    // default button: Return
        if alert.buttons.count > 1 { alert.buttons[1].keyEquivalent = "\u{1b}" }  // Close: Escape

        ModelessAlertPresenter.present(alert) { [weak self] response in
            self?.isAlertShown = false
            if response == .alertFirstButtonReturn {
                Self.presentLogUpload()
            }
        }
    }


    /// The "Inform developer" action: from the share extension, hand off to the host app via the
    /// `quickdrop://sendLog` URL; otherwise upload logs directly. Mirrors the previous alert's primary
    /// button.
    private static func presentLogUpload() {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            if let url = URL(string: "quickdrop://sendLog") {
                NSWorkspace.shared.open(url)
            }
        } else {
            LogExportPresenter.showUploadLogsAlert(openSupportMailAfterUpload: false)
        }
    }
    #endif
}


enum AlertType: String {
    case ApIsolation
    case NetworkFilter
    case Firewall
    case AndroidAirDropMode
}
