//
//  NearbyConnectionManager.swift
//  QuickDrop
//
//  Created by Grishka on 08.04.2023.
//

#if os(iOS)
import UIKit
import DeviceKit
#endif

import Foundation
import Network
import System
import SwiftECC
import CryptoKit
import SwiftUI
import QRCode
import LUI

public class NearbyConnectionManager: NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, OutboundNearbyConnectionDelegate, ObservableObject {
    
    // MARK: Private Properties
    
    #if !EXTENSION
    private let sleepManager = SleepManager.shared
    #endif
    private var tcpListener: NWListener
    private var mdnsServices: [NetService] = []
    private var incomingConnections: [String: InboundNearbyConnection] = [:]
    private var foundServices: [String: FoundServiceInfo] = [:]
    private var outboundAppDelegates: [OutboundAppDelegate] = []
    private var inboundAppDelegates: [InboundAppDelegate] = []
    private var outgoingTransfers: [String: OutgoingTransferInfo] = [:]
    private var pendingOutgoingTransferPreparations: [String: UUID] = [:]
    private var startedDeviceDiscovery = false
    private var startedAdvertising = false { didSet { informAboutStatus() }}
    private var browsers: [NWBrowser] = []
    private let deviceNameResolver = NearbyDeviceNameResolver()
    private let serviceTypes = ["_FC9F5ED42C8A._tcp."]
    private var qrCodePrivateKey: ECPrivateKey?
    private var qrCodeAdvertisingToken: Data?
    private var qrCodeNameEncryptionKey: SymmetricKey?
    private let hasConnectionMonitor = NWPathMonitor()
    private let connectionMonitorQueue = DispatchQueue(label: "NetworkConnectionMonitorQueue")
    private var securityScopeUrl: URL?
    private static let customDeviceNameKey = "com.leonboettger.quickdrop.deviceName"
    private var defaultPort: NWEndpoint.Port = 50362
    private let txtKeyEndpointInfo = "n"
    private let txtQuickDropCapabilities = "qd_caps"
    private let txtQuickDropDeviceKeyFingerprint = "qd_kid"
    private let notificationSyncCapabilityToken = "nsync1"
    private let unnamedAndroidFallbackDeviceName = "AndroidDevice".localized()
    
    
    // MARK: Shared Instance
    
    public static let shared = NearbyConnectionManager()
    
    
    // MARK: Published State
    
    @Published var attachments: AttachmentDetails? = nil
    @Published var hasLocalNetworkPermission = true
    @Published var isConnectedToLocalNetwork = true { didSet { informAboutStatus() }}
    @Published var deviceInfo: EndpointInfo
    
    
    // MARK: Public Properties
    
    public var endpointID: [UInt8] = getEndpointID(forceRegeneration: false)
    public var connectionUpdateCallback: (Bool) -> Void = { _ in } { didSet { informAboutStatus() }}
    public var changedDeviceNameCallback: () -> Void = { }
    
    
    // MARK: Initializers
    
    override init() {
        self.deviceInfo = Self.getEndpointInfo()
        tcpListener = try! NWListener(using: NWParameters(tls: .none))
        
        super.init()
        
        hasConnectionMonitor.pathUpdateHandler = { path in
            
            #if os(macOS)
            // On Mac, the local network is available as long as the path is satisfied, since Macs do not have cellular modems
            let isConnected = path.status == .satisfied
            #else
            // On iPhone and iPad, the local network is only available using Wi-Fi or Ethernet
            let isConnected = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            #endif
            
            DispatchQueue.main.async {
                if isConnected {
                    log("[NearbyConnectionManager] Connected to local network.")
                } else {
                    log("[NearbyConnectionManager] Local network lost.")
                }
                self.isConnectedToLocalNetwork = isConnected
            }
        }
        
        hasConnectionMonitor.start(queue: connectionMonitorQueue)
        
        
        // remove old temp directory
        let tempPath = FileManager.default.temporaryDirectory
        let fileManager = FileManager.default

         do {
             let contents = try fileManager.contentsOfDirectory(at: tempPath, includingPropertiesForKeys: nil)
             
             var didSomething = false
             
             for item in contents {
                 didSomething = true
                 try fileManager.removeItem(at: item)
             }
             
             if didSomething {
                 log("[SaveFilesManager] Temporary directory cleared.")
             }
         } catch {
             log("[SaveFilesManager] Failed to list contents of temp directory: \(error)")
         }
    }
    
    
    // MARK: Deinitializer
    
    deinit {
        self.stopAccessingSaveDirectory()
    }
    
    
    public static func getCustomDeviceName() -> String? {
        let storedName = AppGroup.appGroupUD.string(forKey: Self.customDeviceNameKey)
        
        guard let name = storedName, !name.isEmpty else {
            return nil
        }
        
        return name
    }
    
    
    public func setCustomDeviceName(to newName: String) {
        AppGroup.appGroupUD.setValue(newName, forKey: Self.customDeviceNameKey)
        
        self.deviceInfo = Self.getEndpointInfo()
        changedDeviceNameCallback()
        
        if startedAdvertising {
            self.becomeInvisible()
            
            runAfter(seconds: 0.5) {
                self.becomeVisible()
            }
        }
    }
    
    
    private static func getEndpointInfo() -> EndpointInfo {
        
        let deviceType = isMac() ? RemoteDeviceInfo.DeviceType.computer : (isiPadOrMac() ? .tablet : .phone)
        
        if let customName = getCustomDeviceName() {
            return EndpointInfo(name: String(customName), deviceType: deviceType)
        }
        
        #if os(macOS)
        return EndpointInfo(name: String((Host.current().localizedName ?? "Mac")), deviceType: deviceType)
        #else
        return EndpointInfo(name: String(Device.current.description.withoutBracketedContent), deviceType: deviceType)
        #endif
    }
    
    
    public func becomeVisible(randomPort: Bool = false) {
        if startedAdvertising {
            log("[NearbyConnectionManager] Already advertising, skipping")
            return
        }
        
        log("[NearbyConnectionManager] Becoming visible")
        let parameters = NWParameters(tls: .none)
        
        do {
            if randomPort {
                self.tcpListener = try NWListener(using: parameters)
            } else {
                self.tcpListener = try NWListener(using: parameters, on: defaultPort)
            }
        }
        catch {
            log("[NearbyConnectionManager] Error starting TCP listener: \(error). Trying with random port.")
            
            runAfter(seconds: 1) {
                self.becomeVisible(randomPort: true)
            }
            
            return
        }
        
        startedAdvertising = true
        
        tcpListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("[NearbyConnectionManager] Listener ready")
                self.initMDNS(forceIDRegeneration: randomPort)
                
                if let port = self.tcpListener.port, port != self.defaultPort {
                    log("[NearbyConnectionManager] Updated default port to \(port)")
                    self.defaultPort = port
                }
                
            case .failed(let error):
                log("[NearbyConnectionManager] Listener failed: \(error)")
                self.becomeInvisible()
                
                runAfter(seconds: 1) {
                    if case .posix(let posixError) = error,
                       posixError == .EADDRINUSE {
                        self.becomeVisible(randomPort: true)
                    }
                    else {
                        self.becomeVisible()
                    }
                }
                
            case .cancelled:
                log("[NearbyConnectionManager] Listener cancelled")
                
            case .setup:
                log("[NearbyConnectionManager] Listener setup")
                
            case .waiting(let state):
                log("[NearbyConnectionManager] Listener waiting: \(state)")
                
            @unknown default:
                log("[NearbyConnectionManager] Listener unknown state")
            }
        }
        
        tcpListener.newConnectionHandler = { (connection: NWConnection) in
            let id = UUID().uuidString
            let conn = InboundNearbyConnection(connection: connection, id: id)
            self.incomingConnections[id] = conn
            conn.delegate = self
            conn.start()
        }
        
        tcpListener.start(queue: .global(qos: .utility))
    }
    
    
    public func becomeInvisible() {
        if !startedAdvertising {
            log("[NearbyConnectionManager] Already invisible, ignoring becomeInvisible()")
            return
        }
        
        log("[NearbyConnectionManager] Becoming invisible")
        
        startedAdvertising = false
        self.stopMDNS()
        tcpListener.cancel()
    }
    
    
    private static func getEndpointID(forceRegeneration: Bool) -> [UInt8] {
        
        // Try to retrieve from UserDefaults
        if !forceRegeneration,
           let savedString = Settings.sharedInstance.endpointID,
           let savedData = savedString.data(using: .utf8) {
            log("[NearbyConnectionManager] Using cached endpoint ID: \(savedString)")
            return [UInt8](savedData)
        }
        
        // Generate a new random ID
        var id: [UInt8] = []
        let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".compactMap { UInt8($0.asciiValue!) }
        for _ in 0 ..< 4 {
            id.append(alphabet[Int.random(in: 0 ..< alphabet.count)])
        }
        
        // Save to UserDefaults as String
        let idString = String(bytes: id, encoding: .utf8) ?? ""
        Settings.sharedInstance.endpointID = idString
        log("[NearbyConnectionManager] Storing new endpoint ID: \(idString) ======================================")
        
        return id
    }
    
    
    private func initMDNS(forceIDRegeneration: Bool) {
        
        self.endpointID = Self.getEndpointID(forceRegeneration: forceIDRegeneration)
        
        let nameBytes: [UInt8] = [
            0x23, // PCP
            endpointID[0], endpointID[1], endpointID[2], endpointID[3],
            0xFC, 0x9F, 0x5E, // Service ID hash
            0, 0,
        ]
        
        let name = Data(nameBytes).urlSafeBase64EncodedString()
        let port = Int32(tcpListener.port!.rawValue)
        
        mdnsServices = serviceTypes.map { serviceType in
            let service = NetService(domain: "", type: serviceType, name: name, port: port)
            service.delegate = self
            var txtRecord: [String: Data] = [
                txtKeyEndpointInfo: deviceInfo.serialize().urlSafeBase64EncodedString().data(using: .utf8)!,
            ]
            if let keyFingerprint = notificationSyncKeyFingerprintHex() {
                txtRecord[txtQuickDropDeviceKeyFingerprint] = Data(keyFingerprint.utf8)
            }
            #if os(macOS)
            txtRecord[txtQuickDropCapabilities] = Data(notificationSyncCapabilityToken.utf8)
            #endif
            service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
            service.publish()
            return service
        }
    }
    

    private func notificationSyncKeyFingerprintHex() -> String? {
        guard let keyID = IdentityManager.shared.getPublicKey()?.toGenericPublicKey().id() else {
            return nil
        }
        return keyID.hex.lowercased()
    }
    
    
    private func stopMDNS() {
        // Gracefully stop each published service
        for service in mdnsServices {
            service.stop()
        }
        mdnsServices.removeAll()
    }
    
    
    func obtainUserConsent(transfer: TransferMetadata, device: RemoteDeviceInfo, connection _: InboundNearbyConnection) {
        inboundAppDelegates.forEach { delegate in
            delegate.obtainUserConsent(transfer: transfer, device: device)
        }
    }
    
    
    func obtainedUserConsentAutomatically(transfer: TransferMetadata, device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
        inboundAppDelegates.forEach { delegate in
            delegate.obtainedUserConsentAutomatically(transfer: transfer, device: device)
        }
    }
    
    
    func connectionWasTerminated(connection: InboundNearbyConnection, savedFiles: [URL], error: Error?) {
        incomingConnections.removeValue(forKey: connection.id)

        // Control transfers suppress normal success callbacks, but
        // still forward failures so pending consent/error UI can be cleaned up.
        if connection.isControlTransfer, error == nil {
            return
        }

        if !connection.wasUserRejected {
            inboundAppDelegates.forEach { delegate in
                delegate.connectionWasTerminated(connectionID: connection.id, from: connection.remoteDeviceInfo, savedFiles: savedFiles, wasPlainTextTransfer: connection.isPlainTextTransfer, error: error)
            }
        }
    }

    func notificationSyncSetupConfirmed(connection _: InboundNearbyConnection) {
        inboundAppDelegates.forEach { delegate in
            delegate.notificationSyncSetupConfirmed()
        }
    }
    
    
    func showPlusScreen() {
        inboundAppDelegates.forEach { delegate in
            delegate.showPlusScreen()
        }
    }
    
    
    func updatedTransferProgress(connection: InboundNearbyConnection, progress: Double) {
        inboundAppDelegates.forEach { delegate in
            delegate.transferProgress(connectionID: connection.id, progress: progress)
        }
    }
    
    
    public func submitUserConsent(
        transferID: String,
        accept: Bool,
        trustDevice: Bool,
        pairingToken: String? = nil
    ) {
        guard let conn = incomingConnections[transferID] else { return }
        
        log("[NearbyConnectionManager] Submitting user consent for transfer \(transferID), accepted: \(accept)")
        conn.submitUserConsent(accepted: accept, trustDevice: trustDevice, pairingToken: pairingToken)
    }
    
    
    public func startDeviceDiscovery() {
        
        if !startedDeviceDiscovery {
            startedDeviceDiscovery = true
            foundServices.removeAll()
            
            log("[NearbyConnectionManager] Starting device discovery")
            
            if browsers.isEmpty {
                for type in serviceTypes {
                    log("[NearbyConnectionManager] Starting browser for type \(type)")
                    
                    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
                    browser.browseResultsChangedHandler = { _, changes in
                        for change in changes {
                            switch change {
                            case let .added(res):
                                self.addFoundDevice(service: res)
                            case let .removed(res):
                                self.removeFoundDevice(service: res)
                            default:
                                log("[NearbyConnectionManager] Ignoring change \(change)")
                            }
                        }
                    }
                    
                    browser.stateUpdateHandler = { newState in
                        switch newState {
                        case .failed(let error):
                            log("[NearbyConnectionManager] Browser failed: \(error)")
                        case .ready:
                            log("[NearbyConnectionManager] Browser ready")
                            self.hasLocalNetworkPermission = true
                        case .waiting(let error):
                            log("[NearbyConnectionManager] Browser waiting: \(error)")
                            
                            if error == NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))  {
                                log("[NearbyConnectionManager] Local network access not granted.")
                                self.hasLocalNetworkPermission = false
                            }
                        default:
                            break
                        }
                    }
                    
                    browser.start(queue: .main)
                    browsers.append(browser)
                }
            }
        }
    }
    
    
    public func stopDeviceDiscovery() {
        if startedDeviceDiscovery {
            
            log("[NearbyConnectionManager] Stopping device discovery")
            
            for browser in browsers {
                browser.cancel()
            }
            
            browsers.removeAll()
            startedDeviceDiscovery = false
            deviceNameResolver.cancelAll()
            
            for delegate in outboundAppDelegates {
                
                foundServices.values.forEach { service in
                    guard let device = service.device, let id = device.id else { return }
                    delegate.removeDevice(id: id)
                }
            }
        }
    }
    
    
    public func addOutboundAppDelegate(_ delegate: OutboundAppDelegate) {
        outboundAppDelegates.append(delegate)
        for service in foundServices.values {
            guard let device = service.device else { continue }
            delegate.addDevice(device: device)
        }
    }
    
    
    public func addInboundAppDelegate(_ delegate: InboundAppDelegate) {
        inboundAppDelegates.append(delegate)
    }
    
    
    public func removeOutboundAppDelegate(_ delegate: OutboundAppDelegate) {
        outboundAppDelegates.removeAll(where: { $0 === delegate })
    }
    
    public func removeInboundAppDelegate(_ delegate: InboundAppDelegate) {
        inboundAppDelegates.removeAll(where: { $0 === delegate })
    }
    
    
    public func cancelTransfer(id: String) {
        
        if let transfer = incomingConnections[id] {
            transfer.cancel()
        }
        pendingOutgoingTransferPreparations.removeValue(forKey: id)
        if let info = outgoingTransfers[id] {
            info.connection.cancel()
        }
    }

    public func cancelAllIncomingConnections() {
        let incomingTransfers = Array(incomingConnections.values)
        for transfer in incomingTransfers {
            transfer.cancel()
        }
    }

    private func endpointID(for service: NWBrowser.Result) -> String? {
        guard case let NWEndpoint.service(name: serviceName, type: _, domain: _, interface: _) = service.endpoint else { return nil }
        guard let nameData = Data.dataFromUrlSafeBase64(serviceName) else { return nil }
        guard nameData.count >= 10 else { return nil }
        let pcp = nameData[0]
        guard pcp == 0x23 else { return nil }
        let endpointID = String(data: nameData.subdata(in: 1 ..< 5), encoding: .ascii)!
        let serviceIDHash = nameData.subdata(in: 5 ..< 8)
        guard serviceIDHash == Data([0xFC, 0x9F, 0x5E]) else { return nil }
        return endpointID
    }
    
    
    private func addFoundDevice(service: NWBrowser.Result) {
        log("[NearbyConnectionManager] Found Service \(service)")
        for interface in service.interfaces {
            if case .loopback = interface.type {
                return
            }
        }
        guard let endpointID = endpointID(for: service) else { return }
        var foundService = FoundServiceInfo(service: service)
        
        guard case let NWBrowser.Result.Metadata.bonjour(txtRecord) = service.metadata else { return }
        guard let endpointInfoEncoded = txtRecord.dictionary[txtKeyEndpointInfo] else { return }
        guard let endpointInfoData = Data.dataFromUrlSafeBase64(endpointInfoEncoded) else { return }
        let parsedEndpointInfo = EndpointInfo(data: endpointInfoData)
        var endpointInfo = parsedEndpointInfo
            ?? EndpointInfo(name: unnamedAndroidFallbackDeviceName, deviceType: .unknown)
        let isQuickDropPeer = txtRecord.dictionary[txtQuickDropDeviceKeyFingerprint] != nil
        let needsDeviceNameLookup = deviceNameResolver.needsLookup(for: parsedEndpointInfo)
        if needsDeviceNameLookup {
            endpointInfo.name = unnamedAndroidFallbackDeviceName
        }
        let deviceInfo = addFoundDevice(
            foundService: &foundService,
            endpointInfo: endpointInfo,
            endpointID: endpointID,
            isQuickDropPeer: isQuickDropPeer
        )

        if needsDeviceNameLookup {
            deviceNameResolver.resolveName(for: service, endpointID: endpointID) { [weak self] deviceName in
                guard let self else { return }
                guard self.foundServices[endpointID]?.device?.name == self.unnamedAndroidFallbackDeviceName else { return }

                var resolvedEndpointInfo = endpointInfo
                resolvedEndpointInfo.name = deviceName
                var resolvedFoundService = FoundServiceInfo(service: service)
                _ = self.addFoundDevice(
                    foundService: &resolvedFoundService,
                    endpointInfo: resolvedEndpointInfo,
                    endpointID: endpointID,
                    isQuickDropPeer: isQuickDropPeer
                )
            }
        }
        else {
            deviceNameResolver.cancelLookup(for: endpointID)
        }
        
        if let qrData = endpointInfo.qrCodeData, let qrCodeAdvertisingToken = qrCodeAdvertisingToken, let qrCodeNameEncryptionKey = qrCodeNameEncryptionKey {
            
            log("[NearbyConnectionManager] Device has QR data: \(qrData.base64EncodedString()), advertising token is \(qrCodeAdvertisingToken.base64EncodedString())")
            
            if qrData == qrCodeAdvertisingToken {
                for delegate in outboundAppDelegates {
                    delegate.startTransferWithQrCode(device: deviceInfo)
                }
            }
            else if qrData.count > 28 {
                do {
                    let box = try AES.GCM.SealedBox(combined: qrData)
                    let decryptedName = try AES.GCM.open(box, using: qrCodeNameEncryptionKey, authenticating: qrCodeAdvertisingToken)
                    guard let name = String.init(data: decryptedName, encoding: .utf8) else { return }
                    endpointInfo.name = name
                    let deviceInfo = addFoundDevice(
                        foundService: &foundService,
                        endpointInfo: endpointInfo,
                        endpointID: endpointID,
                        isQuickDropPeer: isQuickDropPeer
                    )
                    for delegate in outboundAppDelegates {
                        delegate.startTransferWithQrCode(device: deviceInfo)
                    }
                } catch {
                    log("[NearbyConnectionManager] Error decrypting QR code data of an invisible device: \(error)")
                }
            }
        }
    }
    
    
    private func addFoundDevice(
        foundService: inout FoundServiceInfo,
        endpointInfo: EndpointInfo,
        endpointID: String,
        isQuickDropPeer: Bool = false
    ) -> RemoteDeviceInfo {
        let hadPreviousDevice = foundServices[endpointID]?.device != nil
        let deviceInfo = RemoteDeviceInfo(
            info: endpointInfo,
            id: endpointID,
            isQuickDropPeer: isQuickDropPeer
        )
        foundService.device = deviceInfo
        foundServices[endpointID] = foundService
        
        if hadPreviousDevice {
            for delegate in outboundAppDelegates {
                delegate.removeDevice(id: endpointID)
            }
        }
        
        for delegate in outboundAppDelegates {
            delegate.addDevice(device: deviceInfo)
        }
        
        return deviceInfo
    }
    
    
    private func removeFoundDevice(service: NWBrowser.Result) {
        guard let endpointID = endpointID(for: service) else { return }
        deviceNameResolver.cancelLookup(for: endpointID)
        guard let _ = foundServices.removeValue(forKey: endpointID) else { return }
        for delegate in outboundAppDelegates {
            delegate.removeDevice(id: endpointID)
        }
    }
    
    
    public func generateQrCodeKey() -> Image? {
        
        log("[NearbyConnectionManager] Generating new QR code key")
        
        let domain = Domain.instance(curve: .EC256r1)
        let (pubKey, privKey) = domain.makeKeyPair()
        
        qrCodePrivateKey = privKey
        
        var keyData = Data()
        keyData.append(contentsOf: [0, 0, 2])
        keyData.append(Data(pubKey.w.x.asSignedBytes()).ensureLength(length: 32))
        
        let ikm = SymmetricKey(data: keyData)
        
        qrCodeAdvertisingToken = HKDF.deriveKey(ikm: ikm, salt: Data(), info: "advertisingContext".data(using: .utf8)!, outputLength: 16).data()
        qrCodeNameEncryptionKey = HKDF.deriveKey(ikm: ikm, salt: Data(), info: "encryptionKey".data(using: .utf8)!, outputLength: 16)
        
        do {
            let qrKey = keyData.urlSafeBase64EncodedString()
            let qrCodeImage = try QRCode.build
                .text("https://quickshare.google/qrcode#key=\(qrKey)")
                .backgroundColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0))
                .quietZonePixelCount(3)
                .onPixels.shape(.circle())
                .eye.shape(.squircle())
                .errorCorrection(.low)
                .generate
                .image(dimension: 1000)
            
            return Image(decorative: qrCodeImage, scale: 1.0, orientation: .up)
        }
        catch {
            log("Error generating QR code: \(error)")
        }
        
        return nil
    }
    
    
    public func startOutgoingTransfer(
        deviceID: String,
        delegate: OutboundAppDelegate,
        urls: [URL],
        textToSend: String?,
        preparationFinished: (() -> Void)? = nil
    ) {
        log("Starting outgoing transfer to \(deviceID)")
        guard foundServices[deviceID] != nil else { return }

        let preparationID = UUID()
        pendingOutgoingTransferPreparations[deviceID] = preparationID

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak delegate] in
            guard let self else { return }

            do {
                let localUrls = try self.saveFilesToTemp(urls: urls)

                DispatchQueue.main.async {
                    guard let info = self.foundServices[deviceID],
                          self.pendingOutgoingTransferPreparations[deviceID] == preparationID else {
                        return
                    }

                    self.pendingOutgoingTransferPreparations.removeValue(forKey: deviceID)
                    guard let delegate else { return }

                    preparationFinished?()

                    let tcp = NWProtocolTCP.Options()
                    tcp.noDelay = true
                    let nwconn = NWConnection(to: info.service.endpoint, using: NWParameters(tls: .none, tcp: tcp))

                    let conn = OutboundNearbyConnection(connection: nwconn, id: deviceID, urlsToSend: localUrls, textToSend: textToSend)
                    conn.delegate = self
                    conn.qrCodePrivateKey = self.qrCodePrivateKey

                    let transfer = OutgoingTransferInfo(service: info.service, device: info.device!, connection: conn, delegate: delegate)
                    self.outgoingTransfers[deviceID] = transfer
                    conn.start()
                }
            } catch {
                log("[NearbyConnectionManager] Error storing URLs: \(error)")
                DispatchQueue.main.async {
                    guard self.pendingOutgoingTransferPreparations[deviceID] == preparationID else {
                        return
                    }

                    self.pendingOutgoingTransferPreparations.removeValue(forKey: deviceID)
                    self.outboundAppDelegates.forEach { delegate in
                        delegate.connectionFailed(error: error)
                    }
                }
            }
        }
    }
    
    
    func connectionWasEstablished(connection: OutboundNearbyConnection) {
        guard let transfer = outgoingTransfers[connection.id] else { return }
        DispatchQueue.main.async {
            transfer.delegate.connectionWasEstablished(pinCode: connection.pinCode!)
        }
    }
    
    
    func transferAccepted(connection: OutboundNearbyConnection) {
        guard let transfer = outgoingTransfers[connection.id] else { return }
        DispatchQueue.main.async {
            transfer.delegate.transferAccepted()
        }
    }
    
    
    func updatedTransferProgress(connection: OutboundNearbyConnection, progress: Double) {
        guard let transfer = outgoingTransfers[connection.id] else { return }
        DispatchQueue.main.async {
            transfer.delegate.transferProgress(progress: progress)
        }
    }
    
    
    func failedWithError(connection: OutboundNearbyConnection, error: Error) {
        guard let transfer = outgoingTransfers[connection.id] else { return }
        DispatchQueue.main.async {
            transfer.delegate.connectionFailed(error: error)
        }
        outgoingTransfers.removeValue(forKey: connection.id)
    }
    
    
    func transferFinished(connection: OutboundNearbyConnection) {
        guard let transfer = outgoingTransfers[connection.id] else { return }
        DispatchQueue.main.async {
            transfer.delegate.transferFinished()
        }
        outgoingTransfers.removeValue(forKey: connection.id)
    }
    
    
    public func getActiveConnectionsCount() -> Int {
        return incomingConnections.count + outgoingTransfers.count
    }
    
    
    private func saveFilesToTemp(urls: [URL]) throws -> [URL] {
        
        var modifiedUrls = [URL]()
        
        for url in urls {
            
            // if url is no file url or already in inside temp directory, do nothing
            if url.isFileURL && !url.standardizedFileURL.path.contains(FileManager.default.temporaryDirectory.standardizedFileURL.path) {
                
                let accessSuccess = url.startAccessingSecurityScopedResource()
                
                if !accessSuccess {
                    log("[NearbyConnectionManager] Could not access security scoped resource at \(url)")
                }
                
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                    let zipUrl = try Zip.createAtTemporaryDirectory(zipFilename: url.lastPathComponent, fromDirectory: url)
                    
                    modifiedUrls.append(zipUrl)
                }
                else {
                    // Copy single file to temp directory
                    let tempUrl = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    // Remove if already exists
                    if FileManager.default.fileExists(atPath: tempUrl.path) {
                        try FileManager.default.removeItem(at: tempUrl)
                    }
                    try FileManager.default.copyItem(at: url, to: tempUrl)
                    modifiedUrls.append(tempUrl)
                }
                
                if accessSuccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            else {
                log("[NearbyConnectionManager] File URL \(url) does not point to a security scoped resource")
                modifiedUrls.append(url)
            }
        }
        
        return modifiedUrls
    }
    
    
    // -- MARK: - Inbound Connection Data Store
    
    public func getSaveDirectory() -> URL {
        
        // Not supported on iOS
        #if os(macOS)
        if let securityScopeUrl = securityScopeUrl {
            log("[SaveFilesManager] Using existing security scope URL: \(securityScopeUrl)")
            return securityScopeUrl
        }

        if let bookmarkData = Settings.sharedInstance.saveFolderBookmark {
            var isStale = false
   
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

                if !isStale {
                    if url.startAccessingSecurityScopedResource() {
                        log("[SaveFilesManager] Successfully accessed security scoped resource: \(url)")

                        securityScopeUrl = url
                        return url
                    }
                } else {
                    log("[SaveFilesManager] Bookmark is stale, using default downloads folder.")
                }

            } catch {
                log("[SaveFilesManager] Failed to resolve bookmark: \(error), using default downloads folder.")
            }
        }

        do {
            return try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        } catch {
            fatalError("[SaveFilesManager] Failed to get downloads directory: \(error)")
        }
        #else
        // Return the documents directory for iOS
        do {
            return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        } catch {
            fatalError("Failed to get documents directory: \(error)")
        }
        #endif
    }
    
    
    private func stopAccessingSaveDirectory() {
        // Clean up security scoped resource access
        guard let url = securityScopeUrl else {
            return
        }

        log("[SaveFilesManager] Stopping access to security scoped resource: \(url)")
        url.stopAccessingSecurityScopedResource()
        securityScopeUrl = nil
    }
    
    
    // MARK: Callbacks
    
    func informAboutStatus() {
        DispatchQueue.main.async {
            self.connectionUpdateCallback(self.isConnectedToLocalNetwork && self.startedAdvertising)
        }
    }
    
    
    // -- MARK: - Internal Data Model
    
    private struct FoundServiceInfo {
        let service: NWBrowser.Result
        var device: RemoteDeviceInfo?
    }
    
    
    private struct OutgoingTransferInfo {
        let service: NWBrowser.Result
        let device: RemoteDeviceInfo
        let connection: OutboundNearbyConnection
        let delegate: OutboundAppDelegate
    }
}
