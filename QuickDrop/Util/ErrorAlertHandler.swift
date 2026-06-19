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
    
    func showErrorAlert(for deviceName: String, error: Error) {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        
        var description = ""
        let fixInstructions = " " + "Error.FixInstructions".localized()
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
            
            let primaryButtonTitle = "InformDeveloper".localized()
            let secondaryButtonTitle = "CloseAlert".localized()
            
            self.isAlertShown = true
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = title
            alert.informativeText = description
            alert.addButton(withTitle: primaryButtonTitle)
            alert.addButton(withTitle: secondaryButtonTitle)
            
            let result = alert.runModal()
            self.isAlertShown = false
            
            if result == .alertFirstButtonReturn {
                if Bundle.main.bundlePath.hasSuffix(".appex") {
                    if let url = URL(string: "quickdrop://sendLog") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    LogExportPresenter.showUploadLogsAlert(openSupportMailAfterUpload: false)
                }
            }
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
    #endif
}


enum AlertType: String {
    case ApIsolation
    case NetworkFilter
    case Firewall
    case AndroidAirDropMode
}
