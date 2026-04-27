//
//  ContentView.swift
//  QuickDropiOS
//
//  Created by Leon Böttger on 28.07.25.
//

import SwiftUI
import LUI
import StoreKit

struct ContentView: View {
    
    @ObservedObject var luiSettings = LUISettings.sharedInstance
    @ObservedObject var iapManager = IAPManager.sharedInstance
    
    var body: some View {
        AppRootView(phoneView: {
            DeviceListView()
                .environment(\.sheetActive, isShareExtension())
        }, settingsView: {
            CustomSection(header: iapManager.plusVersionState ? "" : "General", footer: "TrustedDevicesFooterShort") {
                LUIButton {
                    FileManager.default.openDocumentFolder()
                } label: {
                    NavigationLinkLabel(imageName: "folder.fill", text: "BrowseDownloadedFiles")
                }
                
                LUILink(destination: NavigationSubView(header: "TrustedDevices") {
                    TrustedDevicesView()
                }) {
                    NavigationLinkLabel(imageName: "checkmark.shield.fill", text: "ManageTrustedDevices", backgroundColor: .green)
                }
            }
        }, firstIntroductionView: {
            LocalNetworkPermissionView()
        })
    }
}

struct DeviceListView: View {
    
    @State private var qrCode: Image? = nil
    @StateObject var sendModel = SendModel()
    
    #if !EXTENSION
    @StateObject var receiveModel = ReceiveModel(controlPlusScreen: { show in
        log("[DeviceListView] Setting showPlusScreen to \(show)")
        errorVibration()
        if show {
            presentPaywall()
        }
        else {
            OverlayCoverStack.shared.dismissTop(animated: true)
        }
    })
    #endif
    
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.sheetActive) var sheetActive
    @ObservedObject var nearbyConnectionManager = NearbyConnectionManager.shared
    @ObservedObject var settings = Settings.sharedInstance
    
    var body: some View {
        
        let showsLoadingIndicator = nearbyConnectionManager.hasLocalNetworkPermission && nearbyConnectionManager.isConnectedToLocalNetwork
        
        BottomBarView(header: "QuickDrop", navigationBarLayout: isShareExtension() ? .SmallOnlyAlways : .Default, bottomViewHeight: 30) {
            VStack {
                
                let attachments = nearbyConnectionManager.attachments
                
                if nearbyConnectionManager.hasLocalNetworkPermission && attachments == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        
                        FormHeader(name: attachments == nil ? "YouAreVisibleAs".localized() : "YouAreSending".localized())
                        
                        HStack {
                            
                            LUIText(attachments?.shortDescription ?? NearbyConnectionManager.shared.deviceInfo.name ?? "Unknown".localized(), isBold: true)
                                .lineLimit(1)
                            
                            if attachments == nil {
                                Image(systemName: "pencil")
                                    .foregroundColor(.mainColor.opacity(0.5))
                                    .padding(.horizontal, -3)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(sheetActive ? Color.sheetForegroundColor : Color.defaultForegroundColor)
                        .cornerRadius(24)
                        .changeDeviceNameAlert(isEnabled: attachments == nil)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if !nearbyConnectionManager.hasLocalNetworkPermission {
                    NoLocalNetworkAccessAlertView()
                }
                
                var availableDevices: [RemoteDeviceInfo] {
                    var devices = sendModel.foundDevices

                    if let selected = sendModel.selectedDevice,
                       !devices.contains(where: { $0.id == selected.id }) {
                        devices.append(selected)
                    }

                    return devices
                }
                
                if availableDevices.isEmpty {
                    
                    CustomSection(header: "NoDevicesFound") {
                        
                        let hasWifi = nearbyConnectionManager.isConnectedToLocalNetwork
                        
                        HStack(spacing: 12) {
                            Image(systemName: hasWifi ? "arrow.down.circle.fill" : "wifi.slash")
                                .font(.system(size: 30))
                                .foregroundColor(.blue)
                                .background(
                                    Circle()
                                        .fill(Color.white)
                                        .padding(3)
                                        .opacity(hasWifi ? 1 : 0)
                                )
                                .frame(width: 32)
                            
                            LUIText(hasWifi ? "DownloadQuickDropOnPlayStore" : "NoWiFiConnectionDescription")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .animation(.default, value: hasWifi)
                        .padding(.vertical)
                    }
                    
                } else {
                    
                    CustomSection(header: "AvailableDevices") {
                        ForEach(availableDevices) { device in
                            
                            let isSelected = sendModel.selectedDevice == device
                            
                            ZStack {
                                if let attachments = NearbyConnectionManager.shared.attachments {
                                    LUIButton {
                                        lightVibration()
                                        sendModel.selectDevice(device: device, with: attachments)
                                    } label: {
                                        DeviceButtonLabel(device: device, isSelected: isSelected, progress: sendModel.progressState, progressValue: sendModel.progressValue)
                                    }
                                }
                                else {
                                    DeviceFilePickerButton(device: device, isSelected: isSelected, progressState: sendModel.progressState, progressValue: sendModel.progressValue, sendModel: sendModel)
                                }
                            }
                            .animation(.easeInOut, value: sendModel.progressValue)
                            .animation(.easeInOut, value: isSelected)
                        }
                    }
                }
                
                
                if showsLoadingIndicator {
                    HStack(spacing: 8) {
                        Text("SearchingForDevices")
                            .font(.system(size: 14))
                            .foregroundColor(Color.primary.opacity(0.6))
                        
                        LoadingIndicator(size: 12)
                            .opacity(0.75)
                    }
                    .padding(.vertical, 16)
                }
            }
            .frame(maxWidth: 700)
        } bottomView: {
            
            LUIButton {
                qrCode = NearbyConnectionManager.shared.generateQrCodeKey()
                sendModel.showQrCodeView = true
            } label: {
                UnderlineText(label: "DeviceNotShown")
                    .padding()
            }
            .opacity(showsLoadingIndicator ? 1 : 0)
        }
        .luiSheet(isPresented: $sendModel.showQrCodeView, content: {
            NavigationView {
                NavigationSubView(header: "ConnectDevice", navigationBarLayout: .SmallOnlyAlways) {
                    SmallSheetView(type: .sendToDeviceQrCode, dynamicQrCode: qrCode, closeView: {})
                }
                .navigationBarItems(trailing: XButton(action: { sendModel.showQrCodeView = false }))
            }
        })
        .onChange(of: scenePhase) { newValue in
            
            if newValue == .active {
                
                log("[ScenePhase] App became active")
                NearbyConnectionManager.shared.startDeviceDiscovery()
                #if !EXTENSION
                NearbyConnectionManager.shared.becomeVisible()
                
                if Settings.sharedInstance.incomingTransmissionCount > 0 {
                    runAfter(seconds: 0.3) {
                        requestReviewOnce()
                    }
                }
                #endif
            }
            
            if newValue == .background {
                
                log("[ScenePhase] App went to background")
                #if !EXTENSION
                NearbyConnectionManager.shared.becomeInvisible()
                #endif
                NearbyConnectionManager.shared.stopDeviceDiscovery()
            }
        }
        .animation(.smooth, value: nearbyConnectionManager.hasLocalNetworkPermission)
        .animation(.smooth, value: nearbyConnectionManager.isConnectedToLocalNetwork)
        .navigationBarItems(trailing: ZStack {
            if isShareExtension() {
                XButton(action: { NearbyConnectionManager.shared.attachments?.closeView?() })
            }
            else {
                LUISettingsButton()
            }
        })
    }
}


struct DeviceFilePickerButton: View {
    
    let device: RemoteDeviceInfo
    let isSelected: Bool
    let progressState: String?
    let progressValue: Double?
    let sendModel: SendModel
    
    @State private var isPreparing = false
    
    var body: some View {
        SendPickerButton {
            DeviceButtonLabel(device: device, isSelected: isPreparing || isSelected, progress: isPreparing ? "Preparing".localized() : progressState, progressValue: progressValue)
        } onResult: { urls, text in
            isPreparing = false
            sendModel.selectDevice(device: device, with: AttachmentDetails(urls: urls ?? [], textToSend: text, shortDescription: ""))
        } onPrepare: {
            isPreparing = true
        }
    }
}


struct DeviceButtonLabel: View {
    
    let device: RemoteDeviceInfo
    let isSelected: Bool
    let progress: String?
    let progressValue: Double?
    
    var body: some View {
        HStack(spacing: 12) {
            
            let name = device.name ?? "AndroidDevice".localized()
            
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.623, green: 0.659, blue: 0.855),
                                     Color(red: 0.474, green: 0.525, blue: 0.796)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 40, height: 40)
                
                Image(systemName: device.icon)
                    .foregroundColor(.white)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(name)
                        .fontWeight(.medium)
                        .foregroundColor(Color.primary)

                    if device.isQuickDropPeer {
                        Image(.menuBarIcon)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color.primary)
                            .opacity(0.5)
                    }
                }
                
                Text(isSelected ? progress ?? "..." : "Available".localized())
                    .font(.system(size: 12))
                    .foregroundColor(Color.primary.opacity(0.6))
            }
            
            Spacer()
            
            if isSelected, let progress = progressValue {
                PieProgressView(progress: progress, size: 20)
            }
            else {
                Image(systemName: "chevron.right")
                    .foregroundColor(Color.primary.opacity(0.6))
            }
        }
        .padding(.vertical, 13)
    }
}


func isShareExtension() -> Bool {
    #if EXTENSION
    return true
    #else
    return false
    #endif
}


//extension DeviceListView {
//    static var preview: DeviceListView {
//        let model = SendModel()
//        model.foundDevices = [
//            RemoteDeviceInfo(name: "MacBook Pro", type: .computer, id: "macbook-pro-id"),
//            RemoteDeviceInfo(name: "iPhone 14", type: .phone, id: "iphone-14-id"),
//            RemoteDeviceInfo(name: "Samsung Galaxy S21", type: .phone, id: "samsung-galaxy-s21-id")
//        ]
//
//        return DeviceListView(sendModel: model, receiveModel: ReceiveModel())
//    }
//}
//
#Preview {
    NavigationView {
        DeviceListView()
    }
}
