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

    @Test
    func scansOnlyForAirDropModeServiceAndAllowsDuplicatePackets() {
        #expect(AndroidAirDropModeDetector.scanServiceUUIDs.map(\.uuidString) == [AndroidAirDropModeClassifier.airDropModeServiceUUID])
        #expect(AndroidAirDropModeDetector.scanOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool == true)
    }
}

private extension AndroidAirDropAdvertisement {
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
        serviceUUIDs: Set<String>
    ) -> Self {
        AndroidAirDropAdvertisement(
            rssi: rssi,
            manufacturerDataHex: manufacturerDataHex,
            serviceUUIDs: serviceUUIDs
        )
    }
}
