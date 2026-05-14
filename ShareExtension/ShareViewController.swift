//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Grishka on 12.09.2023.
//

import AppKit
import Cocoa
import Foundation
import LUI
import SwiftUI

class ShareViewController: NSViewController, OutboundAppDelegate {
    
    private var urls: [URL] = []
    private var textToSend: String? = nil
    private var foundDevices: [RemoteDeviceInfo] = []
    private var chosenDevice: RemoteDeviceInfo?
    private var lastError: Error?
    private var errorAlertHandler = ErrorAlertHandler.shared
    
    private var connectionEstablished = false
    private var timeoutDispatchWorkItem: DispatchWorkItem? = nil
    
    @IBOutlet var filesIcon: NSImageView?
    @IBOutlet var filesLabel: NSTextField?
    @IBOutlet var loadingOverlay: NSStackView?
    @IBOutlet var largeProgress: NSProgressIndicator?
    @IBOutlet var listView: NSCollectionView?
    @IBOutlet var listViewWrapper: NSView?
    @IBOutlet var contentWrap: NSView?
    @IBOutlet var progressView: NSView?
    @IBOutlet var progressDeviceIcon: NSImageView?
    @IBOutlet var progressDeviceName: NSTextField?
    @IBOutlet var progressProgressBar: NSProgressIndicator?
    @IBOutlet var progressState: NSTextField?
    @IBOutlet var progressDeviceIconWrap: NSView?
    @IBOutlet var progressDeviceSecondaryIcon: NSImageView?
    @IBOutlet var dontSeeDeviceButton: NSButton?
    
    private var qrCodeSheetView: NSPanel? = nil
    private var sheetAttachedWindow: NSWindow? = nil
    
    
    override var nibName: NSNib.Name? {
        return NSNib.Name("ShareViewController")
    }
    
    
    override func loadView() {
        
        super.loadView()
        LUIInit(configuration: configuration)
        
        loadAttachments(with: extensionContext, loadedItems: { result in
            
            log("[ShareViewController] Loaded attachments: \(result)")
            
            self.urls = result.urls
            self.textToSend = result.textToSend
            self.filesLabel?.stringValue = result.shortDescription
            self.filesIcon?.image = result.previewImage
        })
        
        contentWrap!.addSubview(listViewWrapper!)
        contentWrap!.addSubview(loadingOverlay!)
        contentWrap!.addSubview(progressView!)
        progressView!.isHidden = true
        
        listViewWrapper!.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay!.translatesAutoresizingMaskIntoConstraints = false
        progressView!.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            NSLayoutConstraint(item: listViewWrapper!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
            NSLayoutConstraint(item: listViewWrapper!, attribute: .height, relatedBy: .equal, toItem: contentWrap, attribute: .height, multiplier: 1, constant: 0),
            
            NSLayoutConstraint(item: loadingOverlay!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
            NSLayoutConstraint(item: loadingOverlay!, attribute: .centerY, relatedBy: .equal, toItem: contentWrap, attribute: .centerY, multiplier: 1, constant: 0),
            
            NSLayoutConstraint(item: progressView!, attribute: .width, relatedBy: .equal, toItem: contentWrap, attribute: .width, multiplier: 1, constant: 0),
            NSLayoutConstraint(item: progressView!, attribute: .centerY, relatedBy: .equal, toItem: contentWrap, attribute: .centerY, multiplier: 1, constant: 0),
        ])
        
        largeProgress!.startAnimation(nil)
        
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.itemSize = NSSize(width: 75, height: 90)
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        flowLayout.minimumInteritemSpacing = 10
        flowLayout.minimumLineSpacing = 10
        listView!.collectionViewLayout = flowLayout
        listView!.dataSource = self
        
        progressDeviceIconWrap!.wantsLayer = true
        progressDeviceIconWrap!.layer!.masksToBounds = false
        progressDeviceSecondaryIcon?.image = NSImage(named: "MenuBarIcon")
        progressDeviceSecondaryIcon?.image?.isTemplate = true
        progressDeviceSecondaryIcon?.contentTintColor = .white
    }
    
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        dicoverDevices()
        NearbyConnectionManager.shared.addOutboundAppDelegate(self)
    }
    
    
    override func viewWillDisappear() {
        log("[ShareViewController] ShareViewController: viewWillDisappear")
        
        timeoutDispatchWorkItem?.cancel()
        
        NearbyConnectionManager.shared.stopDeviceDiscovery()
        NearbyConnectionManager.shared.removeOutboundAppDelegate(self)
    }
    
    
    @IBAction func cancel(_: AnyObject?) {
        if let device = chosenDevice {
            NearbyConnectionManager.shared.cancelTransfer(id: device.id!)
        }
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        extensionContext!.cancelRequest(withError: cancelError)
    }
    
    
    @IBAction func dontSeeDeviceButton(_: AnyObject?) {
        openQrCodeView()
    }
    
    
    private func openQrCodeView() {
        if qrCodeSheetView == nil {
            
            let contentView = SmallSheetView(type: .sendToDeviceQrCode, dynamicQrCode: NearbyConnectionManager.shared.generateQrCodeKey()) {
                self.closeQrCodeView()
            }
            
            let hostingView = NSHostingView(rootView: contentView)
            
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: smallSheetViewSize.width, height: smallSheetViewSize.height),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered,
                                defer: false)
            
            panel.contentView = hostingView
            
            qrCodeSheetView = panel
            
            if let mainWindow = NSApp.mainWindow {
                sheetAttachedWindow = mainWindow
                mainWindow.beginSheet(panel) { _ in }
            }
        }
    }
    
    
    private func closeQrCodeView() {
        if let mainWindow = sheetAttachedWindow, let qrCodeView = qrCodeSheetView {
            mainWindow.endSheet(qrCodeView)
            
            qrCodeSheetView = nil
            sheetAttachedWindow = nil
        }
    }
    
    
    func addDevice(device: RemoteDeviceInfo) {
        
        if chosenDevice != nil {
            return
        }
        if foundDevices.isEmpty {
            loadingOverlay?.animator().isHidden = true
        }
        foundDevices.append(device)
        listView?.animator().insertItems(at: [[0, foundDevices.count - 1]])
        
        closeQrCodeView()
    }
    
    
    func removeDevice(id: String) {
        
        if chosenDevice != nil {
            return
        }
        for i in foundDevices.indices {
            if foundDevices[i].id == id {
                foundDevices.remove(at: i)
                listView?.animator().deleteItems(at: [[0, i]])
                break
            }
        }
        if foundDevices.isEmpty {
            loadingOverlay?.animator().isHidden = false
        }
    }
    
    
    func startTransferWithQrCode(device: RemoteDeviceInfo) {
        closeQrCodeView()
        selectDevice(device: device)
    }
    
    
    func connectionWasEstablished(pinCode: String) {
        connectionEstablished = true
        
        progressState?.stringValue = String(format: "PinCode".localized(), arguments: [pinCode])
        progressProgressBar?.isIndeterminate = false
        progressProgressBar?.maxValue = 1000
        progressProgressBar?.doubleValue = 0
    }
    
    
    func connectionFailed(error: Error) {
        progressProgressBar?.isIndeterminate = false
        progressProgressBar?.maxValue = 1000
        progressProgressBar?.doubleValue = 0
        lastError = error
        
        ErrorAlertHandler.shared.showErrorAlert(for: chosenDevice?.name ?? "", error: error)
        self.extensionContext!.cancelRequest(withError: error)
    }
    
    
    func transferAccepted() {
        progressState?.stringValue = "Sending".localized()
    }
    
    
    func transferProgress(progress: Double) {
        progressProgressBar!.doubleValue = progress * progressProgressBar!.maxValue
    }
    
    
    func transferFinished() {
        progressState?.stringValue = "TransferFinished".localized()
        dismissDelayed()
    }
    
    
    func selectDevice(device: RemoteDeviceInfo) {
        
        listViewWrapper?.animator().isHidden = true
        dontSeeDeviceButton?.animator().isHidden = true
        progressView?.animator().isHidden = false
        progressDeviceName?.stringValue = getDeviceName(device: device)
        progressDeviceIcon?.image = imageForDeviceType(type: device.type)
        progressDeviceSecondaryIcon?.isHidden = !device.isQuickDropPeer
        progressProgressBar?.startAnimation(nil)
        progressState?.stringValue = "Preparing".localized()
        chosenDevice = device
        
        runAfter(seconds: 0.3) {
            NearbyConnectionManager.shared.startOutgoingTransfer(
                deviceID: device.id!,
                delegate: self,
                urls: self.urls,
                textToSend: self.textToSend,
                preparationFinished: {
                    self.progressState?.stringValue = "Connecting".localized()
                    
                    let timeoutAlert = DispatchWorkItem {
                        if !self.connectionEstablished {
                            AudioManager.playErrorSound()
                            let alert = NSAlert()
                            alert.alertStyle = .critical
                            
                            alert.messageText = "TimeoutTitle".localized()
                            
                            if #available(macOS 15.0, *) {
                                alert.informativeText = "TimeoutDescription".localized()
                                alert.addButton(withTitle: "TimeoutButton".localized())
                                alert.addButton(withTitle: "CloseAlert".localized())
                            } else {
                                alert.informativeText = "TimeoutDescriptionLegacy".localized()
                                alert.addButton(withTitle: "TimeoutButtonLegacy".localized())
                            }
                            
                            alert.beginSheetModal(for: self.view.window!) { response in
                                if #available(macOS 15.0, *), response == .alertFirstButtonReturn {
                                    openPrivacyAndSecuritySettings()
                                }
                            }
                        }
                    }
                    
                    self.timeoutDispatchWorkItem = timeoutAlert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutAlert)
                },
                receiverAuthenticationPolicy: .none
            )
        }
    }
    
    
    private func dismissDelayed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let error = self.lastError {
                self.extensionContext!.cancelRequest(withError: error)
            } else {
                self.extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    
    private func dicoverDevices() {
        
        let bundleIdentifier = "com.leonboettger.neardrop"
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Check if the app is already running
        let isRunning = runningApps.contains { $0.bundleIdentifier == bundleIdentifier }
        
        if !isRunning {
            log("[ShareViewController] Launching main app")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error = error {
                        log("[ShareViewController] Failed to launch application: \(error)")
                    } else {
                        log("[ShareViewController] Application launched successfully")
                    }
                }
            } else {
                log("[ShareViewController] Could not find application with bundle identifier \(bundleIdentifier)")
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NearbyConnectionManager.shared.startDeviceDiscovery()
                self.scheduleAutomaticQrCodeView()
            }
        } else {
            log("Main app is already running")
            NearbyConnectionManager.shared.startDeviceDiscovery()
            scheduleAutomaticQrCodeView()
        }
        
        // Force local network access prompt if not already granted
        let _ = DeviceToDeviceHeuristicScanner.shared.hasLocalNetworkAccess(completion: {_ in })
    }
    
    
    private func scheduleAutomaticQrCodeView() {
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.foundDevices.isEmpty {
                self.openQrCodeView()
            }
        }
    }
}


private func imageForDeviceType(type: RemoteDeviceInfo.DeviceType) -> NSImage {
    let imageName: String
    switch type {
    case .tablet:
        imageName = "com.apple.ipad"
    case .computer:
        imageName = "com.apple.macbookpro-13-unibody"
    default: // also .phone
        imageName = "com.apple.iphone"
    }
    return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(imageName).icns")!
}


extension ShareViewController: NSCollectionViewDataSource {
    
    func numberOfSections(in _: NSCollectionView) -> Int {
        return 1
    }
    
    
    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
        return foundDevices.count
    }
    
    
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "DeviceListCell"), for: indexPath)
        
        guard let collectionViewItem = item as? DeviceListCell else { return item }
        
        let device = foundDevices[indexPath[1]]
        
        collectionViewItem.configure(
            deviceName: getDeviceName(device: device),
            deviceImage: imageForDeviceType(type: device.type),
            showsQuickDropPeerMarker: device.isQuickDropPeer && device.type == .phone
        )
        collectionViewItem.clickHandler = {
            self.selectDevice(device: device)
        }
        
        return collectionViewItem
    }
    
    
    func getDeviceName(device: RemoteDeviceInfo) -> String {
        if let name = device.name, name.count > 1 {
            return name
        }
        
        return "AndroidDevice".localized()
    }
}


fileprivate func openPrivacyAndSecuritySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") else { return }
    NSWorkspace.shared.open(url)
}
