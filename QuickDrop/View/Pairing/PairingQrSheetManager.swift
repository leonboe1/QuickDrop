//
//  PairingQrSheetManager.swift
//  QuickDrop
//
//  Created by Leon Böttger on 2026-03-15.
//

import AppKit
import SwiftUI

final class PairingQrSheetManager: NSObject, NSWindowDelegate {
    static let shared = PairingQrSheetManager()

    private var alert: NSAlert?
    private weak var alertWindow: NSWindow?

    func open(
        token: String,
        receiverFingerprint: String,
        deviceName: String,
        useCase: PairingUseCase
    ) {
        guard alert == nil else { return }
        guard let qrImage = PairingToken.makeQrImage(
            token: token,
            receiverFingerprint: receiverFingerprint,
            useCase: useCase
        ) else { return }

        let alert = NSAlert()
        alert.messageText = "PairingQrSheetTitle".localized()
        alert.informativeText = "PairingQrSheetDescription".localized(with: deviceName)
        alert.addButton(withTitle: "Cancel".localized())
        alert.alertStyle = .informational

        let accessoryView = NSHostingView(rootView: PairingQrAccessoryView(qrImage: qrImage))
        accessoryView.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
        alert.accessoryView = accessoryView
        alert.layout()
        alert.buttons.forEach { button in
            button.target = self
            button.action = #selector(handleAlertButton(_:))
        }

        self.alert = alert
        let alertWindow = alert.window
        alertWindow.delegate = self
        self.alertWindow = alertWindow
        if let screen = NSApp.mainWindow?.screen ?? NSScreen.main {
            let frame = alertWindow.frame
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.midX - (frame.width / 2),
                y: screenFrame.midY - (frame.height / 2)
            )
            alertWindow.setFrameOrigin(origin)
        } else {
            alertWindow.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        alertWindow.makeKeyAndOrderFront(nil)
    }

    func close() {
        alertWindow?.close()
        alert = nil
        alertWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        alert = nil
        alertWindow = nil
    }

    @objc private func handleAlertButton(_ sender: NSButton) {
        close()
    }
}

private struct PairingQrAccessoryView: View {
    let qrImage: Image

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
            qrImage
                .resizable()
                .interpolation(.none)
                .aspectRatio(1, contentMode: .fit)
                .padding(10)
        }
        .frame(width: 160, height: 160)
    }
}
