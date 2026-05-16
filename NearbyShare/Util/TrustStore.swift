//
//  TrustStore.swift
//  QuickDrop
//
//  Created by Leon Böttger on 22.08.25.
//

import Foundation
import CryptoKit

class TrustStore: ObservableObject {
    
    static let shared = TrustStore()
    static let trustedCertificatesDidChange = Notification.Name("TrustStore.trustedCertificatesDidChange")
    
    @Published private(set) var trustedCertificates: [String: TrustedCertificate] = [:]
    
    private let trustedKeysKey = "com.leonboettger.quickdrop.identity.trustedKeys"
    private let pendingPairingQueue = DispatchQueue(label: "TrustStore.pairingPending")
    private var pendingPairingTrust: [String: PendingPairingTrust] = [:]
    private let pendingPairingTTL: TimeInterval = 5 * 60
        
    private init() {
        loadTrustedCertificates()
    }
    
    
    // MARK: - Persistence
    
    private func loadTrustedCertificates() {
        do {
            if let data = try KeychainStore.loadData(account: trustedKeysKey) {
                trustedCertificates = try JSONDecoder().decode([String: TrustedCertificate].self, from: data)
                AppGroup.appGroupUD.removeObject(forKey: trustedKeysKey)
                return
            }
        } catch {
            print("[TrustStore] Failed to load trusted certificates from keychain: \(error.localizedDescription)")
        }

        guard let dict = legacyTrustedCertificates() else {
            trustedCertificates = [:]
            return
        }
        
        trustedCertificates = dict

        do {
            try persistTrustedCertificates()
            AppGroup.appGroupUD.removeObject(forKey: trustedKeysKey)
            print("[TrustStore] Migrated trusted certificates from shared defaults to keychain.")
        } catch {
            print("[TrustStore] Failed to migrate trusted certificates to keychain: \(error.localizedDescription)")
        }
    }
    
    
    private func saveTrustedCertificates() {
        do {
            try persistTrustedCertificates()
            AppGroup.appGroupUD.removeObject(forKey: trustedKeysKey)
            notifyTrustedCertificatesDidChange()
        } catch {
            print("[TrustStore] Failed to save trusted certificates to keychain: \(error.localizedDescription)")
        }
    }


    private func notifyTrustedCertificatesDidChange() {
        NotificationCenter.default.post(name: Self.trustedCertificatesDidChange, object: self)
    }
    
    
    // MARK: - Public API
    
    func findTrustedKey(for secretIdHash: Data) -> Data? {
        trustedCertificates[secretIdHash.hex]?.certificateData
    }
    
    
    func addTrusted(
        certificate: Sharing_Nearby_PublicCertificate,
        device: RemoteDeviceInfo,
        grantedUseCases: Set<PairingUseCase> = []
    ) {
        guard let publicKeyData = try? certificate.serializedData() else { return }
        let fingerprint = certificate.secretID.hex
        let existingGrants = trustedCertificates[fingerprint]?.grantedUseCases ?? []
        
        trustedCertificates[fingerprint] = TrustedCertificate(
            device: device,
            creationDate: Date(),
            certificateData: publicKeyData,
            grantedUseCases: existingGrants.union(grantedUseCases)
        )
        
        saveTrustedCertificates()
    }


    func grantUseCase(_ useCase: PairingUseCase, for secretIdHex: String) {
        let normalized = secretIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let existing = trustedCertificates[normalized] else { return }
        trustedCertificates[normalized] = existing.withGrantedUseCase(useCase)
        saveTrustedCertificates()
    }


    func hasUseCaseGrant(_ useCase: PairingUseCase, for secretIdHex: String?) -> Bool {
        guard let normalized = secretIdHex?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return false
        }
        return trustedCertificates[normalized]?.grantedUseCases.contains(useCase) == true
    }
    
    
    func removeTrusted(secretIdHex: String) {
        trustedCertificates.removeValue(forKey: secretIdHex)
        saveTrustedCertificates()
    }


    // MARK: - Pending Pairing Trust

    func registerPendingPairingTrust(secretIdHex: String, pinCode: String, useCase: PairingUseCase) {
        let normalized = secretIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPin = pinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !trimmedPin.isEmpty else { return }

        let pinHash = Self.pinHash(for: trimmedPin)
        pendingPairingQueue.sync {
            pendingPairingTrust[normalized] = PendingPairingTrust(
                useCase: useCase,
                pinHash: pinHash,
                createdAt: Date()
            )
        }
    }

    func confirmPendingPairingTrust(secretIdHex: String, useCase: PairingUseCase, pinHash: Data) -> Bool {
        let normalized = secretIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !pinHash.isEmpty else { return false }

        let now = Date()
        return pendingPairingQueue.sync {
            guard let pending = pendingPairingTrust[normalized] else { return false }
            pendingPairingTrust.removeValue(forKey: normalized)
            let expired = now.timeIntervalSince(pending.createdAt) > pendingPairingTTL
            if expired {
                return false
            }
            guard pending.useCase == useCase else {
                return false
            }
            return pending.pinHash == pinHash
        }
    }

    func clearPendingPairingTrust(secretIdHex: String) {
        let normalized = secretIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }

        _ = pendingPairingQueue.sync {
            pendingPairingTrust.removeValue(forKey: normalized)
        }
    }
    
    
    struct TrustedCertificate: Codable, Equatable {
        
        // warning: do not rename for persistence
        let device: RemoteDeviceInfo
        let creationDate: Date
        let certificateData: Data
        let grantedUseCases: Set<PairingUseCase>

        init(
            device: RemoteDeviceInfo,
            creationDate: Date,
            certificateData: Data,
            grantedUseCases: Set<PairingUseCase> = []
        ) {
            self.device = device
            self.creationDate = creationDate
            self.certificateData = certificateData
            self.grantedUseCases = grantedUseCases
        }

        private enum CodingKeys: String, CodingKey {
            case device
            case creationDate
            case certificateData
            case grantedUseCases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            device = try container.decode(RemoteDeviceInfo.self, forKey: .device)
            creationDate = try container.decode(Date.self, forKey: .creationDate)
            certificateData = try container.decode(Data.self, forKey: .certificateData)
            grantedUseCases = try container.decodeIfPresent(Set<PairingUseCase>.self, forKey: .grantedUseCases) ?? []
        }

        func withGrantedUseCase(_ useCase: PairingUseCase) -> TrustedCertificate {
            TrustedCertificate(
                device: device,
                creationDate: creationDate,
                certificateData: certificateData,
                grantedUseCases: grantedUseCases.union([useCase])
            )
        }
    }

    struct PendingPairingTrust: Equatable {
        let useCase: PairingUseCase
        let pinHash: Data
        let createdAt: Date
    }


    private func persistTrustedCertificates() throws {
        let data = try JSONEncoder().encode(trustedCertificates)
        try KeychainStore.saveData(data, account: trustedKeysKey)
    }


    private func legacyTrustedCertificates() -> [String: TrustedCertificate]? {
        guard let dict = AppGroup.appGroupUD.dictionary(forKey: trustedKeysKey) as? [String: Data] else {
            return nil
        }

        var decoded: [String: TrustedCertificate] = [:]
        for (key, data) in dict {
            if let cert = try? JSONDecoder().decode(TrustedCertificate.self, from: data) {
                decoded[key] = cert
            }
        }
        return decoded
    }

    private static func pinHash(for pinCode: String) -> Data {
        let data = Data(pinCode.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }
}
