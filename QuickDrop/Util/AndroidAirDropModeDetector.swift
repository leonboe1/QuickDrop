//
//  AndroidAirDropModeDetector.swift
//  QuickDrop
//
//  Created by Leon Böttger on 10.06.26.
//

import CoreBluetooth
import Foundation
import LUI

struct AndroidAirDropAdvertisement: Equatable {
    let rssi: Int
    let manufacturerDataHex: String?
    let serviceUUIDs: Set<String>

    init(rssi: Int, manufacturerDataHex: String?, serviceUUIDs: Set<String>) {
        self.rssi = rssi
        self.manufacturerDataHex = manufacturerDataHex?.lowercased()
        self.serviceUUIDs = Set(serviceUUIDs.map { $0.uppercased() })
    }
}

struct AndroidAirDropModeObservation: Equatable {
    let airDropModePacketCount: Int
    let strongestAirDropModeRSSI: Int?
    let minimumRSSI: Int
    let requiredPacketsPerSignal: Int

    var isDetected: Bool {
        airDropModePacketCount >= requiredPacketsPerSignal
    }
}

struct AndroidAirDropModeClassifier {
    static let defaultMinimumRSSI = -70
    static let defaultRequiredPacketsPerSignal = 2

    static let airDropModeManufacturerPrefix = "4c000512000000000000000001"
    static let airDropModeServiceUUID = "FCF1"

    let minimumRSSI: Int
    let requiredPacketsPerSignal: Int

    private(set) var airDropModePacketCount = 0
    private(set) var strongestAirDropModeRSSI: Int?

    init(
        minimumRSSI: Int = Self.defaultMinimumRSSI,
        requiredPacketsPerSignal: Int = Self.defaultRequiredPacketsPerSignal
    ) {
        self.minimumRSSI = minimumRSSI
        self.requiredPacketsPerSignal = requiredPacketsPerSignal
    }

    var observation: AndroidAirDropModeObservation {
        AndroidAirDropModeObservation(
            airDropModePacketCount: airDropModePacketCount,
            strongestAirDropModeRSSI: strongestAirDropModeRSSI,
            minimumRSSI: minimumRSSI,
            requiredPacketsPerSignal: requiredPacketsPerSignal
        )
    }

    mutating func reset() {
        airDropModePacketCount = 0
        strongestAirDropModeRSSI = nil
    }

    @discardableResult
    mutating func record(_ advertisement: AndroidAirDropAdvertisement) -> AndroidAirDropModeObservation {
        guard advertisement.rssi >= minimumRSSI else {
            return observation
        }

        if Self.isAirDropModeAdvertisement(advertisement) {
            airDropModePacketCount += 1
            strongestAirDropModeRSSI = Self.strongerRSSI(strongestAirDropModeRSSI, advertisement.rssi)
        }

        return observation
    }

    static func isAirDropModeAdvertisement(_ advertisement: AndroidAirDropAdvertisement) -> Bool {
        advertisement.manufacturerDataHex?.hasPrefix(airDropModeManufacturerPrefix) == true &&
        advertisement.serviceUUIDs.contains(airDropModeServiceUUID)
    }

    private static func strongerRSSI(_ current: Int?, _ candidate: Int) -> Int {
        guard let current else { return candidate }
        return max(current, candidate)
    }
}

final class AndroidAirDropModeDetector: NSObject, CBCentralManagerDelegate {
    static let shared = AndroidAirDropModeDetector()
    static let scanServiceUUIDs = [CBUUID(string: AndroidAirDropModeClassifier.airDropModeServiceUUID)]
    static let scanOptions: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]

    private var centralManager: CBCentralManager?
    private var classifier = AndroidAirDropModeClassifier()
    private var onDetected: ((AndroidAirDropModeObservation) -> Void)?
    private var isScanning = false
    private var hasDeliveredDetection = false

    func start(onDetected: @escaping (AndroidAirDropModeObservation) -> Void) {
        guard BluetoothPermissionManager.shared.isAllowed else {
            log("[AndroidAirDropModeDetector] Bluetooth permission is not granted; skipping scan. authorization=\(BluetoothPermissionManager.shared.authorization.rawValue)")
            return
        }

        self.onDetected = onDetected

        guard !hasDeliveredDetection else { return }
        guard !isScanning else { return }

        log("[AndroidAirDropModeDetector] Starting detector.")

        classifier.reset()

        if centralManager == nil {
            log("[AndroidAirDropModeDetector] Creating central manager.")
            centralManager = CBCentralManager(delegate: self, queue: .main)
        }
        else if centralManager?.state == .poweredOn {
            beginScanning()
        }
    }

    func stop() {
        log("[AndroidAirDropModeDetector] Stopping detector.")
        centralManager?.stopScan()
        classifier.reset()
        onDetected = nil
        hasDeliveredDetection = false
        isScanning = false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("[AndroidAirDropModeDetector] Central state changed: \(central.state.rawValue)")

        guard central.state == .poweredOn else {
            if isScanning {
                central.stopScan()
                isScanning = false
            }
            return
        }

        if onDetected != nil {
            beginScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !hasDeliveredDetection else { return }

        let advertisement = Self.advertisement(from: advertisementData, rssi: RSSI.intValue)
        let observation = classifier.record(advertisement)

        guard observation.isDetected else { return }

        hasDeliveredDetection = true
        isScanning = false
        central.stopScan()

        let callback = onDetected
        onDetected = nil

        log(
            "[AndroidAirDropModeDetector] Detected Android AirDrop-compatible sharing mode. " +
            "airDropModePackets=\(observation.airDropModePacketCount), " +
            "minimumRSSI=\(observation.minimumRSSI)"
        )

        callback?(observation)
    }

    private func beginScanning() {
        guard !isScanning, let centralManager, centralManager.state == .poweredOn else { return }

        log("[AndroidAirDropModeDetector] BLE scan started for service \(AndroidAirDropModeClassifier.airDropModeServiceUUID).")

        // Duplicate delivery is intentional: the classifier waits for repeated
        // matching packets so one transient advertisement does not trigger the alert.
        centralManager.scanForPeripherals(
            withServices: Self.scanServiceUUIDs,
            options: Self.scanOptions
        )
        isScanning = true
    }

    private static func advertisement(
        from advertisementData: [String: Any],
        rssi: Int
    ) -> AndroidAirDropAdvertisement {
        var serviceUUIDs = Set<String>()

        [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ].forEach { key in
            guard let uuids = advertisementData[key] as? [CBUUID] else { return }
            uuids.forEach { serviceUUIDs.insert($0.uuidString) }
        }

        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            serviceData.keys.forEach { serviceUUIDs.insert($0.uuidString) }
        }

        return AndroidAirDropAdvertisement(
            rssi: rssi,
            manufacturerDataHex: (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.androidAirDropModeHexString,
            serviceUUIDs: serviceUUIDs
        )
    }
}

private extension Data {
    var androidAirDropModeHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
