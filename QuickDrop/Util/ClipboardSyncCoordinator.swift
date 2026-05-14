//
//  ClipboardSyncCoordinator.swift
//  QuickDrop
//

#if os(macOS) && !EXTENSION

import AppKit
import Foundation
import LUI

final class ClipboardSyncCoordinator {
    static let shared = ClipboardSyncCoordinator()

    private let pollInterval: TimeInterval = 1
    private let transferTimeout: TimeInterval = 75

    private var pollTimer: Timer?
    private var lastObservedChangeCount: Int
    private var suppressedClipboardText: String?
    private var startedOwnDiscovery = false
    private var activeTransfersByFingerprint: [String: ClipboardSyncTransferDelegate] = [:]
    private var queuedTextByFingerprint: [String: String] = [:]

    private init() {
        lastObservedChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard pollTimer == nil else { return }

        let manager = NearbyConnectionManager.shared
        if !manager.isDeviceDiscoveryActive {
            startedOwnDiscovery = true
            manager.startDeviceDiscovery()
        }

        lastObservedChangeCount = NSPasteboard.general.changeCount
        log("[ClipboardSyncCoordinator] Starting clipboard watcher at changeCount=\(lastObservedChangeCount)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
    }

    func stop() {
        guard pollTimer != nil else { return }

        log("[ClipboardSyncCoordinator] Stopping clipboard watcher")
        pollTimer?.invalidate()
        pollTimer = nil
        suppressedClipboardText = nil
        activeTransfersByFingerprint.values.forEach { $0.cancelTimeout() }
        activeTransfersByFingerprint.removeAll()
        queuedTextByFingerprint.removeAll()

        guard startedOwnDiscovery else { return }
        startedOwnDiscovery = false
        NearbyConnectionManager.shared.stopDeviceDiscovery()
    }

    func suppressNextClipboardSync(for text: String) {
        if Thread.isMainThread {
            setSuppressedClipboardText(text)
        } else {
            DispatchQueue.main.sync {
                setSuppressedClipboardText(text)
            }
        }
    }

    private func setSuppressedClipboardText(_ text: String) {
        log("[ClipboardSyncCoordinator] Suppressing next clipboard sync for incoming text with \(text.utf8.count) bytes")
        suppressedClipboardText = text
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastObservedChangeCount else { return }

        log("[ClipboardSyncCoordinator] Clipboard change detected: \(lastObservedChangeCount) -> \(currentChangeCount)")
        lastObservedChangeCount = currentChangeCount

        guard let clipboardText = pasteboard.string(forType: .string) else {
            log("[ClipboardSyncCoordinator] Clipboard change ignored because no plain text content is available")
            return
        }
        guard !clipboardText.isEmpty else {
            log("[ClipboardSyncCoordinator] Clipboard change ignored because text content is empty")
            return
        }

        if suppressedClipboardText == clipboardText {
            log("[ClipboardSyncCoordinator] Ignoring clipboard change because it matches an incoming clipboard transfer")
            suppressedClipboardText = nil
            return
        }
        suppressedClipboardText = nil

        sendClipboardText(clipboardText)
    }

    private func sendClipboardText(_ clipboardText: String) {
        let targets = nearbyTrustedClipboardTargets()
        guard !targets.isEmpty else {
            log("[ClipboardSyncCoordinator] Clipboard change will not be sent because no trusted clipboard-capable devices are nearby")
            return
        }

        log("[ClipboardSyncCoordinator] Sending clipboard contents to \(targets.count) trusted clipboard-capable device(s)")

        for target in targets {
            startTransfer(to: target, clipboardText: clipboardText)
        }
    }

    private func startTransfer(to target: ClipboardSyncTarget, clipboardText: String) {
        guard activeTransfersByFingerprint[target.fingerprint] == nil else {
            queuedTextByFingerprint[target.fingerprint] = clipboardText
            log("[ClipboardSyncCoordinator] Queued latest clipboard text for \(target.logName) because a transfer is already active")
            return
        }

        let delegate = ClipboardSyncTransferDelegate(target: target) { [weak self] finishedTarget, finishedDelegate in
            DispatchQueue.main.async {
                self?.handleTransferCompleted(for: finishedTarget, delegate: finishedDelegate)
            }
        }
        activeTransfersByFingerprint[target.fingerprint] = delegate
        delegate.startTimeout(after: transferTimeout)

        NearbyConnectionManager.shared.startOutgoingTransfer(
            deviceID: target.deviceID,
            delegate: delegate,
            urls: [],
            textToSend: clipboardText,
            receiverAuthenticationPolicy: .trustedReceiver(fingerprint: target.fingerprint)
        )
    }

    private func handleTransferCompleted(for target: ClipboardSyncTarget, delegate: ClipboardSyncTransferDelegate) {
        guard activeTransfersByFingerprint[target.fingerprint] === delegate else {
            log("[ClipboardSyncCoordinator] Ignoring stale clipboard sync completion for \(target.logName)")
            return
        }

        activeTransfersByFingerprint.removeValue(forKey: target.fingerprint)

        guard let queuedText = queuedTextByFingerprint.removeValue(forKey: target.fingerprint) else {
            return
        }

        guard let refreshedTarget = nearbyTrustedClipboardTargets()
            .first(where: { $0.fingerprint == target.fingerprint }) else {
            log("[ClipboardSyncCoordinator] Dropping queued clipboard text for \(target.logName) because the device is no longer an eligible target")
            return
        }

        log("[ClipboardSyncCoordinator] Sending queued latest clipboard text to \(refreshedTarget.logName)")
        startTransfer(to: refreshedTarget, clipboardText: queuedText)
    }

    private func nearbyTrustedClipboardTargets() -> [ClipboardSyncTarget] {
        let trustedFingerprints = Set(
            TrustStore.shared.trustedCertificates.keys.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        var seenFingerprints = Set<String>()

        return NearbyConnectionManager.shared.discoveredDevices()
            .compactMap { device -> ClipboardSyncTarget? in
                guard let deviceID = device.id,
                      !deviceID.isEmpty,
                      let fingerprint = device.keyFingerprint,
                      trustedFingerprints.contains(fingerprint),
                      device.supportsClipboardReceive,
                      device.type != .computer,
                      seenFingerprints.insert(fingerprint).inserted else {
                    return nil
                }

                return ClipboardSyncTarget(
                    device: device,
                    deviceID: deviceID,
                    fingerprint: fingerprint
                )
            }
            .sorted { lhs, rhs in
                lhs.logName < rhs.logName
            }
    }
}

private struct ClipboardSyncTarget {
    let device: RemoteDeviceInfo
    let deviceID: String
    let fingerprint: String

    var logName: String {
        device.name ?? deviceID
    }
}

private final class ClipboardSyncTransferDelegate: OutboundAppDelegate {
    private let target: ClipboardSyncTarget
    private let onComplete: (ClipboardSyncTarget, ClipboardSyncTransferDelegate) -> Void
    private var isCompleted = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(target: ClipboardSyncTarget, onComplete: @escaping (ClipboardSyncTarget, ClipboardSyncTransferDelegate) -> Void) {
        self.target = target
        self.onComplete = onComplete
    }

    func startTimeout(after timeout: TimeInterval) {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isCompleted else { return }

            log("[ClipboardSyncCoordinator] Clipboard sync to \(self.target.logName) timed out")
            NearbyConnectionManager.shared.cancelTransfer(id: self.target.deviceID)
            self.complete()
        }

        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    }

    func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    func addDevice(device _: RemoteDeviceInfo) {}

    func removeDevice(id _: String) {}

    func startTransferWithQrCode(device _: RemoteDeviceInfo) {}

    func connectionWasEstablished(pinCode _: String) {}

    func transferAccepted() {}

    func transferProgress(progress _: Double) {}

    func connectionFailed(error: Error) {
        log("[ClipboardSyncCoordinator] Clipboard sync to \(target.logName) failed: \(error.localizedDescription)")
        complete()
    }

    func transferFinished() {
        log("[ClipboardSyncCoordinator] Clipboard sync to \(target.logName) finished")
        complete()
    }

    private func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        cancelTimeout()
        onComplete(target, self)
    }
}

#endif
