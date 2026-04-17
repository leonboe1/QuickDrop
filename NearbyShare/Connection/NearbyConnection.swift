//
//  NearbyConnection.swift
//  QuickDrop
//
//  Created by Grishka on 09.04.2023.
//

import CommonCrypto
import CryptoKit
import Foundation
import Network
import System
import BigInt
import SwiftECC
import LUI

class NearbyConnection {
    
    private let maxFrameLength = 5 * 1024 * 1024
    static let dispatchQueue = DispatchQueue(label: "com.leonboettger.quickdrop.queue", qos: .utility)
    
    let id: String
    let connection: NWConnection
    
    var remoteDeviceInfo: RemoteDeviceInfo?
    var encryptionDone: Bool = false
    var lastError: Error?
    var bytesTransferred: Int64 = 0
    var cancelled: Bool = false
    var isTransferring: Bool = false {
        didSet {
            dataTransferInactivityTimer?.cancel()
            dataTransferInactivityTimer = nil
            
            if isTransferring {
                log("[NearbyConnection \(self.id)] Now transferring. Setting up data transfer inactivity timer.")
                startDataTransferTimer(previousBytesTransferred: bytesTransferred)
            }
        }
    }
    
    private var payloadBuffers: [Int64: NSMutableData] = [:]
    private var connectionClosed: Bool = false
    
    private var inactivityTimer: DispatchSourceTimer?
    private var dataTransferInactivityTimer: DispatchSourceTimer?
    
    private let ackInterval: TimeInterval = 5
    private let ackTimeoutInterval: TimeInterval = 60
    private var lastKeepAliveFrameSent = Date()
    
    // UKEY2-related state
    var privateKey: ECPrivateKey?
    var ukeyClientInitMsgData: Data?
    var ukeyServerInitMsgData: Data?
    
    // SecureMessage encryption keys
    var decryptKey: [UInt8]?
    var encryptKey: [UInt8]?
    var recvHmacKey: SymmetricKey?
    var sendHmacKey: SymmetricKey?
    
    // SecureMessage sequence numbers
    private var serverSeq: Int32 = 0
    private var clientSeq: Int32 = 0
    
    private(set) var pinCode: String?
    private(set) var authKey: SymmetricKey?
    
    
    init(connection: NWConnection, id: String) {
        self.connection = connection
        self.id = id
    }
    
    
    func start() {
        
        log("[NearbyConnection \(self.id)] Starting connection.")
        
        connection.stateUpdateHandler = { state in
            
            if !self.connectionClosed {
                if case .ready = state {
                    self.connectionReady()
                    self.receiveFrameAsync()
                } else if case let .failed(err) = state {

                    // If connection reset by peer, it could still be a valid file transfer that has not been processed yet. => Wait
                    if err == .posix(.ECONNRESET) {
                        
                        log("[NearbyConnection \(self.id)] Network connection reset error detected.")
                        self.connectionClosedByPeer {
                            recordErrorAndDisconnect(err: err)
                        }
                    }
                    else {
                        recordErrorAndDisconnect(err: err)
                    }
                }
            }
            else {
                log("[NearbyConnection \(self.id)] Connection already closed, ignoring state update: \(state)")
            }
        }

        connection.start(queue: NearbyConnection.dispatchQueue)
        
        func recordErrorAndDisconnect(err: NWError) {
            self.lastError = err
            log("[NearbyConnection \(self.id)] Connection Error: \(err)")
            
            // If the error is a connection reset, it could be due to firewall issues.
            if err == .posix(.ENOTCONN) {
                log("[NearbyConnection \(self.id)] Network not connected error detected (firewall likely).")
                self.lastError = NearbyError.firewallError
            }
            
            if err == .posix(.ENETDOWN) {
                log("[NearbyConnection \(self.id)] Network down error detected.")
                self.lastError = NearbyError.protocolError("Error.NetworkDown".localized())
            }
            
            self.disconnect()
        }
    }
    
    
    func connectionClosedByPeer(onError: @escaping () -> Void) {
        NearbyConnection.dispatchQueue.asyncAfter(deadline: .now() + 1) {
            
            // If already closed, ignore the error, as file transfer has been processed
            if !self.connectionClosed {
                onError()
            }
        }
    }
    
    
    func connectionReady() {}
    
    
    func protocolError() {
        log("[NearbyConnection \(self.id)] Protocol error: \(String(describing: lastError))")
        disconnect()
    }
    
    
    func processReceivedFrame(frameData _: Data) {
        fatalError()
    }
    
    
    func processTransferSetupFrame(_: Sharing_Nearby_Frame) throws {
        fatalError()
    }
    
    
    func isServer() -> Bool {
        fatalError()
    }
    
    
    func processFileChunk(frame _: Location_Nearby_Connections_PayloadTransferFrame) throws {
        protocolError()
    }
    
    
    func processBytesPayload(payload _: Data, id _: Int64) throws -> Bool {
        return false
    }
    
    
    private func receiveFrameAsync() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, isComplete, error in
            if self.connectionClosed {
                log("[NearbyConnection \(self.id)] Received FIN from peer, connection closed.")
                self.connection.cancel()
                return
            }
            if isComplete {
                log("[NearbyConnection \(self.id)] Connection closed by peer during receiveFrameAsync()")
                self.connectionClosedByPeer {
                    self.lastError = NearbyError.protocolError("Error.ClosedByPeer".localized())
                    self.disconnect()
                    self.connection.cancel()
                }
                return
            }
            if !(error == nil) {
                log("[NearbyConnection \(self.id)] Error during receiveFrameAsync(): \(String(describing: error))")
                self.lastError = error
                self.protocolError()
                return
            }
            guard let content = content else {
                log("[NearbyConnection \(self.id)] Received nil content during receiveFrameAsync(). IsComplete: \(isComplete)")
                self.lastError = NearbyError.protocolError("Received empty frame header")
                self.protocolError()
                return
            }
            guard content.count == 4 else {
                log("[NearbyConnection \(self.id)] Received invalid frame header size \(content.count), expected 4")
                self.lastError = NearbyError.protocolError("Unexpected frame header length")
                self.protocolError()
                return
            }
            let frameLength = UInt32(content[0]) << 24 | UInt32(content[1]) << 16 | UInt32(content[2]) << 8 | UInt32(content[3])
            guard frameLength < self.maxFrameLength else {
                self.lastError = NearbyError.protocolError("Unexpected packet length")
                self.protocolError()
                return
            }
            
            self.startAndResetHeartbeatTimer()
            self.receiveFrameAsync(length: frameLength)
        }
    }
    
    
    private func receiveFrameAsync(length: UInt32) {
        connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [self] content, _, isComplete, error in
            if self.connectionClosed {
                log("[NearbyConnection \(self.id)] Received FIN from peer, connection closed.")
                connection.cancel()
                return
            }
            if isComplete {
                log("[NearbyConnection \(self.id)] Connection closed by peer during receiveFrameAsync(length:)")
                
                if let content = content, !content.isEmpty {
                    log("[NearbyConnection \(self.id)] Connection closed by peer during receiveFrameAsync(length:), and frame not empty. Frame length: \(content.count)")
                    
                    if content.count == Int(length) {
                        self.processReceivedFrame(frameData: content)
                    }
                    else {
                        log("[NearbyConnection \(self.id)] Dropping trailing partial frame during connection close. Expected \(length) bytes, got \(content.count)")
                    }
                }
                else {
                    log("[NearbyConnection \(self.id)] Connection closed by peer during receiveFrameAsync(length:), but no content received anymore (\(String(describing: content))).")
                }
                
                self.connectionClosedByPeer {
                    self.lastError = NearbyError.protocolError("Error.ClosedByPeer".localized())
                    self.disconnect()
                    self.connection.cancel()
                }
                
                return
            }
            if let error = error {
                log("[NearbyConnection \(self.id)] Error during receiveFrameAsync(length:): \(error)")
                self.lastError = error
                self.protocolError()
                return
            }
            guard let content = content else {
                log("[NearbyConnection \(self.id)] Received nil content during receiveFrameAsync(length:). IsComplete: \(isComplete)")
                self.protocolError()
                return
            }
            guard content.count == Int(length) else {
                log("[NearbyConnection \(self.id)] Dropping partial frame body. Expected \(length) bytes, got \(content.count)")
                self.lastError = NearbyError.protocolError("Unexpected frame body length")
                self.protocolError()
                return
            }
            
            self.startAndResetHeartbeatTimer()
            self.processReceivedFrame(frameData: content)
            self.receiveFrameAsync()
        }
    }
    
    
    func sendFrameAsync(_ frame: Data, completion: (() -> Void)? = nil) {
        if connectionClosed {
            return
        }
        var lengthPrefixedData = Data(capacity: frame.count + 4)
        let length: Int = frame.count
        lengthPrefixedData.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        lengthPrefixedData.append(frame)
        connection.send(content: lengthPrefixedData, completion: .contentProcessed { error in
            if let error = error {
                log("[NearbyConnection \(self.id)] Error while sending frame: \(error)")
            }
            if let completion = completion {
                completion()
            }
        })
    }
    
    
    func encryptAndSendOfflineFrame(_ frame: Location_Nearby_Connections_OfflineFrame, completion: (() -> Void)? = nil) throws {
        var d2dMsg = Securegcm_DeviceToDeviceMessage()
        serverSeq += 1
        d2dMsg.sequenceNumber = serverSeq
        d2dMsg.message = try frame.serializedData()
        
        let serializedMsg = try [UInt8](d2dMsg.serializedData())
        let iv = Data.randomData(length: 16)
        var encryptedData = Data(count: serializedMsg.count + 16)
        var encryptedLength: size_t = 0
        encryptedData.withUnsafeMutableBytes {
            let status = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                encryptKey, kCCKeySizeAES256,
                [UInt8](iv),
                serializedMsg, serializedMsg.count,
                $0.baseAddress, $0.count,
                &encryptedLength
            )
            guard status == kCCSuccess else { fatalError("CCCrypt error: \(status)") }
        }
        
        var hb = Securemessage_HeaderAndBody()
        hb.body = encryptedData.prefix(encryptedLength)
        hb.header = Securemessage_Header()
        hb.header.encryptionScheme = .aes256Cbc
        hb.header.signatureScheme = .hmacSha256
        hb.header.iv = iv
        var md = Securegcm_GcmMetadata()
        md.type = .deviceToDeviceMessage
        md.version = 1
        hb.header.publicMetadata = try md.serializedData()
        
        var smsg = Securemessage_SecureMessage()
        smsg.headerAndBody = try hb.serializedData()
        smsg.signature = Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: sendHmacKey!))
        try sendFrameAsync(smsg.serializedData(), completion: completion)
    }
    
    
    func sendTransferSetupFrame(_ frame: Sharing_Nearby_Frame) throws {
        log("[NearbyConnection \(self.id)] Sending transfer setup frame.")
        try sendBytesPayload(data: frame.serializedData(), id: Int64.random(in: Int64.min ... Int64.max))
    }
    
    
    func sendBytesPayload(data: Data, id: Int64) throws {
        
        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadChunk.offset = 0
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = data
        transfer.payloadHeader.id = id
        transfer.payloadHeader.type = .bytes
        transfer.payloadHeader.totalSize = Int64(transfer.payloadChunk.body.count)
        transfer.payloadHeader.isSensitive = false
        
        var wrapper = Location_Nearby_Connections_OfflineFrame()
        wrapper.version = .v1
        wrapper.v1 = Location_Nearby_Connections_V1Frame()
        wrapper.v1.type = .payloadTransfer
        wrapper.v1.payloadTransfer = transfer
        try encryptAndSendOfflineFrame(wrapper)
        
        transfer.payloadChunk.flags = 1 // .lastChunk
        transfer.payloadChunk.offset = Int64(transfer.payloadChunk.body.count)
        transfer.payloadChunk.clearBody()
        wrapper.v1.payloadTransfer = transfer
        try encryptAndSendOfflineFrame(wrapper)
    }
    
    
    func decryptAndProcessReceivedSecureMessage(_ smsg: Securemessage_SecureMessage) throws {
        guard smsg.hasSignature, smsg.hasHeaderAndBody else { throw NearbyError.requiredFieldMissing("secureMessage.signature|headerAndBody") }
        
        let hmac = Data(HMAC<SHA256>.authenticationCode(for: smsg.headerAndBody, using: recvHmacKey!))
        guard hmac == smsg.signature else { throw NearbyError.protocolError("Error.Signature".localized()) }
        
        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: smsg.headerAndBody)
        var decryptedData = Data(count: headerAndBody.body.count)
        
        var decryptedLength = 0
        decryptedData.withUnsafeMutableBytes {
            let status = CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                decryptKey, kCCKeySizeAES256,
                [UInt8](headerAndBody.header.iv),
                [UInt8](headerAndBody.body), headerAndBody.body.count,
                $0.baseAddress, $0.count,
                &decryptedLength
            )
            guard status == kCCSuccess else { fatalError("CCCrypt error: \(status)") }
        }
        
        decryptedData = decryptedData.prefix(decryptedLength)
        let d2dMsg = try Securegcm_DeviceToDeviceMessage(serializedBytes: decryptedData)
        
        guard d2dMsg.hasMessage, d2dMsg.hasSequenceNumber else { throw NearbyError.requiredFieldMissing("d2dMessage.message|sequenceNumber") }
        let receivedSeq = d2dMsg.sequenceNumber
        let expectedSeq = clientSeq + 1
        
        if receivedSeq == expectedSeq {
            clientSeq = receivedSeq
        } else if receivedSeq <= clientSeq {
            log("[NearbyConnection \(self.id)] Ignoring duplicate/stale frame sequence \(receivedSeq). Current sequence is \(clientSeq)")
            return
        } else {
            throw NearbyError.protocolError("Wrong sequence number. Expected \(expectedSeq), got \(receivedSeq)")
        }
        let offlineFrame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: d2dMsg.message)
        
        if offlineFrame.hasV1, offlineFrame.v1.hasType, case .payloadTransfer = offlineFrame.v1.type {
            
            guard offlineFrame.v1.hasPayloadTransfer else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.payloadTransfer") }
            
            let payloadTransfer = offlineFrame.v1.payloadTransfer
            let header = payloadTransfer.payloadHeader
            let chunk = payloadTransfer.payloadChunk
            
            guard header.hasType, header.hasID else { throw NearbyError.requiredFieldMissing("payloadHeader.type|id") }

            if payloadTransfer.hasPayloadChunk {
                guard chunk.hasOffset, chunk.hasFlags else {
                    log("[NearbyConnection \(self.id)] Payload transfer chunk is missing offset or flags. Frame is \(payloadTransfer.debugDescription)")
                    throw NearbyError.requiredFieldMissing("payloadChunk.offset|flags")
                }
            } else if payloadTransfer.hasControlMessage || payloadTransfer.packetType == .control {
                switch payloadTransfer.controlMessage.event {
                case .payloadCanceled:
                    log("[NearbyConnection \(self.id)] Cancel control frame received.")
                    throw NearbyError.canceled(reason: .userCanceled)
                case .payloadReceivedAck:
                    // Legacy peers can send ACKs as control events instead of packetType=.payloadAck.
                    return
                case .payloadError:
                    throw NearbyError.protocolError("Peer reported payload error")
                case .unknownEventType:
                    return
                }
            } else if payloadTransfer.packetType == .payloadAck {
                return
            } else {
                log("[NearbyConnection \(self.id)] Payload transfer frame missing supported payload content. Frame is \(payloadTransfer.debugDescription)")
                throw NearbyError.requiredFieldMissing("payloadChunk.offset|flags")
            }
            
            if case .bytes = header.type {
                
                let payloadID = header.id
                
                if header.totalSize > maxFrameLength {
                    
                    payloadBuffers.removeValue(forKey: payloadID)
                    throw NearbyError.protocolError("Payload too large (\(header.totalSize) bytes)")
                }
                
                if payloadBuffers[payloadID] == nil {
                    
                    payloadBuffers[payloadID] = NSMutableData(capacity: Int(header.totalSize))
                }
                
                let buffer = payloadBuffers[payloadID]!
                
                guard chunk.offset == buffer.count else {
                    payloadBuffers.removeValue(forKey: payloadID)
                    throw NearbyError.protocolError("Unexpected chunk offset \(chunk.offset), expected \(buffer.count)")
                }
                
                if chunk.hasBody {
                    buffer.append(chunk.body)
                }
                
                if (chunk.flags & 1) == 1 {
                    payloadBuffers.removeValue(forKey: payloadID)
                    if try !processBytesPayload(payload: Data(buffer), id: payloadID) {
                        let innerFrame = try Sharing_Nearby_Frame(serializedBytes: buffer as Data)
                        try processTransferSetupFrame(innerFrame)
                    }
                }
                
            } else if case .file = header.type {
                
                try processFileChunk(frame: payloadTransfer)
            }
        }
        else if offlineFrame.hasV1, offlineFrame.v1.hasType, case .keepAlive = offlineFrame.v1.type {
            if offlineFrame.v1.hasKeepAlive {
                let keepAlive = offlineFrame.v1.keepAlive
                if !keepAlive.hasAck || !keepAlive.ack {
                    sendKeepAlive(ack: true)
                }
            } else {
                // Older peers can omit the keepAlive payload; default to ACK reply.
                sendKeepAlive(ack: true)
            }
        } else if offlineFrame.hasV1, offlineFrame.v1.hasType, case .disconnection = offlineFrame.v1.type {
            log("[NearbyConnection \(self.id)] Received disconnection frame.")
            disconnect()
        } else {
            
            if offlineFrame.hasV1, offlineFrame.v1.hasType, offlineFrame.v1.type == .bandwidthUpgradeRetry {
                // only supporting WiFi for now, ignore upgrade request to other mediums
                return
            }
            
            log("[NearbyConnection \(self.id)] Unhandled offline frame encrypted: \(offlineFrame)")
        }
    }
    
    
    static func pinCodeFromAuthKey(_ key: SymmetricKey) -> String {
        var hash = 0
        var multiplier = 1
        let keyBytes: [UInt8] = key.withUnsafeBytes {
            [UInt8]($0)
        }
        
        for _byte in keyBytes {
            let byte = Int(Int8(bitPattern: _byte))
            hash = (hash + byte * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        
        return String(format: "%04d", abs(hash))
    }
    
    
    func finalizeKeyExchange(peerKey: Securemessage_GenericPublicKey) throws {
        guard peerKey.hasEcP256PublicKey else { throw NearbyError.requiredFieldMissing("peerKey.ecP256PublicKey") }
        
        let domain = Domain.instance(curve: .EC256r1)
        let clientX = peerKey.ecP256PublicKey.x.ensureLength(length: 32)
        let clientY = peerKey.ecP256PublicKey.y.ensureLength(length: 32)
        let key = try ECPublicKey(domain: domain, w: Point(BInt(magnitude: [UInt8](clientX)), BInt(magnitude: [UInt8](clientY))))
        
        let dhsRaw = try (privateKey?.domain.multiplyPoint(key.w, privateKey!.s).x.asMagnitudeBytes())!
        let dhs = Data(dhsRaw).ensureLength(length: 32)
        var sha = SHA256()
        sha.update(data: dhs)
        let derivedSecretKey = Data(sha.finalize())
        
        var ukeyInfo = Data()
        ukeyInfo.append(ukeyClientInitMsgData!)
        ukeyInfo.append(ukeyServerInitMsgData!)
        let authenticationSecret = HKDF.deriveKey(ikm: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 auth".data(using: .utf8)!, info: ukeyInfo, outputLength: 32)
        let nextSecret = HKDF.deriveKey(ikm: SymmetricKey(data: derivedSecretKey), salt: "UKEY2 v1 next".data(using: .utf8)!, info: ukeyInfo, outputLength: 32)
        
        authKey = authenticationSecret
        pinCode = NearbyConnection.pinCodeFromAuthKey(authenticationSecret)
        
        sha = SHA256()
        sha.update(data: "D2D".data(using: .utf8)!)
        let salt = Data(sha.finalize())
        
        let d2dClientKey = HKDF.deriveKey(ikm: nextSecret, salt: salt, info: "client".data(using: .utf8)!, outputLength: 32)
        let d2dServerKey = HKDF.deriveKey(ikm: nextSecret, salt: salt, info: "server".data(using: .utf8)!, outputLength: 32)
        
        sha = SHA256()
        sha.update(data: "SecureMessage".data(using: .utf8)!)
        let smsgSalt = Data(sha.finalize())
        
        let clientKey = HKDF.deriveBytes(ikm: d2dClientKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputLength: 32)
        let clientHmacKey = HKDF.deriveKey(ikm: d2dClientKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputLength: 32)
        let serverKey = HKDF.deriveBytes(ikm: d2dServerKey, salt: smsgSalt, info: "ENC:2".data(using: .utf8)!, outputLength: 32)
        let serverHmacKey = HKDF.deriveKey(ikm: d2dServerKey, salt: smsgSalt, info: "SIG:1".data(using: .utf8)!, outputLength: 32)
        
        if isServer() {
            decryptKey = clientKey
            recvHmacKey = clientHmacKey
            encryptKey = serverKey
            sendHmacKey = serverHmacKey
        } else {
            decryptKey = serverKey
            recvHmacKey = serverHmacKey
            encryptKey = clientKey
            sendHmacKey = clientHmacKey
        }
    }
    
    
    func cancel() {
        cancelled = true
        if encryptionDone {
            var cancel = Sharing_Nearby_Frame()
            cancel.version = .v1
            cancel.v1 = Sharing_Nearby_V1Frame()
            cancel.v1.type = .cancel
            try? sendTransferSetupFrame(cancel)
        }
        try? sendDisconnectionAndDisconnect()
    }
    
    
    func disconnect() {
        log("[NearbyConnection \(self.id)] Disconnecting from connection.")
        
        connection.stateUpdateHandler = nil
        inactivityTimer?.cancel()
        inactivityTimer = nil
        dataTransferInactivityTimer?.cancel()
        dataTransferInactivityTimer = nil
        connectionClosed = true
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
    }
    
    
    func sendDisconnectionAndDisconnect() throws {
        var offlineFrame = Location_Nearby_Connections_OfflineFrame()
        offlineFrame.version = .v1
        offlineFrame.v1.type = .disconnection
        offlineFrame.v1.disconnection = Location_Nearby_Connections_DisconnectionFrame()

        if connectionClosed {
            disconnect()
            return
        }

        let finishDisconnect: () -> Void = {
            log("[NearbyConnection \(self.id)] Sent disconnection frame during sendDisconnectionAndDisconnect")
            self.disconnect()
        }
        
        if encryptionDone {
            try encryptAndSendOfflineFrame(offlineFrame, completion: finishDisconnect)
        } else {
            let data = try offlineFrame.serializedData()
            sendFrameAsync(data, completion: finishDisconnect)
        }
    }
    
    
    func sendUkey2Alert(type: Securegcm_Ukey2Alert.AlertType) {
        var alert = Securegcm_Ukey2Alert()
        alert.type = type
        var msg = Securegcm_Ukey2Message()
        msg.messageType = .alert
        msg.messageData = try! alert.serializedData()
        sendFrameAsync(try! msg.serializedData())
        
        log("[NearbyConnection \(self.id)] Sent UKEY2 alert: \(type)")
        disconnect()
    }
    
    
    func sendKeepAlive(ack: Bool) {
        var offlineFrame = Location_Nearby_Connections_OfflineFrame()
        offlineFrame.version = .v1
        offlineFrame.v1.type = .keepAlive
        offlineFrame.v1.keepAlive.ack = ack
        
        do {
            if encryptionDone {
                try encryptAndSendOfflineFrame(offlineFrame)
            } else {
                try sendFrameAsync(offlineFrame.serializedData())
            }
            
            self.lastKeepAliveFrameSent = Date()
        } catch {
            log("[NearbyConnection \(self.id)] Error sending KEEP_ALIVE: \(error)")
        }
        
        log("[NearbyConnection \(self.id)] Sent keep-alive \(ack ? "ack" : "no ack"), \(self.bytesTransferred) bytes (\(Double(bytesTransferred) / 1_000_000_000) GB) sent")
    }
    
    
    func startAndResetHeartbeatTimer() {
        if connectionClosed {
            return
        }
        
        if encryptionDone && lastKeepAliveFrameSent.isOlderThan(seconds: ackInterval) {
            sendKeepAlive(ack: false)
        }
        
        // Cancel previous timer if any
        inactivityTimer?.cancel()
        
        inactivityTimer = DispatchSource.makeTimerSource(queue: NearbyConnection.dispatchQueue)
        inactivityTimer?.schedule(deadline: .now() + ackTimeoutInterval)
        inactivityTimer?.setEventHandler { [weak self] in
            
            guard let self = self else { return }
            
            if !self.connectionClosed {
                log("[NearbyConnection \(self.id)] Connection timeout: No message received in \(self.ackTimeoutInterval) seconds")
                self.lastError = NearbyError.canceled(reason: .timedOut)
                self.disconnect()
            }
        }
        
        inactivityTimer?.resume()
    }
    
    
    func startDataTransferTimer(previousBytesTransferred: Int64) {
        dataTransferInactivityTimer?.cancel()
        
        dataTransferInactivityTimer = DispatchSource.makeTimerSource(queue: NearbyConnection.dispatchQueue)
        dataTransferInactivityTimer?.schedule(deadline: .now() + ackTimeoutInterval)
        dataTransferInactivityTimer?.setEventHandler { [weak self] in
            
            guard let self = self else { return }
            guard !self.connectionClosed, self.isTransferring else { return }
            
            if previousBytesTransferred < self.bytesTransferred {
                // everything good, transferred more than last check, schedule next check
                self.startDataTransferTimer(previousBytesTransferred: self.bytesTransferred)
            }
            else {
                // connection stale, need to abort
                log("[NearbyConnection \(self.id)] Connection timeout: No more data received in \(self.ackTimeoutInterval) seconds")
                self.lastError = NearbyError.canceled(reason: .timedOut)
                self.disconnect()
            }
        }
        
        dataTransferInactivityTimer?.resume()
    }
    
    
    // -- MARK: - Internal Data Model
    
    struct InternalFileInfo {
        let meta: FileMetadata
        let payloadID: Int64
        let destinationURL: URL
        var bytesTransferred: Int64 = 0
        var fileHandle: FileHandle?
        var progress: Progress?
        var created: Bool = false
    }
}
