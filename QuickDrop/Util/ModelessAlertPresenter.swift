//
//  ModelessAlertPresenter.swift
//  QuickDrop
//
//  Created by Leon Böttger on 30.06.26.
//

import AppKit

/// Presents an `NSAlert` as its own modeless panel (non-blocking) instead of `runModal()`. It's the
/// exact `_NSAlertPanel` window `runModal()` would show, so it looks identical — but it does not spin a
/// nested modal run loop, so the app keeps working (e.g. can still receive the next transfer) while the
/// alert is on screen.
///
/// Use this in place of `alert.runModal()` for any alert that may appear while the app is busy. The
/// clicked button is reported to `completion` as the `NSApplication.ModalResponse` that `runModal()`
/// would have returned (first button = `.alertFirstButtonReturn`, second = `.alertSecondButtonReturn`,
/// …). Must be called on the main thread.
final class ModelessAlertPresenter: NSObject {

    /// Keeps each live presenter — and thus its `NSAlert` and panel — retained while on screen; the
    /// entry is removed when the alert is dismissed. `NSButton.target` is weak and the panel is owned by
    /// the `NSAlert`, so without this the alert would deallocate immediately.
    private static var active: Set<ModelessAlertPresenter> = []

    private let alert: NSAlert
    private let completion: (NSApplication.ModalResponse) -> Void

    private init(alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    static func present(_ alert: NSAlert,
                        completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {

        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        }
        else {
            let presenter = ModelessAlertPresenter(alert: alert, completion: completion)
            active.insert(presenter)
            presenter.show()
        }
    }

    private func show() {
        alert.layout()

        // runModal() makes the default button respond to Return; modelessly we set it ourselves — but
        // only if the caller specified no key equivalents, so explicit ones (e.g. Escape) are kept.
        if alert.buttons.allSatisfy({ $0.keyEquivalent.isEmpty }) {
            alert.buttons.first?.keyEquivalent = "\r"
        }

        for button in alert.buttons {
            button.target = self
            button.action = #selector(buttonClicked(_:))
        }

        let window = alert.window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(rawValue: sender.tag)
        alert.window.orderOut(nil)
        // Defer teardown so the alert and its panel aren't deallocated while this button's action is
        // still on the stack.
        DispatchQueue.main.async {
            self.completion(response)
            ModelessAlertPresenter.active.remove(self)
        }
    }
}
