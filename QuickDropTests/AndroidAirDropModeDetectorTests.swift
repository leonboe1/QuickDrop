import Foundation
import CoreBluetooth
import Testing
@testable import QuickDrop

@Suite(.serialized)
struct AndroidAirDropModeDetectorTests {
    @Test
    func detectsWhenAirDropModeSignalsPassThreshold() {
        var classifier = AndroidAirDropModeClassifier(minimumRSSI: -70, requiredPacketsPerSignal: 2)

        let firstAirDropMode = classifier.record(.airDropMode(rssi: -58))
        #expect(!firstAirDropMode.isDetected)

        let detected = classifier.record(.airDropMode(rssi: -56))
        #expect(detected.isDetected)
        #expect(detected.airDropModePacketCount == 2)
        #expect(detected.strongestAirDropModeRSSI == -56)
    }

    @Test
    func matchesObservedMoseyAirDropSuffixVariants() {
        #expect(
            AndroidAirDropModeClassifier.isAirDropModeAdvertisement(
                .airDropMode(manufacturerDataSuffix: "28b429412f624af300", rssi: -58)
            )
        )
        #expect(
            AndroidAirDropModeClassifier.isAirDropModeAdvertisement(
                .airDropMode(manufacturerDataSuffix: "03b429412f624af300", rssi: -58)
            )
        )
    }

    @Test
    func ignoresSignalsBelowRSSIThreshold() {
        var classifier = AndroidAirDropModeClassifier(minimumRSSI: -70, requiredPacketsPerSignal: 2)

        classifier.record(.airDropMode(rssi: -72))
        let observation = classifier.record(.airDropMode(rssi: -85))

        #expect(!observation.isDetected)
        #expect(observation.airDropModePacketCount == 0)
    }

    #if os(iOS)
    @Test
    func iOSDetectsNonConnectableFCF1AdvertisementsWithoutServiceData() {
        var classifier = AndroidAirDropModeClassifier(minimumRSSI: -70, requiredPacketsPerSignal: 2)

        let firstAirDropMode = classifier.record(.iOSAirDropMode(rssi: -62))
        #expect(!firstAirDropMode.isDetected)

        let detected = classifier.record(.iOSAirDropMode(rssi: -61))
        #expect(detected.isDetected)
        #expect(detected.airDropModePacketCount == 2)
        #expect(detected.strongestAirDropModeRSSI == -61)
    }

    @Test
    func iOSIgnoresBackgroundFCF1AdvertisementsWithServiceData() {
        var classifier = AndroidAirDropModeClassifier(minimumRSSI: -70, requiredPacketsPerSignal: 1)

        classifier.record(.iOSBackgroundFCF1(rssi: -55))
        let observation = classifier.record(.iOSBackgroundFCF1(rssi: -56))

        #expect(!observation.isDetected)
        #expect(observation.airDropModePacketCount == 0)
    }
    #else
    @Test
    func ignoresNearbyAppleAndBackgroundFCF1Advertisements() {
        var classifier = AndroidAirDropModeClassifier(minimumRSSI: -70, requiredPacketsPerSignal: 1)

        classifier.record(.advertisement(rssi: -50, manufacturerDataHex: "4c001006031dc4e5be78", serviceUUIDs: []))
        classifier.record(.advertisement(rssi: -55, manufacturerDataHex: nil, serviceUUIDs: ["FCF1"]))
        classifier.record(.advertisement(rssi: -56, manufacturerDataHex: "4c00051200000000000000000128b429412f624af300", serviceUUIDs: []))
        let observation = classifier.record(
            .advertisement(
                rssi: -56,
                manufacturerDataHex: "4c00051200000000000000000028b429412f624af300",
                serviceUUIDs: ["FCF1"]
            )
        )

        #expect(!observation.isDetected)
        #expect(observation.airDropModePacketCount == 0)
    }
    #endif

    @Test
    func scansOnlyForAirDropModeServiceAndAllowsDuplicatePackets() {
        #expect(AndroidAirDropModeDetector.scanServiceUUIDs.map(\.uuidString) == [AndroidAirDropModeClassifier.airDropModeServiceUUID])
        #expect(AndroidAirDropModeDetector.scanOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool == true)
    }
}

private extension AndroidAirDropAdvertisement {
    static func iOSAirDropMode(rssi: Int) -> Self {
        advertisement(
            rssi: rssi,
            manufacturerDataHex: nil,
            serviceUUIDs: ["FCF1"],
            isConnectable: false
        )
    }

    static func iOSBackgroundFCF1(rssi: Int) -> Self {
        advertisement(
            rssi: rssi,
            manufacturerDataHex: nil,
            serviceUUIDs: ["FCF1"],
            serviceDataHexByUUID: ["FCF1": "0407329497cd97ce4739a79920b877a45bb8d6d1a7"],
            isConnectable: true
        )
    }

    static func airDropMode(rssi: Int) -> Self {
        airDropMode(manufacturerDataSuffix: "28b429412f624af300", rssi: rssi)
    }

    static func airDropMode(manufacturerDataSuffix: String, rssi: Int) -> Self {
        advertisement(
            rssi: rssi,
            manufacturerDataHex: "4c000512000000000000000001\(manufacturerDataSuffix)",
            serviceUUIDs: ["FCF1"]
        )
    }

    static func advertisement(
        rssi: Int,
        manufacturerDataHex: String?,
        serviceUUIDs: Set<String>,
        serviceDataHexByUUID: [String: String] = [:],
        isConnectable: Bool? = nil
    ) -> Self {
        AndroidAirDropAdvertisement(
            rssi: rssi,
            manufacturerDataHex: manufacturerDataHex,
            serviceUUIDs: serviceUUIDs,
            serviceDataHexByUUID: serviceDataHexByUUID,
            isConnectable: isConnectable
        )
    }
}
