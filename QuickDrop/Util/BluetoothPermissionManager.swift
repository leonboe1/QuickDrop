//
//  BluetoothPermissionManager.swift
//  QuickDrop
//
//  Created by Leon Böttger on 31.05.26.
//

import Combine
import CoreBluetooth
import Foundation
import LUI

#if os(iOS) && !EXTENSION
import UIKit
#endif

#if os(macOS)
import AppKit
#endif

final class BluetoothPermissionManager: NSObject, ObservableObject, CBCentralManagerDelegate {

    static let shared = BluetoothPermissionManager()

    @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization

    private var centralManager: CBCentralManager?
    private var completion: ((Bool) -> Void)?

    var isAllowed: Bool {
        authorization == .allowedAlways
    }

    var canRequestPermission: Bool {
        authorization == .notDetermined
    }

    private override init() {
        super.init()
    }

    func refresh() {
        let currentAuthorization = CBManager.authorization
        guard authorization != currentAuthorization else { return }

        authorization = currentAuthorization
    }

    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        refresh()

        guard authorization == .notDetermined else {
            completion?(isAllowed)
            return
        }

        self.completion = completion
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refresh()

        guard authorization != .notDetermined else { return }

        let completion = completion
        self.completion = nil
        completion?(isAllowed)
    }

    func openSystemBluetoothSettings() {
        #if os(iOS) && !EXTENSION
        openAppSettings()
        #elseif os(macOS)
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"),
            URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")
        ].compactMap { $0 }

        if let url = urls.first {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
