//
//  OutboundNearbyConnection.swift
//  NearbyShare
//
//  Created by Grishka on 23.09.2023.
//

import CommonCrypto
import CryptoKit
import Foundation
import Network
import System
import UniformTypeIdentifiers
import BigInt
import SwiftECC
import ASN1
import BigInt
import LUI


class OutboundNearbyConnection: NearbyConnection {
    private var currentState: State = .initial
    private let urlsToSend: [URL]
    private let textToSend: String?
    private let isClipboardSyncTransfer: Bool
    private let receiverAuthenticationPolicy: ReceiverAuthenticationPolicy
    private var ukeyClientFinishMsgData: Data?
    private var queue: [OutgoingFileTransfer] = []
    private var currentTransfer: OutgoingFileTransfer?
    private var totalBytesToSend: Int64 = 0
    private var textPayloadID: Int64 = 0
    private var receiverAuthenticationVerified = false
    
    public var qrCodePrivateKey: ECPrivateKey?
    public var delegate: OutboundNearbyConnectionDelegate?

    enum State {
        case initial, sentUkeyClientInit, sentUkeyClientFinish, sentPairedKeyEncryption, sentPairedKeyResult, sentIntroduction, sendingFiles
    }

    init(
        connection: NWConnection,
        id: String,
        urlsToSend: [URL],
        textToSend: String?,
        isClipboardSyncTransfer: Bool = false,
        receiverAuthenticationPolicy: ReceiverAuthenticationPolicy
    ) {
        
        self.urlsToSend = urlsToSend
        self.textToSend = textToSend
        self.isClipboardSyncTransfer = isClipboardSyncTransfer
        self.receiverAuthenticationPolicy = receiverAuthenticationPolicy
        
        super.init(connection: connection, id: id)
        
        if hasURL() || textToSend != nil {
            textPayloadID = Int64.random(in: Int64.min ... Int64.max)
        }
    }

    
    deinit {
        if let transfer = currentTransfer, let handle = transfer.handle {
            try? handle.close()
        }
        for transfer in queue {
            if let handle = transfer.handle {
                try? handle.close()
            }
        }
    }
    
    
    override func disconnect() {
        super.disconnect()
  
        // delete all files
        for url in urlsToSend {
            
            do {
                try FileManager.default.removeItem(at: url)
                log("[OutboundNearbyConnection \(self.id)] Deleted file at \(url).")
            }
            catch {
                log("[OutboundNearbyConnection \(self.id)] Failed to delete file at \(url): \(error)")
            }
        }
        
        if let error = lastError {
            DispatchQueue.main.async {
                self.delegate?.failedWithError(connection: self, error: error)
            }
        }
    }
    

    override func connectionReady() {
        super.connectionReady()
        do {
            try sendConnectionRequest()
            try sendUkey2ClientInit()
        } catch {
            lastError = error
            protocolError()
        }
    }
    

    override func isServer() -> Bool {
        return false
    }

    
    override func processReceivedFrame(frameData: Data) {
        
        if currentState != .sendingFiles {
            log("[OutboundNearbyConnection \(self.id)] Received frame in state \(currentState)...")
        }
        
        do {
            switch currentState {
            case .initial:
                protocolError()
            case .sentUkeyClientInit:
                try processUkey2ServerInit(frame: Securegcm_Ukey2Message(serializedBytes: frameData), raw: frameData)
            case .sentUkeyClientFinish:
                try processConnectionResponse(frame: Location_Nearby_Connections_OfflineFrame(serializedBytes: frameData))
            default:
                let smsg = try Securemessage_SecureMessage(serializedBytes: frameData)
                try decryptAndProcessReceivedSecureMessage(smsg)
            }
        } catch {
            
            log("[OutboundNearbyConnection \(self.id)] Error occured while processing frame with data \(frameData.hex): \(error)")
            
            if case NearbyError.ukey2 = error {
                // do nothing
            }
            else if currentState == .sentUkeyClientInit {
                sendUkey2Alert(type: .badMessage)
            }
            lastError = error
            protocolError()
        }
    }

    
    override func processTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        
        if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
            self.cancelled = true
            self.lastError = NearbyError.canceled(reason: .userCanceled)
            log("[OutboundNearbyConnection \(self.id)] Transfer canceled")
            try sendDisconnectionAndDisconnect()
            delegate?.failedWithError(connection: self, error: self.lastError!)
            return
        }
        
        switch currentState {
        case .sentPairedKeyEncryption:
            if frame.hasV1, frame.v1.hasPairedKeyEncryption {
                try processPairedKeyEncryption(frame: frame)
                return
            }
            if frame.hasV1, frame.v1.hasPairedKeyResult {
                log("[OutboundNearbyConnection \(self.id)] Received pairedKeyResult before pairedKeyEncryption; continuing for legacy compatibility.")
                try processPairedKeyResult(frame: frame)
                return
            }
            if frame.hasV1, frame.v1.hasType {
                if frame.v1.type == .progressUpdate || frame.v1.type == .response {
                    log("[OutboundNearbyConnection \(self.id)] Ignoring duplicate/intermediate transfer setup frame \(frame.v1.type) while waiting for pairedKeyEncryption.")
                    return
                }
            }
            throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyEncryption")
        case .sentPairedKeyResult:
            if frame.hasV1, frame.v1.hasPairedKeyResult {
                try processPairedKeyResult(frame: frame)
                return
            }
            if frame.hasV1, frame.v1.hasType {
                if frame.v1.type == .pairedKeyEncryption || frame.v1.type == .progressUpdate || frame.v1.type == .response {
                    log("[OutboundNearbyConnection \(self.id)] Ignoring duplicate/intermediate transfer setup frame \(frame.v1.type) while waiting for pairedKeyResult.")
                    return
                }
            }
            throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyResult")
        case .sentIntroduction:
            if frame.version == .v1, frame.v1.type == .response {
                try processConsent(frame: frame)
                return
            }
            if frame.hasV1, frame.v1.hasType {
                if frame.v1.type == .pairedKeyEncryption || frame.v1.type == .pairedKeyResult || frame.v1.type == .progressUpdate {
                    log("[OutboundNearbyConnection \(self.id)] Ignoring duplicate/intermediate transfer setup frame \(frame.v1.type) while waiting for consent.")
                    return
                }
            }
            throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.type==response")
        case .sendingFiles:
            break
        default:
            log("[OutboundNearbyConnection \(self.id)] Unexpected state \(currentState)")
        }
    }
    

    override func protocolError() {
        super.protocolError()
        delegate?.failedWithError(connection: self, error: lastError!)
    }

    
    private func sendConnectionRequest() throws {
        
        let endpointInfo = NearbyConnectionManager.shared.deviceInfo
        
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1 = Location_Nearby_Connections_V1Frame()
        frame.v1.type = .connectionRequest
        frame.v1.connectionRequest = Location_Nearby_Connections_ConnectionRequestFrame()
        frame.v1.connectionRequest.endpointID = Data(NearbyConnectionManager.shared.endpointID)
        frame.v1.connectionRequest.endpointName = Data((endpointInfo.name ?? "QuickDrop").utf8)
        frame.v1.connectionRequest.endpointInfo = endpointInfo.serialize()
        frame.v1.connectionRequest.mediums = [.wifiLan]
        try sendFrameAsync(frame.serializedData())
    }

    
    private func sendUkey2ClientInit() throws {
        let domain = Domain.instance(curve: .EC256r1)
        let (pubKey, privKey) = domain.makeKeyPair()
        privateKey = privKey

        var finishFrame = Securegcm_Ukey2Message()
        finishFrame.messageType = .clientFinish
        var finish = Securegcm_Ukey2ClientFinished()
        var pkey = Securemessage_GenericPublicKey()
        pkey.type = .ecP256
        pkey.ecP256PublicKey = Securemessage_EcP256PublicKey()
        pkey.ecP256PublicKey.x = Data(pubKey.w.x.asSignedBytes())
        pkey.ecP256PublicKey.y = Data(pubKey.w.y.asSignedBytes())
        finish.publicKey = try pkey.serializedData()
        finishFrame.messageData = try finish.serializedData()
        ukeyClientFinishMsgData = try finishFrame.serializedData()

        var frame = Securegcm_Ukey2Message()
        frame.messageType = .clientInit

        var clientInit = Securegcm_Ukey2ClientInit()
        clientInit.version = 1
        clientInit.random = Data.randomData(length: 32)
        clientInit.nextProtocol = "AES_256_CBC-HMAC_SHA256"
        var sha = SHA512()
        sha.update(data: ukeyClientFinishMsgData!)
        var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitment.commitment = Data(sha.finalize())
        commitment.handshakeCipher = .p256Sha512
        clientInit.cipherCommitments.append(commitment)
        frame.messageData = try clientInit.serializedData()

        ukeyClientInitMsgData = try frame.serializedData()
        sendFrameAsync(ukeyClientInitMsgData!)
        currentState = .sentUkeyClientInit
    }
    

    private func processUkey2ServerInit(frame: Securegcm_Ukey2Message, raw: Data) throws {
        ukeyServerInitMsgData = raw
        guard frame.messageType == .serverInit else {
            sendUkey2Alert(type: .badMessageType)
            log("[OutboundNearbyConnection \(self.id)] Invalid message type: \(frame.messageType)")
            throw NearbyError.ukey2
        }
        let serverInit = try Securegcm_Ukey2ServerInit(serializedBytes: frame.messageData)
        guard serverInit.version == 1 else {
            sendUkey2Alert(type: .badVersion)
            log("[OutboundNearbyConnection \(self.id)] Invalid version: \(serverInit.version)")
            throw NearbyError.ukey2
        }
        guard serverInit.random.count == 32 else {
            sendUkey2Alert(type: .badRandom)
            log("[OutboundNearbyConnection \(self.id)] Invalid random: \(serverInit.random.count)")
            throw NearbyError.ukey2
        }
        guard serverInit.handshakeCipher == .p256Sha512 else {
            sendUkey2Alert(type: .badHandshakeCipher)
            log("[OutboundNearbyConnection \(self.id)] Invalid handshake cipher: \(serverInit.handshakeCipher)")
            throw NearbyError.ukey2
        }

        let serverKey = try Securemessage_GenericPublicKey(serializedBytes: serverInit.publicKey)
        try finalizeKeyExchange(peerKey: serverKey)
        sendFrameAsync(ukeyClientFinishMsgData!)
        currentState = .sentUkeyClientFinish

        var resp = Location_Nearby_Connections_OfflineFrame()
        resp.version = .v1
        resp.v1 = Location_Nearby_Connections_V1Frame()
        resp.v1.type = .connectionResponse
        resp.v1.connectionResponse = Location_Nearby_Connections_ConnectionResponseFrame()
        resp.v1.connectionResponse.response = .accept
        resp.v1.connectionResponse.status = 0
        resp.v1.connectionResponse.osInfo = Location_Nearby_Connections_OsInfo()
        resp.v1.connectionResponse.osInfo.type = .apple
        try sendFrameAsync(resp.serializedData())

        encryptionDone = true
        delegate?.connectionWasEstablished(connection: self)
    }

    
    private func processConnectionResponse(frame: Location_Nearby_Connections_OfflineFrame) throws {
        
        guard frame.version == .v1 else { throw NearbyError.protocolError("Unexpected offline frame version \(frame.version)") }
        guard frame.hasV1, frame.v1.hasType else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.type") }

        if frame.v1.type == .keepAlive {
            log("[OutboundNearbyConnection \(self.id)] Ignoring keep-alive while waiting for connection response")
            return
        }
        
        guard frame.v1.type == .connectionResponse else { throw NearbyError.protocolError("Unexpected frame type \(frame.v1.type)") }
        
        guard frame.v1.connectionResponse.response == .accept else { throw NearbyError.protocolError("Connection was rejected by recipient") }

        var pairedEncryption = Sharing_Nearby_Frame()
        pairedEncryption.version = .v1
        pairedEncryption.v1.type = .pairedKeyEncryption
        
        // add public key
        var cert = Sharing_Nearby_PublicCertificate()
        if let signingPrivateKey = IdentityManager.shared.getPrivateKey(),
            let publicKey = IdentityManager.shared.getPublicKey()?.toGenericPublicKey(),
            let publicKeyData = IdentityManager.shared.getPublicKey()?.toGenericPublicKeyData(),
            let publicKeyId = publicKey.id(),
            let authKeyData = self.authKey?.data() {
            
            log("[OutboundNearbyConnection \(self.id)] Using private key for signing")
            
            cert.secretID = publicKeyId
            cert.publicKey = publicKeyData

            let signatureTuple = signingPrivateKey.sign(msg: authKeyData)

            pairedEncryption.v1.certificateInfo.publicCertificate.append(cert)
            pairedEncryption.v1.pairedKeyEncryption.signedData = Data(signatureTuple.asn1.encode())
            pairedEncryption.v1.pairedKeyEncryption.secretIDHash = cert.secretID
            
            pairedEncryption.v1.pairedKeyResult.status = .success
        }
        else {
            
            log("[OutboundNearbyConnection \(self.id)] No private key available, cannot send signing certificate!")
            
            pairedEncryption.v1.pairedKeyEncryption.secretIDHash = Data.randomData(length: 6)
            pairedEncryption.v1.pairedKeyEncryption.signedData = Data.randomData(length: 72)
        }
        
        if let qrKey = qrCodePrivateKey, let authKey = authKey {
            let signature = qrKey.sign(msg: authKey.data())
            var serializedSignature = Data(signature.r)
            serializedSignature.append(Data(signature.s))
            pairedEncryption.v1.pairedKeyEncryption.qrCodeHandshakeData = serializedSignature
        }
        
        try sendTransferSetupFrame(pairedEncryption)

        currentState = .sentPairedKeyEncryption
    }

    
    private func processPairedKeyEncryption(frame: Sharing_Nearby_Frame) throws {
        guard frame.hasV1, frame.v1.hasPairedKeyEncryption else { throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyEncryption") }
        var pairedResult = Sharing_Nearby_Frame()
        pairedResult.version = .v1
        pairedResult.v1 = Sharing_Nearby_V1Frame()
        pairedResult.v1.type = .pairedKeyResult
        pairedResult.v1.pairedKeyResult = Sharing_Nearby_PairedKeyResultFrame()
        if receiverAuthenticationPolicy.requiresReceiverAuthentication {
            try verifyReceiverAuthentication(frame: frame)
            pairedResult.v1.pairedKeyResult.status = .success
        } else {
            pairedResult.v1.pairedKeyResult.status = .unable
        }
        
        try sendTransferSetupFrame(pairedResult)
        currentState = .sentPairedKeyResult
    }

    
    private func processPairedKeyResult(frame: Sharing_Nearby_Frame) throws {
        guard frame.hasV1, frame.v1.hasPairedKeyResult else { throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.pairedKeyResult") }
        if receiverAuthenticationPolicy.requiresReceiverAuthentication, !receiverAuthenticationVerified {
            throw NearbyError.protocolError("Receiver authentication incomplete")
        }

        var introduction = Sharing_Nearby_Frame()
        introduction.version = .v1
        introduction.v1.type = .introduction
        if isClipboardSyncTransfer {
            introduction.v1.introduction.useCase = .remoteCopy
        }
        
        if let textToSend = textToSend {
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .text
            meta.textTitle = textToSend
            meta.size = Int64(textToSend.utf8.count)
            meta.payloadID = textPayloadID
            meta.id = Int64.random(in: Int64.min ... Int64.max)
            introduction.v1.introduction.textMetadata.append(meta)
            
        } else if hasURL() {
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .url
            meta.textTitle = urlsToSend[0].host ?? "URL"
            meta.size = Int64(urlsToSend[0].absoluteString.utf8.count)
            meta.payloadID = textPayloadID
            meta.id = Int64.random(in: Int64.min ... Int64.max)
            introduction.v1.introduction.textMetadata.append(meta)
        } else {
            for url in urlsToSend {
                guard url.isFileURL else { continue }
                var meta = Sharing_Nearby_FileMetadata()
                meta.name = OutboundNearbyConnection.sanitizeFileName(name: url.lastPathComponent)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                meta.size = (attrs[FileAttributeKey.size] as! NSNumber).int64Value
                let typeID = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
                meta.mimeType = "application/octet-stream"
                if let typeID = typeID {
                    let type = UTType(typeID)
                    if let type = type, let mimeType = type.preferredMIMEType {
                        meta.mimeType = mimeType
                    }
                }
                if meta.mimeType.starts(with: "image/") {
                    meta.type = .image
                } else if meta.mimeType.starts(with: "video/") {
                    meta.type = .video
                } else if meta.mimeType.starts(with: "audio/") {
                    meta.type = .audio
                } else if url.pathExtension.lowercased() == "apk" {
                    meta.type = .androidApp
                } else {
                    meta.type = .unknown
                }

                meta.payloadID = Int64.random(in: Int64.min ... Int64.max)
                meta.id = Int64.random(in: Int64.min ... Int64.max)
                
                try queue.append(OutgoingFileTransfer(url: url, fileName: meta.name, payloadID: meta.payloadID, handle: FileHandle(forReadingFrom: url), totalBytes: meta.size, currentOffset: 0))
                introduction.v1.introduction.fileMetadata.append(meta)
                totalBytesToSend += meta.size
                
                log("[OutboundNearbyConnection \(self.id)] Sending file with \(meta.size) bytes and mime type \(meta.mimeType) and type \(meta.type) and name \(meta.name)")
            }
        }
        try sendTransferSetupFrame(introduction)

        currentState = .sentIntroduction
    }
    

    private func processConsent(frame: Sharing_Nearby_Frame) throws {
        guard frame.version == .v1, frame.v1.type == .response else { throw NearbyError.requiredFieldMissing("sharingNearbyFrame.v1.type==response") }
        switch frame.v1.connectionResponse.status {
        case .accept:
            currentState = .sendingFiles
            isTransferring = true
            delegate?.transferAccepted(connection: self)
            
            if let textToSend = textToSend {
                try sendText(text: textToSend)
            } else if hasURL() {
                try sendURL()
            } else {
                try sendNextFileChunk()
            }
        case .reject, .unknown:
            delegate?.failedWithError(connection: self, error: NearbyError.canceled(reason: .userRejected))
            try sendDisconnectionAndDisconnect()
        case .notEnoughSpace:
            delegate?.failedWithError(connection: self, error: NearbyError.canceled(reason: .notEnoughSpace))
            try sendDisconnectionAndDisconnect()
        case .timedOut:
            delegate?.failedWithError(connection: self, error: NearbyError.canceled(reason: .timedOut))
            try sendDisconnectionAndDisconnect()
        case .unsupportedAttachmentType:
            delegate?.failedWithError(connection: self, error: NearbyError.canceled(reason: .unsupportedType))
            try sendDisconnectionAndDisconnect()
        }
    }


    private func verifyReceiverAuthentication(frame: Sharing_Nearby_Frame) throws {
        guard let expectedFingerprint = receiverAuthenticationPolicy.expectedReceiverKeyFingerprint, !expectedFingerprint.isEmpty else {
            throw NearbyError.protocolError("Missing expected receiver fingerprint")
        }

        guard let certificate = frame.v1.certificateInfo.publicCertificate.first else {
            throw NearbyError.protocolError("Missing receiver certificate")
        }

        let certificateData = try certificate.serializedData()
        let secretID = certificate.secretID
        guard !secretID.isEmpty else {
            throw NearbyError.protocolError("Missing receiver key ID")
        }

        let peerGenericKey = try Securemessage_GenericPublicKey(serializedBytes: certificate.publicKey)
        guard let derivedKeyID = peerGenericKey.id() else {
            throw NearbyError.protocolError("Receiver key ID derivation failed")
        }

        guard secretID == derivedKeyID else {
            throw NearbyError.protocolError("Receiver key ID mismatch")
        }

        let actualFingerprint = derivedKeyID.hex.lowercased()
        guard actualFingerprint == expectedFingerprint else {
            throw NearbyError.protocolError("Receiver fingerprint mismatch")
        }

        let pinnedCertificateData = TrustStore.shared.findTrustedKey(for: secretID)
        if pinnedCertificateData == nil, !receiverAuthenticationPolicy.allowsReceiverTrustBootstrap {
            throw NearbyError.protocolError("Receiver certificate is not trusted")
        }

        if let pinnedCertificateData, pinnedCertificateData != certificateData {
            throw NearbyError.protocolError("Receiver certificate changed")
        }

        let pairedKeyEncryption = frame.v1.pairedKeyEncryption
        guard pairedKeyEncryption.secretIDHash == secretID else {
            throw NearbyError.protocolError("Receiver sent unexpected key ID")
        }

        guard let authKeyData = authKey?.data() else {
            throw NearbyError.protocolError("Missing auth key for receiver verification")
        }

        let domain = Domain.instance(curve: .EC256r1)
        let ecKey = peerGenericKey.ecP256PublicKey
        let point = Point(
            BInt(magnitude: [UInt8](ecKey.x.ensureLength(length: 32))),
            BInt(magnitude: [UInt8](ecKey.y.ensureLength(length: 32)))
        )

        guard let peerPublicKey = try? ECPublicKey(domain: domain, w: point) else {
            throw NearbyError.protocolError("Invalid receiver public key")
        }

        let signature = try ECSignature(asn1: .build(pairedKeyEncryption.signedData), domain: domain)
        guard peerPublicKey.verify(signature: signature, msg: authKeyData) else {
            throw NearbyError.protocolError("Receiver signature verification failed")
        }

        if pinnedCertificateData == nil, receiverAuthenticationPolicy.allowsReceiverTrustBootstrap {
            guard let device = remoteDeviceInfo else {
                throw NearbyError.protocolError("Missing remote device info for receiver trust")
            }
            delegate?.receiverAuthenticationPending(
                connection: self,
                certificateData: certificateData,
                device: device,
                fingerprint: actualFingerprint
            )
        }

        receiverAuthenticationVerified = true
    }

    private func hasURL() -> Bool {
        urlsToSend.count == 1 && !urlsToSend[0].isFileURL
    }

    
    private func sendURL() throws {
        try sendText(text: urlsToSend[0].absoluteString)
    }
    
    
    private func sendText(text: String) throws {
        try sendBytesPayload(data: Data(text.utf8), id: textPayloadID)
        delegate?.transferFinished(connection: self)
        try sendDisconnectionAndDisconnect()
    }
    

    private func sendNextFileChunk() throws {
        if cancelled {
            return
        }
        if currentTransfer == nil || currentTransfer?.currentOffset == currentTransfer?.totalBytes {
            if currentTransfer != nil && currentTransfer?.handle != nil {
                try currentTransfer?.handle?.close()
            }
            if queue.isEmpty {
                log("[OutboundNearbyConnection \(self.id)] Disconnecting because all files have been transferred")
                
                // Delay disconnection to ensure EOF frame is processed at peer
                NearbyConnection.dispatchQueue.asyncAfter(deadline: .now() + 0.5) {
                    do {
                        try self.sendDisconnectionAndDisconnect()
                        self.delegate?.transferFinished(connection: self)
                    }
                    catch {
                        log("[OutboundNearbyConnection \(self.id)] Error while sending disconnection: \(error)")
                    }
                }
                
                return
            }
            currentTransfer = queue.removeFirst()
        }

        let fileBuffer: Data
        guard let _fileBuffer = try currentTransfer!.handle!.read(upToCount: 512 * 1024) else {
            throw NearbyError.inputOutput
        }
        fileBuffer = _fileBuffer

        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadChunk.offset = currentTransfer!.currentOffset
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = fileBuffer
        transfer.payloadHeader.id = currentTransfer!.payloadID
        transfer.payloadHeader.type = .file
        transfer.payloadHeader.totalSize = Int64(currentTransfer!.totalBytes)
        transfer.payloadHeader.isSensitive = false
        transfer.payloadHeader.fileName = currentTransfer!.fileName
        currentTransfer!.currentOffset += Int64(fileBuffer.count)

        var wrapper = Location_Nearby_Connections_OfflineFrame()
        wrapper.version = .v1
        wrapper.v1 = Location_Nearby_Connections_V1Frame()
        wrapper.v1.type = .payloadTransfer
        wrapper.v1.payloadTransfer = transfer
        try encryptAndSendOfflineFrame(wrapper, completion: {
            do {
                try self.sendNextFileChunk()
            } catch {
                self.lastError = error
                self.protocolError()
            }
        })
        
        self.bytesTransferred += Int64(fileBuffer.count)
        
        startAndResetHeartbeatTimer()
        delegate?.updatedTransferProgress(connection: self, progress: Double(bytesTransferred) / Double(totalBytesToSend))

        if currentTransfer!.currentOffset == currentTransfer!.totalBytes {
            
            // Signal end of file
            var transfer = Location_Nearby_Connections_PayloadTransferFrame()
            transfer.packetType = .data
            transfer.payloadChunk.offset = currentTransfer!.currentOffset
            transfer.payloadChunk.flags = 1
            transfer.payloadHeader.id = currentTransfer!.payloadID
            transfer.payloadHeader.type = .file
            transfer.payloadHeader.totalSize = Int64(currentTransfer!.totalBytes)
            transfer.payloadHeader.isSensitive = false

            var wrapper = Location_Nearby_Connections_OfflineFrame()
            wrapper.version = .v1
            wrapper.v1 = Location_Nearby_Connections_V1Frame()
            wrapper.v1.type = .payloadTransfer
            wrapper.v1.payloadTransfer = transfer
            try encryptAndSendOfflineFrame(wrapper)
            log("[OutboundNearbyConnection \(self.id)] Sent EOF, current transfer: \(String(describing: currentTransfer))")
        }
    }

    
    private static func sanitizeFileName(name: String) -> String {
        return name.replacingOccurrences(of: "[\\/\\\\?%\\*:\\|\"<>=]", with: "_", options: .regularExpression)
    }
    
    
    // -- MARK: - Internal Data Model
    
    private struct OutgoingFileTransfer {
        let url: URL
        let fileName: String
        let payloadID: Int64
        let handle: FileHandle?
        let totalBytes: Int64
        var currentOffset: Int64
    }
}

private extension ReceiverAuthenticationPolicy {
    var expectedReceiverKeyFingerprint: String? {
        switch self {
        case .none:
            return nil
        case .trustedReceiver(let fingerprint), .bootstrapReceiverTrust(let fingerprint):
            return Self.normalizedFingerprint(fingerprint)
        }
    }

    var allowsReceiverTrustBootstrap: Bool {
        if case .bootstrapReceiverTrust = self {
            return true
        }
        return false
    }

    var requiresReceiverAuthentication: Bool {
        if case .none = self {
            return false
        }
        return true
    }

    static func normalizedFingerprint(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
