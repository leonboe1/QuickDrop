//
//  AppDelegate.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import UserNotifications
import NearbyShare
import SwiftUI
import StoreKit

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MainAppDelegate{
    private var statusItem:NSStatusItem?
    private var activeIncomingTransfers:[String:TransferInfo]=[:]
    
    var window: NSWindow?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let menu=NSMenu()
        menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        
        // Add "Recommended Apps" menu item
        let recommendedAppsItem = NSMenuItem(title: NSLocalizedString("RecommendedApps", value: "Recommended Apps", comment: ""), action: #selector(openRecommendedApps), keyEquivalent: "")
        menu.addItem(recommendedAppsItem)
        
        // Add "Privacy Policy" menu item
        let privacyPolicyItem = NSMenuItem(title: NSLocalizedString("PrivacyPolicy", value: "Privacy Policy", comment: ""), action: #selector(openPrivacyPolicy), keyEquivalent: "")
        menu.addItem(privacyPolicyItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let userManualItem = NSMenuItem(title: NSLocalizedString("UserManual", value: "User Manual", comment: ""), action: #selector(openWelcomeScreen), keyEquivalent: "")
        menu.addItem(userManualItem)
        
        menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        
        
        statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image=NSImage(named: "MenuBarIcon")
        statusItem?.menu=menu
        statusItem?.behavior = .removalAllowed
        
        let nc=UNUserNotificationCenter.current()
        nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if !granted{
                DispatchQueue.main.async {
                    self.showNotificationsDeniedAlert()
                }
            }
        }
        nc.delegate=self
        let incomingTransfersCategory=UNNotificationCategory(identifier: "INCOMING_TRANSFERS", actions: [
            UNNotificationAction(identifier: "ACCEPT", title: NSLocalizedString("Accept", comment: ""), options: UNNotificationActionOptions.authenticationRequired)
        ], intentIdentifiers: [])
        let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
        nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
        NearbyConnectionManager.shared.mainAppDelegate=self
        NearbyConnectionManager.shared.becomeVisible()
        
        if !UserDefaults.standard.bool(forKey: "ShowedWelcomeScreen"){
            openWelcomeScreen()
            UserDefaults.standard.set(true, forKey: "ShowedWelcomeScreen")
        }
    }
    
    
    @objc func openWelcomeScreen() {
        // Create the welcome screen SwiftUI view
        let welcomeView = WelcomeScreen()
        
        // Create an NSWindow to host the SwiftUI view
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window?.center()
        window?.isReleasedWhenClosed = false
        window?.setFrameAutosaveName("WelcomeScreen")
        window?.contentView = NSHostingView(rootView: welcomeView)
        
        // Ensure the window is always on top
        window?.level = .floating
        
        window?.makeKeyAndOrderFront(nil)
    }
    
    
    // Action for "Recommended Apps" menu item
    @objc func openRecommendedApps() {
        if let url = URL(string: "https://apps.apple.com/de/developer/leon-boettger/id1537384790") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // Action for "Privacy Policy" menu item
    @objc func openPrivacyPolicy() {
        if let url = URL(string: "  ") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible=true
        return true
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func showNotificationsDeniedAlert(){
        let alert=NSAlert()
        alert.alertStyle = .critical
        alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
        alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "NearDrop needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit NearDrop", comment: ""))
        let result=alert.runModal()
        if result==NSApplication.ModalResponse.alertFirstButtonReturn{
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
        }else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
            NSApplication.shared.terminate(nil)
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let transferID=response.notification.request.content.userInfo["transferID"]! as! String
        NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: response.actionIdentifier=="ACCEPT")
        if response.actionIdentifier != "ACCEPT"{
            activeIncomingTransfers.removeValue(forKey: transferID)
        }
        completionHandler()
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.sound, .banner])
    }
    
    func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
        let fileStr:String
        if let textTitle=transfer.textDescription{
            fileStr=textTitle
        }else if transfer.files.count==1{
            fileStr=transfer.files[0].name
        }else{
            fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
        }
        let notificationContent=UNMutableNotificationContent()
        notificationContent.title="NearDrop"
        notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [transfer.pinCode!])
        notificationContent.body=String(format: NSLocalizedString("DeviceSendingFiles", value: "%1$@ is sending you %2$@", comment: ""), arguments: [device.name, fileStr])
        notificationContent.sound = .default
        notificationContent.categoryIdentifier="INCOMING_TRANSFERS"
        notificationContent.userInfo=["transferID": transfer.id]
        if #available(macOS 11.0, *){
            NDNotificationCenterHackery.removeDefaultAction(notificationContent)
        }
        let notificationReq=UNNotificationRequest(identifier: "transfer_"+transfer.id, content: notificationContent, trigger: nil)
        UNUserNotificationCenter.current().add(notificationReq)
        self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
    }
    
    func incomingTransfer(id: String, didFinishWith error: Error?) {
        guard let transfer=self.activeIncomingTransfers[id] else {return}
        if let error=error{
            let notificationContent=UNMutableNotificationContent()
            notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [transfer.device.name])
            if let ne=(error as? NearbyError){
                switch ne{
                case .inputOutput:
                    notificationContent.body="I/O Error";
                case .protocolError(_):
                    notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
                case .requiredFieldMissing:
                    notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
                case .ukey2:
                    notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
                case .canceled(reason: _):
                    break; // can't happen for incoming transfers
                }
            }else{
                notificationContent.body=error.localizedDescription
            }
            notificationContent.categoryIdentifier="ERRORS"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+id, content: notificationContent, trigger: nil))
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_"+id])
        self.activeIncomingTransfers.removeValue(forKey: id)
        
        let currentCount = UserDefaults.standard.integer(forKey: "reviewRequestCountKey")
       
        if currentCount % 20 == 0 {   
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                SKStoreReviewController.requestReview()
            }
        }
        
        UserDefaults.standard.set(currentCount + 1, forKey: "reviewRequestCountKey")
    }
}

struct TransferInfo{
    let device:RemoteDeviceInfo
    let transfer:TransferMetadata
}
