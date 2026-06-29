//
//  Model.swift
//  QuickDrop
//
//  Created by Leon Böttger on 28.07.25.
//

import SwiftUI
#if os(iOS)
import LUI
#endif

class SendModel: ObservableObject, OutboundAppDelegate {
    
    @Published var showQrCodeView: Bool = false
    
    @Published var foundDevices: [RemoteDeviceInfo] = []
    @Published var selectedDevice: RemoteDeviceInfo?
    
    @Published var progressState: String? = nil
    @Published var progressValue: Double? = nil
    
    var urls: [URL] = []
    var textToSend: String? = nil
    
    private var connectionEstablished = false
    private var timeoutDispatchWorkItem: DispatchWorkItem? = nil
    
    
    init() {
        NearbyConnectionManager.shared.startDeviceDiscovery()
        NearbyConnectionManager.shared.addOutboundAppDelegate(self)
    }
    
    
    deinit {
        NearbyConnectionManager.shared.removeOutboundAppDelegate(self)
    }
    
    
    func addDevice(device: RemoteDeviceInfo) {
        withAnimation(.smooth) {
            foundDevices.append(device)
        }
    }
    
    
    func removeDevice(id: String) {
        withAnimation(.smooth) {
            foundDevices.removeAll { $0.id == id }
        }
    }
    
    
    func connectionWasEstablished(pinCode: String) {
        connectionEstablished = true
        progressState = String(format: "PinCode".localized(), arguments: [pinCode])
        progressValue = 0
    }
    
    
    func connectionFailed(error: any Error) {
        
        if let name = selectedDevice?.name {
            errorVibration()
            ErrorAlertHandler.shared.showErrorAlert(for: name, error: error, isQuickDropPeer: selectedDevice?.isQuickDropPeer ?? false)
        }
        
        progressValue = nil
        selectedDevice = nil
    }
    
    
    func transferAccepted() {
        progressState = "Sending".localized()
    }
    
    
    func transferProgress(progress: Double) {
        progressValue = progress
    }
    
    
    func transferFinished() {
        
        #if os(iOS)
        doubleVibration()
        #endif
        
        progressValue = 0
        selectedDevice = nil
        progressState = "TransferFinished".localized()
        
        NearbyConnectionManager.shared.attachments?.closeView?()
        
        #if !EXTENSION
        requestReviewOnce()
        #endif
    }
    
    
    func startTransferWithQrCode(device: RemoteDeviceInfo) {
        showQrCodeView = false
        
        #if EXTENSION
        if let attachments = NearbyConnectionManager.shared.attachments {
            self.selectDevice(device:device, with: attachments)
        }
        #endif
    }
    
    
    func selectDevice(device: RemoteDeviceInfo, with attachments: AttachmentDetails) {
        
        self.urls = attachments.urls
        self.textToSend = attachments.textToSend
        
        // already selected, cancel transfer
        if device == selectedDevice {
            progressValue = 0
            progressState = nil
            selectedDevice = nil
            NearbyConnectionManager.shared.cancelTransfer(id: device.id!)
        }
        else {
            
            progressValue = 0
            progressState = "Preparing".localized()
            selectedDevice = device
            
            runAfter(seconds: 0.3) {
                NearbyConnectionManager.shared.startOutgoingTransfer(
                    deviceID: device.id!,
                    delegate: self,
                    urls: self.urls,
                    textToSend: self.textToSend,
                    receiverAuthenticationPolicy: .none
                )
                self.progressState = "Connecting".localized()
            }
        }
    }
}
