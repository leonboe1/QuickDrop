//
//  WelcomeScreen.swift
//  QuickDrop
//
//  Created by Leon Böttger on 03.01.25.
//

import SwiftUI
import UniformTypeIdentifiers
import LUI

struct WelcomeScreen: View {
    
    static let width: CGFloat = 1000
    static let height: CGFloat = 600
    
    @Environment(\.colorScheme) var colorScheme
    
    let openPlusScreen: () -> Void
    let openAppAdvertisementView: () -> Void
    let openCableTransmissionView: () -> Void
    let checkForNetworkIssues: () -> Void
    
    @State private var selection: Tab = Tab.receive
    
    var body: some View {
        
        HStack(spacing: 0) {
            
            let listBinding = Binding<Tab?>(
                get: { selection },
                set: { newValue in
                    selection = newValue ?? .receive
                }
            )
            
            List(selection: listBinding) {
                ForEach(Tab.allCases.filter({$0 != .settings }), id: \.self) { tab in
                    Label(tab.sidebarTitle, systemImage: tab.systemImage)
                        .tag(tab)
                        .frame(height: 30)
                }
                
                Divider()
                
                ExternalLinkLabel(label: "GetSupport", icon: "questionmark.circle") {
                    LogExportPresenter.showUploadLogsAlert(openSupportMailWhenNotUploading: true)
                }
                
                ExternalLinkLabel(label: "PrivacyPolicy", icon: "hand.raised") {
                    openPrivacyPolicy()
                }
                
                ExternalLinkLabel(label: "AndroidApp", icon: getPhoneIcon()) {
                    openAppAdvertisementView()
                }
                
                ExternalLinkLabel(label: "TransmitUsingCable", icon: getCableIcon()) {
                    openCableTransmissionView()
                }
                
                Divider()
                
                Label(Tab.settings.sidebarTitle, systemImage: Tab.settings.systemImage)
                    .tag(Tab.settings)
                    .frame(height: 30)
            }
            .minimumScaleFactor(0.5)
            .frame(width: 220)
            .listStyle(SidebarListStyle())
            
            Divider()
                .edgesIgnoringSafeArea(.vertical)
            
            ZStack {
                Color.defaultBackground.edgesIgnoringSafeArea(.vertical)
            
                    if selection == .settings {
                        SettingsView()
                    }
                    else {
                        TutorialView(
                            tab: selection,
                            openPlus: openPlusScreen,
                            openAppAdvertisementView: openAppAdvertisementView
                        )
                        .onAppear {
                            if selection == .troubleshooting {
                                checkForNetworkIssues()
                            }
                        }
                    }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .frame(width: Self.width, height: Self.height)
    }
    
    func openPrivacyPolicy() {
        if let url = URL(string: .privacyPolicyURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    func getPhoneIcon() -> String {
        if #available(macOS 14.0, *) {
            return "smartphone"
        }
        return "iphone.rear.camera"
    }
    
    func getCableIcon() -> String {
        if #available(macOS 12.0, *) {
            return "cable.connector"
        }
        return "externaldrive.connected.to.line.below.fill"
    }
    
    func handleDrop(providers: [NSItemProvider]) {
        let dispatchGroup = DispatchGroup()
        var urls: [URL] = []
        let urlQueue = DispatchQueue(label: "DroppedURLsQueue")
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                dispatchGroup.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                    defer { dispatchGroup.leave() }
                    if let data = item as? Data,
                       let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? {
                        urlQueue.sync {
                            urls.append(url)
                        }
                    } else if let url = item as? URL {
                        urlQueue.sync {
                            urls.append(url)
                        }
                    }
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            if !urls.isEmpty {
                sendToSharingService(items: urls)
            }
        }
    }
}


struct ExternalLinkLabel: View {
    
    let label: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack {
                Label(label.localized(), systemImage: icon)
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .opacity(0.3)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


enum Tab: CaseIterable {
    case receive
    case send
    case notificationSync
    case troubleshooting
    case settings
    
    var sidebarTitle: String {
        switch self {
        case .receive:
            return "ReceiveFiles".localized()
        case .send:
            return "SendFiles".localized()
        case .notificationSync:
            return "NotificationSyncSidebar".localized()
        case .troubleshooting:
            return "TroubleshootingAndFaq".localized()
        case .settings:
            return "Settings".localized()
        }
    }
    
    var title: String {
        switch self {
        default:
            return sidebarTitle
        }
    }
    
    var text: String {
        switch self {
        case .receive:
            "UserManualDescription"
        case .send:
            "SendFilesDescription"
        case .notificationSync:
            "NotificationSyncManualDescription"
        default:
            ""
        }
    }
    
    var systemImage: String {
        switch self {
        case .receive:
            return "tray.and.arrow.down"
        case .send:
            return "tray.and.arrow.up"
        case .notificationSync:
            return "bell"
        case .troubleshooting:
            return "exclamationmark.triangle"
        case .settings:
            return "gear"
        }
    }
}


#Preview {
    WelcomeScreen(openPlusScreen: {}, openAppAdvertisementView: {}, openCableTransmissionView: {}, checkForNetworkIssues: {})
}
