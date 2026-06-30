//
//  SettingsView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 24.03.25.
//

import SwiftUI
import AppKit
import LUI

struct SettingsView: View {
    
    let openPlus: () -> Void
    
    @ObservedObject var settings = Settings.sharedInstance
    @ObservedObject var connectionManager = NearbyConnectionManager.shared
    @ObservedObject var iapManager = IAPManager.sharedInstance
    
    @State private var isChangeDeviceNameAlertPresented = false
    @State private var licenseWindow: NSWindow?
    
    var body: some View {
        
        LargeAppIconView(title: "Settings") {
            Form {
                Toggle("AutomaticallyAcceptFiles", isOn: $settings.automaticallyAcceptFiles)
                    .padding(.top, 10)
                
                Text("AutomaticallyAcceptFilesFooter")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.top, 5)
                
                Divider()
                    .padding(.vertical, 10)
                
                HStack {
                    Text("SaveFilesTo")
                    Spacer()
                    Text(getSavedFolderPath() ?? "DownloadsFolder".localized())
                        .foregroundColor(.gray)
                    Button("SaveFilesToButton") {
                        selectFolder()
                    }
                }
                
                HStack {
                    Text("DeviceName")
                    Spacer()
                    Text(connectionManager.deviceInfo.name ?? "Unknown".localized())
                        .foregroundColor(.gray)
                    
                    Button("Edit") {
                        presentRenameAlert()
                    }
                }
                
                Divider()
                    .padding(.vertical, 10)
                
                Toggle("OpenFinderAfterReceiving", isOn: $settings.openFinderAfterReceiving)
                    .padding(.top, 5)
                
                if #available(macOS 13.0, *) {
                    LaunchAtLogin.Toggle {
                        Text("LaunchAtLogin")
                    }
                    .padding(.top, 5)
                }
                
                Divider()
                    .padding(.vertical, 10)
                
                HStack(spacing: 30) {
                    SettingsFooterButton("ManageTrustedDevices") {
                        openTrustedDevicesWindow()
                    }
                    
                    SettingsFooterButton("Acknowledgements") {
                        licenseWindow = openLicenseWindow()
                    }
                    
                    #if !GITHUB
                    if !iapManager.plusVersionState {
                        SettingsFooterButton("SupportQuickDrop") {
                            openPlus()
                        }
                    }
                    #endif
                    
                    #if DEBUG
                    SettingsFooterButton("ResetAllSettings") {
                        IAPManager.sharedInstance.plusVersionState = false
                        Settings.sharedInstance.deleteAllUserDefaults()
                    }
                    #endif
                }
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
        }
    }
    
    
    private func getSavedFolderPath() -> String? {
        if let bookmark = settings.saveFolderBookmark, !bookmark.isEmpty {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                return url.lastPathComponent  // Returns the folder path as a string
            } catch {
                log("Failed to resolve bookmark: \(error)")
            }
        }
        return nil  // No saved folder
    }
    
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "SaveFilesLocation".localized()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.urls.first {
            do {
                log("Selected folder: \(url)")
                
                if url.description == "file:///" {
                    throw NSError(domain: "InvalidSelection", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cannot select root directory. Please choose a specific folder."])
                }
                
                let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                
                Settings.sharedInstance.saveFolderBookmark = bookmarkData
                Settings.sharedInstance.openFinderAfterReceiving = true
            } catch {
                log("Failed to save security-scoped bookmark: \(error)")
                
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    
                    AudioManager.playErrorSound()
                    
                    // show alert
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "FolderSelectionFailedTitle".localized()
                    alert.informativeText = "FolderSelectionFailedMessage".localized()
                    alert.addButton(withTitle: "CloseAlert".localized())

                    ModelessAlertPresenter.present(alert)
                }
            }
        }
    }
    
    
    private func openTrustedDevicesWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.title = "TrustedDevices".localized()
        window.backgroundColor = NSColor(Color.defaultMacBackgroundColor)
        window.contentView = NSHostingView(rootView: TrustedDevicesView())
        
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.level = .normal
    }
    
    
    private func presentRenameAlert() {
        guard let window = NSApplication.shared.keyWindow else { return }

        let alert = NSAlert()
        alert.messageText = "ChangeDeviceName".localized()
        alert.informativeText = "ChangeDeviceNameDescription".localized()
        alert.alertStyle = .informational

        let textField = NSTextField(string: NearbyConnectionManager.shared.deviceInfo.name ?? "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField

        alert.addButton(withTitle: "Save".localized())
        alert.addButton(withTitle: "Cancel".localized())

        alert.beginSheetModal(for: window) { response in

            if response == .alertFirstButtonReturn {
                let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                NearbyConnectionManager.shared.setCustomDeviceName(to: trimmed)
            }
        }

        DispatchQueue.main.async {
            let alertWindow = alert.window
            alertWindow.makeFirstResponder(textField)
            if let editor = alertWindow.fieldEditor(true, for: textField) as? NSTextView {
                editor.selectedRange = NSRange(location: 0, length: textField.stringValue.count)
            }
        }
    }
}


struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(openPlus: {})
            .frame(width: 800, height: 500)
    }
}


private struct SettingsFooterButton: View {
    let title: String
    let action: () -> Void
    
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    
    var body: some View {
        Button {
            action()
        } label: {
            Text(title.localized())
                .underline()
                .font(.subheadline)
                .lineLimit(1)
                .opacity(0.5)
        }
        .buttonStyle(.plain)
    }
}
