//
//  Model.swift
//  QuickDrop
//
//  Created by Leon Böttger on 28.07.25.
//

import SwiftUI

class SendModel: ObservableObject, OutboundAppDelegate {
    
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
        NearbyConnectionManager.shared.becomeVisible()
        NearbyConnectionManager.shared.addShareExtensionDelegate(self)
    }
    
    func addDevice(device: RemoteDeviceInfo) {
        withAnimation {
            foundDevices.append(device)
        }
    }
    
    func removeDevice(id: String) {
        withAnimation {
            foundDevices.removeAll { $0.id == id }
        }
    }
    
    func connectionWasEstablished(pinCode: String) {
        connectionEstablished = true
        progressState = String(format: "PinCode".localized(), arguments: [pinCode])
        progressValue = 0
    }
    
    func connectionFailed(with error: any Error) {
        
        ErrorAlertHandler.shared.showErrorAlert(for: selectedDevice?.name ?? "?", error: error)
        
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
        progressValue = 0
        selectedDevice = nil
        progressState = "TransferFinished".localized()
    }
    
    func startTransferWithQrCode(device: RemoteDeviceInfo) {
        selectDevice(device: device)
    }
    
    func selectDevice(device: RemoteDeviceInfo) {
        
        // already selected, cancel transfer
        if device == selectedDevice {
            progressValue = 0
            progressState = nil
            selectedDevice = nil
            NearbyConnectionManager.shared.cancelOutgoingTransfer(id: device.id!)
        }
        else {
            progressValue = 0
            progressState = "Connecting".localized()
            selectedDevice = device
            NearbyConnectionManager.shared.startOutgoingTransfer(
                deviceID: device.id!,
                delegate: self,
                urls: urls,
                textToSend: textToSend,
                receiverAuthenticationPolicy: .none
            )
        }
    }
}
