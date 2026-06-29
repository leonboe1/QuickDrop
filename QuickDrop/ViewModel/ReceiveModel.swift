//
//  ReceiveModel.swift
//  QuickDrop
//
//  Created by Leon Böttger on 16.08.25.
//

import SwiftUI
import StoreKit
import LUI
#if os(macOS)
import AppKit
#endif

class ReceiveModel: ObservableObject, InboundAppDelegate {
    
    /// For each connection ID, store the last reported progress value
    private var processes: [String: Double] = [:]
    
#if os(macOS)
    @Published var progress: Double? = nil
    @Published var toastActions: ToastViewAction? = nil
    @Published var consentState: ConsentToastState? = nil
    @Published var activeDeviceName: String? = nil
    @Published var toastIsVisible: Bool = false
    @Published var toastDismissStyle: ToastDismissStyle = .slide
    private var pendingReview = false
    private var toastWindowPending = false
    private var toastWindow: NSWindow?
    private var toastHosting: NSHostingView<QuickDropToastHostView>?
    private var toastRevealTask: DispatchWorkItem?
    private var toastCleanupTask: DispatchWorkItem?
    private let monitor = AllowedWorkMonitor()
#endif
    
    let controlPlusScreen: (Bool) -> Void
    
    
    init(controlPlusScreen: @escaping (Bool) -> Void) {
        self.controlPlusScreen = controlPlusScreen
    
        NearbyConnectionManager.shared.addInboundAppDelegate(self)
        
        #if os(macOS)
        self.monitor.onAllowed = {
            NearbyConnectionManager.shared.becomeVisible()
        }
        self.monitor.onStopped = {
            NearbyConnectionManager.shared.becomeInvisible()
        }
        
        self.monitor.start()
        #else
        NearbyConnectionManager.shared.becomeVisible()
        #endif
    }
    
    
    deinit {
        NearbyConnectionManager.shared.removeInboundAppDelegate(self)
        
        #if os(macOS)
        self.monitor.stop()
        #endif
    }
    
    
    func obtainUserConsent(transfer: TransferMetadata, device: RemoteDeviceInfo) {
        
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        AudioManager.playIncomingFileSound()
        #endif

        let mainMessage = transfer.getDescription(deviceName: device.name ?? "AndroidDevice".localized())
        let pinCodeMessage = transfer.getPinCodeMessage()
        let transferID = transfer.id
    
        let primaryButtonAction = { (trustDevice: Bool) in
            NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: true, trustDevice: trustDevice)
        }

        let secondaryButtonAction = { NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: false, trustDevice: false) }

        #if os(macOS)
        DispatchQueue.main.async {
            if transfer.type == .notificationSync || transfer.type == .clipboardSync {
                self.hideQuickDropToast()
                self.toastActions = nil
                self.progress = nil
                self.consentState = nil
                let senderName = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedSenderName = (senderName?.isEmpty == false) ? senderName! : "AndroidDevice".localized()
                self.activeDeviceName = resolvedSenderName

                let pairingUseCase: PairingUseCase = transfer.type == .clipboardSync ? .clipboardSync : .notificationSync
                let compareMessage = transfer.type == .clipboardSync
                    ? "ClipboardSyncToastQrSubtitle".localized()
                    : "NotificationSyncToastQrSubtitle".localized()
                self.consentState = ConsentToastState(
                    transferID: transferID,
                    pinCodeMessage: "",
                    message: compareMessage,
                    notificationSyncStage: .consent,
                    allowsTrust: false,
                    acceptAction: { [weak self] _ in
                        guard let self else { return }
                        withAnimation {
                            self.consentState = nil
                        }
                        guard let receiverFingerprint = PairingToken.receiverFingerprintHex() else {
                            log("[ReceiveModel] Missing local receiver fingerprint; cannot start notification sync pairing.")
                            secondaryButtonAction()
                            self.hideQuickDropToast(style: .fade)
                            return
                        }
                        let pairingToken = PairingToken.generate()
                        PairingQrSheetManager.shared.open(
                            token: pairingToken,
                            receiverFingerprint: receiverFingerprint,
                            deviceName: resolvedSenderName,
                            useCase: pairingUseCase
                        )
                        NearbyConnectionManager.shared.submitUserConsent(
                            transferID: transferID,
                            accept: true,
                            trustDevice: false,
                            pairingToken: pairingToken
                        )
                        self.hideQuickDropToast(style: .fade)
                    },
                    declineAction: { [weak self] in
                        guard let self else { return }
                        self.consentState = nil
                        secondaryButtonAction()
                        self.hideQuickDropToast(style: .fade)
                    }
                )
                self.showQuickDropToast(for: transferID)
                return
            }

            self.toastActions = nil
            self.progress = nil
            self.activeDeviceName = device.name ?? "AndroidDevice".localized()
            self.consentState = ConsentToastState(
                transferID: transferID,
                pinCodeMessage: pinCodeMessage,
                message: mainMessage,
                notificationSyncStage: nil,
                allowsTrust: transfer.allowsToBeAddedAsTrustedDevice,
                acceptAction: { [weak self] trustDevice in
                    DispatchQueue.main.async {
                        withAnimation {
                            self?.consentState = nil
                        }
                    }
                    primaryButtonAction(trustDevice)
                },
                declineAction: { [weak self] in
                    self?.consentState = nil
                    secondaryButtonAction()
                    self?.hideQuickDropToast()
                }
            )
            self.showQuickDropToast(for: transferID)
        }
        #else
        
        let title = "QuickDrop - \(pinCodeMessage)"
        let primaryButtonTitle = "Accept".localized()
        let secondaryButtonTitle = "Decline".localized()
        
        // iOS
        let alwaysAcceptLabel = transfer.allowsToBeAddedAsTrustedDevice ? "AlwaysAccept".localized() : nil
        ProgressAlert.shared.askForUserPermission(title: title, message: mainMessage, acceptLabel: primaryButtonTitle, acceptAlwaysLabel: alwaysAcceptLabel, rejectLabel: secondaryButtonTitle) { accepted in
            
            switch accepted {
                case .Accept:
                    primaryButtonAction(false)
                case .AcceptAlways:
                    primaryButtonAction(true)
                case .Decline:
                    secondaryButtonAction()
            }
        }
        #endif
    }
    
    
    func obtainedUserConsentAutomatically(transfer: TransferMetadata, device: RemoteDeviceInfo) {
        #if os(macOS)
        if transfer.isClipboardSync {
            return
        }
        #endif
        
        let mainMessage = transfer.getDescription(deviceName: device.name ?? "AndroidDevice".localized())
        
        #if os(macOS)
        
        NSApp.activate(ignoringOtherApps: true)
        AudioManager.playIncomingFileSound()
        DispatchQueue.main.async {
            self.toastActions = nil
            self.progress = nil
            self.activeDeviceName = device.name ?? "AndroidDevice".localized()
            self.consentState = nil
            self.showQuickDropToast(for: transfer.id)
        }
        #else
        // If text is received, nothing is shown, as it is directly inserted into clipboard automatically
        // Therefore, give a feedback dialog in this case
        if transfer.type == .text {
            showAlert(title: "QuickDrop", message: mainMessage)
        }
        #endif
    }
    
    
    func transferProgress(connectionID: String, progress: Double) {
        
        // Update process dictionary
        processes[connectionID] = progress
        
        // Calcualate average value for all ongoing transfers
        let totalProgress = processes.values.reduce(0, +)
        let averageProgress = totalProgress / Double(processes.count)
        
#if os(iOS)
        ProgressAlert.shared.updateProgress(averageProgress, onCancel: {
            NearbyConnectionManager.shared.cancelTransfer(id: connectionID)
        }, completion: {})
        #else
        DispatchQueue.main.async {
            self.toastActions = nil
            self.progress = averageProgress
            self.showQuickDropToast(for: connectionID)
        }
        #endif
    }

    
    func pairingSetupConfirmed() {
        #if os(macOS)
        DispatchQueue.main.async {
            if self.consentState?.notificationSyncStage != nil {
                self.hideQuickDropToast(style: .fade)
            }
            PairingQrSheetManager.shared.close()
        }
        #endif
    }
    
    
    func connectionWasTerminated(connectionID: String, from device: RemoteDeviceInfo?, savedFiles: [URL], wasPlainTextTransfer: Bool, wasClipboardSync: Bool, error: (any Error)?) {
        
        processes.removeValue(forKey: connectionID)
        
        #if os(macOS)
        DispatchQueue.main.async {
            let wasPendingConsent = self.consentState?.transferID == connectionID
            if self.processes.isEmpty {
                self.progress = nil
            }
            if wasPendingConsent {
                self.consentState = nil
                self.toastActions = nil
                self.hideQuickDropToast()
            }
            finishMacTermination(device: device, savedFiles: savedFiles, error: error, wasPendingConsent: wasPendingConsent)
        }
        #else
        if self.processes.isEmpty {
            ProgressAlert.shared.updateProgress(nil, onCancel: {}) {
                finish()
            }
        }
        #endif
        
        func finish() {
            if let error = error {
                if let name = device?.name {
                    
                    #if os(macOS)
                    DispatchQueue.main.async {
                        self.hideQuickDropToast()
                    }
                    #endif

                    controlPlusScreen(false)
                    
                    errorVibration()
                    ErrorAlertHandler.shared.showErrorAlert(for: name, error: error, isQuickDropPeer: device?.isQuickDropPeer ?? false)
                }
            } else {
 
                #if os(iOS)
                doubleVibration()
                if !savedFiles.isEmpty {
                    
                    let hasPhotoOrVideos = PhotoManager.hasPhotosOrVideos(at: savedFiles)
                    let photoSaveAction: (() -> ())? = hasPhotoOrVideos ? {
                        Task {
                            do {
                                try await PhotoManager.saveMediaToPhotoLibrary(from: savedFiles)
                            }
                            catch {
                                showAlert(title: "CouldNotSaveMediaToPhotoLibrary", message: error.localizedDescription)
                            }
                        }
                    } : nil
                    
                    ProgressAlert.shared.presentIncomingTransferDoneAlert(title: "FileTransferCompleted".localized(), message: "FileTransferCompletedMessage".localized(), onImportToPhotos: photoSaveAction)
                }
                
                #endif
                
                let currentCount = Settings.sharedInstance.incomingTransmissionCount
                
                #if os(macOS)
                
                let completionKey: String
                let autoHideDelay: TimeInterval

                if !savedFiles.isEmpty {
                    completionKey = "Saved"
                    autoHideDelay = 10
                } else if wasPlainTextTransfer {
                    completionKey = "CopiedToClipboard"
                    autoHideDelay = 10
                } else {
                    completionKey = "URLOpened"
                    autoHideDelay = 4
                }
                
                if currentCount == 0 {
                    pendingReview = true
                }
                
                let openFilesAction: (() -> ())? = savedFiles.isEmpty ? nil : {
                    log("[SaveFilesManager] Opening \(savedFiles.count) file(s) in Finder.")
                    NSWorkspace.shared.activateFileViewerSelecting(savedFiles)
                    showReviewIfAppropriate(currentTransmissionCount: currentCount)
                }
                
                let hasPhotoOrVideos = PhotoManager.hasPhotosOrVideos(at: savedFiles)
                let importPhotosAction: (()->())? = hasPhotoOrVideos ? {
                    Task {
                        do {
                            try await PhotoManager.saveMediaToPhotoLibrary(from: savedFiles)
                            showReviewIfAppropriate(currentTransmissionCount: currentCount)
                        }
                        catch {
                            DispatchQueue.main.async {
                                let alert = NSAlert()
                                alert.alertStyle = .critical
                                alert.messageText = "CouldNotSaveMediaToPhotoLibrary".localized()
                                alert.informativeText = error.localizedDescription
                                alert.addButton(withTitle: "CloseAlert".localized())
                                
                                alert.runModal()
                            }
                        }
                    }
                } : nil
                
                let closeToastAction = {
                    self.hideQuickDropToast(style: .fade)
                    showReviewIfAppropriate(currentTransmissionCount: currentCount)
                }
                let autoHideAction = {
                    self.hideQuickDropToast()
                    showReviewIfAppropriate(currentTransmissionCount: currentCount)
                }
                
                DispatchQueue.main.async {
                    withAnimation {
                        self.toastActions = ToastViewAction(completionMessageKey: completionKey, autoHideDelay: autoHideDelay, openFilesAction: openFilesAction, importPhotosAction: importPhotosAction, closeToastAction: closeToastAction, autoHideAction: autoHideAction)
                    }
                    
                    // Show received files if wanted
                    if Settings.sharedInstance.openFinderAfterReceiving {
                        self.toastActions?.openFilesAction?()
                    }
                }
                #endif

                Settings.sharedInstance.incomingTransmissionCount = currentCount + 1
                log("[ReceiveModel] Successful transmission. Current count: \(currentCount)")
            }
        }
        
        
        #if os(macOS)
        func finishMacTermination(device: RemoteDeviceInfo?, savedFiles: [URL], error: (any Error)?, wasPendingConsent: Bool) {
            if wasPendingConsent {
                return
            }
            if wasClipboardSync && error == nil {
                return
            }

            if let error = error {
                if let name = device?.name {
                    self.hideQuickDropToast()

                    controlPlusScreen(false)

                    errorVibration()
                    ErrorAlertHandler.shared.showErrorAlert(for: name, error: error, isQuickDropPeer: device?.isQuickDropPeer ?? false)
                }
                return
            }

            let currentCount = Settings.sharedInstance.incomingTransmissionCount
            let completionKey: String
            let autoHideDelay: TimeInterval

            if !savedFiles.isEmpty {
                completionKey = "Saved"
                autoHideDelay = 10
            } else if wasPlainTextTransfer {
                completionKey = "CopiedToClipboard"
                autoHideDelay = 10
            } else {
                completionKey = "URLOpened"
                autoHideDelay = 4
            }

            if currentCount == 0 {
                pendingReview = true
            }

            let openFilesAction: (() -> ())? = savedFiles.isEmpty ? nil : {
                log("[SaveFilesManager] Opening \(savedFiles.count) file(s) in Finder.")
                NSWorkspace.shared.activateFileViewerSelecting(savedFiles)
                showReviewIfAppropriate(currentTransmissionCount: currentCount)
            }

            let hasPhotoOrVideos = PhotoManager.hasPhotosOrVideos(at: savedFiles)
            let importPhotosAction: (()->())? = hasPhotoOrVideos ? {
                Task {
                    do {
                        try await PhotoManager.saveMediaToPhotoLibrary(from: savedFiles)
                        showReviewIfAppropriate(currentTransmissionCount: currentCount)
                    }
                    catch {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.alertStyle = .critical
                            alert.messageText = "CouldNotSaveMediaToPhotoLibrary".localized()
                            alert.informativeText = error.localizedDescription
                            alert.addButton(withTitle: "CloseAlert".localized())

                            alert.runModal()
                        }
                    }
                }
            } : nil

            let closeToastAction = {
                self.hideQuickDropToast(style: .fade)
                showReviewIfAppropriate(currentTransmissionCount: currentCount)
            }
            let autoHideAction = {
                self.hideQuickDropToast()
                showReviewIfAppropriate(currentTransmissionCount: currentCount)
            }

            withAnimation {
                self.toastActions = ToastViewAction(completionMessageKey: completionKey, autoHideDelay: autoHideDelay, openFilesAction: openFilesAction, importPhotosAction: importPhotosAction, closeToastAction: closeToastAction, autoHideAction: autoHideAction)
            }

            // Show received files if wanted
            if Settings.sharedInstance.openFinderAfterReceiving {
                self.toastActions?.openFilesAction?()
            }

            Settings.sharedInstance.incomingTransmissionCount = currentCount + 1
            log("[ReceiveModel] Successful transmission. Current count: \(currentCount)")
        }

        func showReviewIfAppropriate(currentTransmissionCount: Int) {
            if pendingReview {
                // Dont request review again
                pendingReview = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    SKStoreReviewController.requestReview()
                }
            }
        }
        #endif
    }
    
    
    func showPlusScreen() {
        DispatchQueue.main.async {
#if os(macOS)
            self.consentState = nil
            self.toastActions = nil
            self.progress = nil
            self.hideQuickDropToast()
#endif
            self.controlPlusScreen(true)
        }
    }
    
    
    // MARK: - macOS Progress Overlay
    
    #if os(macOS)
    private func scheduleToastReveal(for window: NSWindow) {
        toastRevealTask?.cancel()
        toastRevealTask = nil
        
        let revealTask = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            guard self.toastWindow === window else { return }
            self.toastIsVisible = true
            self.toastRevealTask = nil
        }
        
        toastRevealTask = revealTask
        // Reveal on the next run-loop tick to avoid pop-in without timer jitter.
        DispatchQueue.main.async(execute: revealTask)
    }
    
    func showQuickDropToast(for connectionID: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.showQuickDropToast(for: connectionID)
            }
            return
        }

        // If a previous hide is still waiting for cleanup, keep the toast alive for this new request.
        toastCleanupTask?.cancel()
        toastCleanupTask = nil
        toastRevealTask?.cancel()
        toastRevealTask = nil

        if let window = toastWindow {
            toastDismissStyle = .slide
            
            if !toastIsVisible {
                window.makeKeyAndOrderFront(nil)
                scheduleToastReveal(for: window)
            }
            return
        }

        guard !toastWindowPending else { return }
        toastWindowPending = true

        guard toastWindow == nil else {
            toastWindowPending = false
            return
        }

        toastIsVisible = false
        toastDismissStyle = .slide

        let contentView = QuickDropToastHostView(
            receiveModel: self,
            onCancel: { [weak self] in
                guard let self else { return }
                NearbyConnectionManager.shared.cancelAllIncomingConnections()

                self.processes.removeAll()
                self.progress = nil
                self.toastActions = nil
                self.consentState = nil
                self.hideQuickDropToast(style: .fade)
            }
        )

        let hostingView = NSHostingView(rootView: contentView)

        // Prefer the screen under the mouse, then the key window’s screen, then main
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main

        guard let screen else {
            toastWindowPending = false
            return
        }

        let frame = screen.frame
        let visible = screen.visibleFrame

        let marginX: CGFloat = 20
        let marginFromTop: CGFloat = 20

        // If the menu bar is auto-hidden, visible.maxY == frame.maxY; subtract the status bar thickness to stay clear
        let menuBarHidden = abs(frame.maxY - visible.maxY) < 0.5
        let extraTopInset = menuBarHidden ? NSStatusBar.system.thickness : 0

        let targetX = visible.maxX - toastViewSize.width - marginX
        let targetY = visible.maxY - toastViewSize.height - marginFromTop - extraTopInset
        let windowWidth = visible.maxX - targetX
        let targetFrame = CGRect(x: targetX, y: targetY, width: windowWidth, height: toastViewSize.height)
        
        // Expand the borderless window so SwiftUI shadow can render without clipping.
        // Keep the toast anchored at the same screen position by offsetting hostingView
        // inside a clear container view.
        let shadowInsetLeft: CGFloat = 22
        let shadowInsetTop: CGFloat = 18
        let shadowInsetBottom: CGFloat = 24
        let windowFrame = CGRect(
            x: targetFrame.minX - shadowInsetLeft,
            y: targetFrame.minY - shadowInsetBottom,
            width: targetFrame.width + shadowInsetLeft,
            height: targetFrame.height + shadowInsetTop + shadowInsetBottom
        )
        
        let containerView = NSView(frame: CGRect(origin: .zero, size: windowFrame.size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        
        hostingView.frame = CGRect(
            x: shadowInsetLeft,
            y: shadowInsetBottom,
            width: targetFrame.width,
            height: targetFrame.height
        )
        containerView.addSubview(hostingView)

        let window = NSWindow(contentRect: windowFrame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Use SwiftUI shadow on the toast view itself. On macOS 12, window
        // shadow can reveal a rectangular artifact in transparent trailing space.
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = containerView
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)

        toastWindow = window
        toastHosting = hostingView
        toastWindowPending = false
        scheduleToastReveal(for: window)
    }


    func hideQuickDropToast(style: ToastDismissStyle = .fade) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.hideQuickDropToast(style: style)
            }
            return
        }

        toastCleanupTask?.cancel()
        toastCleanupTask = nil
        toastRevealTask?.cancel()
        toastRevealTask = nil

        guard let window = toastWindow else {
            self.toastWindow = nil
            self.toastHosting = nil
            self.toastActions = nil
            self.consentState = nil
            self.toastWindowPending = false
            return
        }

        self.toastDismissStyle = style
        self.toastIsVisible = false

        let cleanupDelay: TimeInterval = (style == .slide) ? 0.5 : 0.3
        let cleanupTask = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            self.toastWindow = nil
            self.toastHosting = nil
            self.toastActions = nil
            self.consentState = nil
            self.activeDeviceName = nil
            self.toastWindowPending = false
            self.toastCleanupTask = nil
            self.toastRevealTask = nil
        }
        toastCleanupTask = cleanupTask

        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay, execute: cleanupTask)
    }
    
    
    struct ToastViewAction {
        let completionMessageKey: String
        let autoHideDelay: TimeInterval
        let openFilesAction: (() -> ())?
        let importPhotosAction: (() -> ())?
        let closeToastAction: () -> ()
        let autoHideAction: () -> ()
    }


    enum ToastDismissStyle {
        case slide
        case fade
    }
    

    struct ConsentToastState {
        enum NotificationSyncStage {
            case consent
            case pin
        }

        let transferID: String
        let pinCodeMessage: String
        let message: String
        let notificationSyncStage: NotificationSyncStage?
        let allowsTrust: Bool
        let acceptAction: (Bool) -> ()
        let declineAction: () -> ()
    }
    #endif
}
