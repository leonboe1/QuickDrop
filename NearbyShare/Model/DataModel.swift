//
//  DataModel.swift
//  QuickDrop
//
//  Created by Leon Böttger on 26.07.25.
//

import Foundation
import UniformTypeIdentifiers
import Network
import CryptoKit
import SwiftECC
import LUI


protocol InboundNearbyConnectionDelegate {
    func obtainUserConsent(transfer: TransferMetadata, device: RemoteDeviceInfo, connection: InboundNearbyConnection)
    func obtainedUserConsentAutomatically(transfer: TransferMetadata, device: RemoteDeviceInfo, connection: InboundNearbyConnection)
    func updatedTransferProgress(connection: InboundNearbyConnection, progress: Double)
    func connectionWasTerminated(connection: InboundNearbyConnection, savedFiles: [URL], error: Error?)
    func showPlusScreen()
    func pairingSetupConfirmed(connection: InboundNearbyConnection)
}


protocol OutboundNearbyConnectionDelegate {
    func connectionWasEstablished(connection: OutboundNearbyConnection)
    func updatedTransferProgress(connection: OutboundNearbyConnection, progress: Double)
    func transferAccepted(connection: OutboundNearbyConnection)
    func failedWithError(connection: OutboundNearbyConnection, error: Error)
    func transferFinished(connection: OutboundNearbyConnection)
    func receiverAuthenticationPending(
        connection: OutboundNearbyConnection,
        certificateData: Data,
        device: RemoteDeviceInfo,
        fingerprint: String
    )
}


public enum ReceiverAuthenticationPolicy: Equatable {
    case none
    case trustedReceiver(fingerprint: String)
    case bootstrapReceiverTrust(fingerprint: String)
}


public protocol InboundAppDelegate: AnyObject {
    func obtainUserConsent(transfer: TransferMetadata, device: RemoteDeviceInfo)
    func obtainedUserConsentAutomatically(transfer: TransferMetadata, device: RemoteDeviceInfo)
    func connectionWasTerminated(connectionID: String, from device: RemoteDeviceInfo?, savedFiles: [URL], wasPlainTextTransfer: Bool, wasClipboardSync: Bool, error: Error?)
    func transferProgress(connectionID: String, progress: Double)
    func showPlusScreen()
    func pairingSetupConfirmed()
}

extension InboundAppDelegate {
    func pairingSetupConfirmed() {}
}


public protocol OutboundAppDelegate: AnyObject {
    func addDevice(device: RemoteDeviceInfo)
    func removeDevice(id: String)
    func startTransferWithQrCode(device: RemoteDeviceInfo)
    func connectionWasEstablished(pinCode: String)
    func connectionFailed(error: Error)
    func transferAccepted()
    func transferProgress(progress: Double)
    func transferFinished()
}


public struct RemoteDeviceInfo: Codable, Identifiable, Equatable {
    public let name: String?
    public let type: DeviceType
    public let qrCodeData: Data?
    public let isQuickDropPeer: Bool
    public var id: String?
    public let keyFingerprint: String?
    public let supportsNotificationSync: Bool
    public let supportsClipboardReceive: Bool

    init(
        name: String?,
        type: DeviceType?,
        id: String? = nil,
        isQuickDropPeer: Bool = false,
        keyFingerprint: String? = nil,
        supportsNotificationSync: Bool = false,
        supportsClipboardReceive: Bool = false
    ) {
        self.name = name
        self.type = type ?? .phone
        self.id = id
        self.qrCodeData = nil
        self.isQuickDropPeer = isQuickDropPeer
        self.keyFingerprint = Self.normalizedKeyFingerprint(keyFingerprint)
        self.supportsNotificationSync = supportsNotificationSync
        self.supportsClipboardReceive = supportsClipboardReceive
    }

    init(
        info: EndpointInfo,
        id: String? = nil,
        isQuickDropPeer: Bool = false,
        keyFingerprint: String? = nil,
        supportsNotificationSync: Bool = false,
        supportsClipboardReceive: Bool = false
    ) {
        self.name = info.name
        self.type = info.deviceType
        self.qrCodeData = info.qrCodeData
        self.id = id
        self.isQuickDropPeer = isQuickDropPeer
        self.keyFingerprint = Self.normalizedKeyFingerprint(keyFingerprint)
        self.supportsNotificationSync = supportsNotificationSync
        self.supportsClipboardReceive = supportsClipboardReceive
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case qrCodeData
        case isQuickDropPeer
        case isVerifiedQuickDropPeer
        case id
        case keyFingerprint
        case supportsNotificationSync
        case supportsClipboardReceive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decode(DeviceType.self, forKey: .type)
        qrCodeData = try container.decodeIfPresent(Data.self, forKey: .qrCodeData)
        isQuickDropPeer = try container.decodeIfPresent(Bool.self, forKey: .isQuickDropPeer)
            ?? container.decodeIfPresent(Bool.self, forKey: .isVerifiedQuickDropPeer)
            ?? false
        id = try container.decodeIfPresent(String.self, forKey: .id)
        keyFingerprint = Self.normalizedKeyFingerprint(
            try container.decodeIfPresent(String.self, forKey: .keyFingerprint)
        )
        supportsNotificationSync = try container.decodeIfPresent(Bool.self, forKey: .supportsNotificationSync) ?? false
        supportsClipboardReceive = try container.decodeIfPresent(Bool.self, forKey: .supportsClipboardReceive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(qrCodeData, forKey: .qrCodeData)
        try container.encode(isQuickDropPeer, forKey: .isQuickDropPeer)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(keyFingerprint, forKey: .keyFingerprint)
        try container.encode(supportsNotificationSync, forKey: .supportsNotificationSync)
        try container.encode(supportsClipboardReceive, forKey: .supportsClipboardReceive)
    }

    
    public enum DeviceType: Int32, Codable {
        case unknown = 0
        case phone
        case tablet
        case computer

        public static func fromRawValue(value: Int) -> DeviceType {
            switch value {
            case 0:
                return .unknown
            case 1:
                return .phone
            case 2:
                return .tablet
            case 3:
                return .computer
            default:
                return .unknown
            }
        }
    }
    
    
    public var icon: String {
        switch type {
            case .computer:
                return "laptopcomputer"
            case .tablet:
                return "ipad.landscape"
            default:
                return getSmartphoneIcon()
        }
    }
    
    
    private func getSmartphoneIcon() -> String {
        if #available(iOS 17.0, macOS 14.0, *) {
            return "smartphone"
        }
        return "iphone"
    }

    private static func normalizedKeyFingerprint(_ keyFingerprint: String?) -> String? {
        let normalized = keyFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}


public struct TransferMetadata {
    public let files: [FileMetadata]
    public let id: String
    public let pinCode: String?
    public let textDescription: String?
    public let type: TransferType
    public let allowsToBeAddedAsTrustedDevice: Bool
    public let isClipboardSync: Bool

    init(files: [FileMetadata], id: String, pinCode: String?, textDescription: String? = nil, transferType: TransferType = .file, allowsToBeAddedAsTrustedDevice: Bool, isClipboardSync: Bool = false) {
        self.files = files
        self.id = id
        self.pinCode = pinCode
        self.textDescription = textDescription
        self.type = transferType
        self.allowsToBeAddedAsTrustedDevice = allowsToBeAddedAsTrustedDevice
        self.isClipboardSync = isClipboardSync
    }
    
    public enum TransferType {
        case file
        case text
        case url
        case wifiPassword
        case notificationSync
        case clipboardSync
    }
    
    private func getSummary() -> String {
        if let textTitle = textDescription {
            return textTitle
        } else if files.count == 1 {
            return fileTypeSummary(for: files[0])
        } else {
            return String.localizedStringWithFormat("NFiles".localized(), files.count)
        }
    }

    private func fileTypeSummary(for file: FileMetadata) -> String {
        let mimeType = file.mimeType.lowercased()
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        let type = UTType(mimeType: mimeType) ?? UTType(filenameExtension: ext)

        if let type, type.conforms(to: .pdf) {
            return "PDF".localized()
        }
        if let type, type.conforms(to: .image) {
            return "Image".localized()
        }
        if let type, type.conforms(to: .video) || type.conforms(to: .movie) {
            return "Video".localized()
        }
        if let type, type.conforms(to: .audio) {
            return "Audio".localized()
        }
        if let type, type.conforms(to: .text) {
            return "Text".localized()
        }
        if let type, type.conforms(to: .archive) {
            return "Archive".localized()
        }
        if let type, let description = type.localizedDescription {
            return description
        }
        return "File".localized()
    }
    
    public func getDescription(deviceName: String) -> String {
        
        let fileStr = getSummary()
        
        switch type {
            case .file:
            return "DeviceSendingFiles".localized(with: fileStr, deviceName)
            
            case .text:
            return "DeviceSendingText".localized(with: deviceName)
            
            case .url:
            return "DeviceSendingUrl".localized(with: deviceName)
            
            case .wifiPassword:
            return "DeviceSendingWifiPassword".localized(with: deviceName)

            case .notificationSync:
            if let textDescription, !textDescription.isEmpty {
                return textDescription
            }
            return "NotificationSyncConsentPromptFromDevice".localized(with: deviceName)

            case .clipboardSync:
            if let textDescription, !textDescription.isEmpty {
                return textDescription
            }
            return "ClipboardSyncConsentPromptFromDevice".localized(with: deviceName)
        }
    }
    
    public func getPinCodeMessage() -> String {
        return String(format: "PinCode".localized(), arguments: [pinCode ?? "?"])
    }
}

enum PairingUseCase: String, Codable, Hashable {
    case notificationSync = "notification_sync"
    case clipboardSync = "clipboard_sync"

    var protoValue: Sharing_Nearby_PairingMetadata.UseCase {
        switch self {
        case .notificationSync:
            return .notificationSync
        case .clipboardSync:
            return .clipboardSync
        }
    }

    init?(protoValue: Sharing_Nearby_PairingMetadata.UseCase) {
        switch protoValue {
        case .notificationSync:
            self = .notificationSync
        case .clipboardSync:
            self = .clipboardSync
        case .unknown:
            return nil
        }
    }
}


public struct FileMetadata {
    public let name: String
    public let size: Int64
    public let mimeType: String
}


public struct EndpointInfo {
    var name: String?
    let deviceType: RemoteDeviceInfo.DeviceType
    let qrCodeData: Data?
    
    static let maxNameChars = 32

    init(name: String, deviceType: RemoteDeviceInfo.DeviceType) {
        self.name = String(decoding: Self.sanitizedString(name), as: UTF8.self)
        self.deviceType = deviceType
        self.qrCodeData = nil
    }
    
    
    init?(data: Data) {
        guard data.count > 17 else {
            log("[EndpointInfo] Invalid endpoint info data received (too short)")
            return nil
        }
        
        let hasName = (data[0] & 0x10) == 0
        let deviceNameLength: Int
        let deviceName: String?
        
        if hasName {
            deviceNameLength = Int(data[17])
            guard data.count >= deviceNameLength + 18 else {
                log("[EndpointInfo] Invalid endpoint info data received (name length mismatch)")
                return nil
            }
            guard let newDeviceName = String(data: data[18..<(18 + deviceNameLength)], encoding: .utf8) else {
                log("[EndpointInfo] Invalid endpoint info data received (name decoding failed)")
                return nil
            }
            deviceName = newDeviceName
        }
        else {
            deviceNameLength = 0
            deviceName = nil
        }
        
        let rawDeviceType: Int = Int(data[0] & 7) >> 1
        self.name = deviceName
        self.deviceType = RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)
        var offset = 1 + 16
        
        if hasName {
            offset = offset + 1 + deviceNameLength
        }
        
        var qrCodeData: Data? = nil
        
        // read TLV records, if any
        while data.count - offset > 2 {
            let type = data[offset]
            let length = Int(data[offset+1])
            offset = offset + 2
            if data.count - offset >= length{
                // QR code data
                if type == 1 {
                    qrCodeData = data.subdata(in: offset..<offset + length)
                }
                
                offset = offset + length
            }
        }
        
        self.qrCodeData = qrCodeData
    }

    
    func serialize() -> Data {
        // 1 byte: Version(3 bits)|Visibility(1 bit)|Device Type(3 bits)|Reserved(1 bits)
        // Device types: unknown=0, phone=1, tablet=2, laptop=3
        var endpointInfo: [UInt8] = [UInt8(deviceType.rawValue << 1)]
        // 16 bytes: unknown random bytes
        for _ in 0 ... 15 {
            endpointInfo.append(UInt8.random(in: 0...255))
        }
        // Device name in UTF-8 prefixed with 1-byte length
        let nameChars = Self.sanitizedString(self.name ?? "")
        endpointInfo.append(UInt8(nameChars.count))
        for ch in nameChars {
            endpointInfo.append(UInt8(ch))
        }
        return Data(endpointInfo)
    }
    
    
    private static func sanitizedString(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(Self.maxNameChars, string.utf8.count))

        for scalar in string.unicodeScalars {
            let bytes = Array(scalar.utf8)
            if out.count + bytes.count > Self.maxNameChars { break }
            out.append(contentsOf: bytes)
        }

        return out
    }
}


public enum NearbyError: Error {
    case protocolError(_ message: String)
    case requiredFieldMissing(_ message: String)
    case ukey2
    case packetFilterError
    case firewallError
    case inputOutput
    case notificationSyncNotTrusted
    case canceled(reason: CancellationReason)

    public enum CancellationReason {
        case userRejected, userCanceled, notEnoughSpace, unsupportedType, timedOut
        
        public func localizedDescription() -> String {
            switch self {
                case .userRejected:
                    "TransferDeclined".localized()
                case .userCanceled:
                    "TransferCanceled".localized()
                case .notEnoughSpace:
                    "NotEnoughSpace".localized()
                case .unsupportedType:
                    "UnsupportedType".localized()
                case .timedOut:
                    "TransferTimedOut".localized()
                }
        }
    }
}
