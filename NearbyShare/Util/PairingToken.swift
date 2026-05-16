//
//  PairingToken.swift
//  QuickDrop
//
//  Created by Leon Böttger on 2026-03-15.
//

import Foundation
import QRCode
import SwiftUI
import LUI

enum PairingToken {
    static func generate() -> String {
        Data.randomData(length: 16).urlSafeBase64EncodedString()
    }

    static func receiverFingerprintHex() -> String? {
        guard let keyId = IdentityManager.shared.getPublicKey()?.toGenericPublicKey().id() else {
            return nil
        }
        return keyId.hex.lowercased()
    }

    static func qrPayload(token: String, receiverFingerprint: String, useCase: PairingUseCase) -> String {
        "quickdrop://pair?token=\(token)&usecase=\(useCase.rawValue)&receiver=\(receiverFingerprint)"
    }

    static func makeQrImage(
        token: String,
        receiverFingerprint: String,
        useCase: PairingUseCase,
        foregroundColor: CGColor = CGColor(gray: 0, alpha: 1),
        backgroundColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ) -> Image? {
        let payload = qrPayload(token: token, receiverFingerprint: receiverFingerprint, useCase: useCase)
        do {
            let qrCodeImage = try QRCode.build
                .text(payload)
                .foregroundColor(foregroundColor)
                .backgroundColor(backgroundColor)
                .quietZonePixelCount(3)
                .onPixels.shape(.circle())
                .eye.shape(.squircle())
                .errorCorrection(.low)
                .generate
                .image(dimension: 1000)
            return Image(decorative: qrCodeImage, scale: 1.0, orientation: .up)
        } catch {
            log("[PairingToken] QR code generation failed: \(error)")
            return nil
        }
    }
}
