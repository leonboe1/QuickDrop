//
//  IntroductionView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 20.12.25.
//

import SwiftUI
import LUI

struct IntroductionView: View {

    static let width: CGFloat = 810
    static let height: CGFloat = 540
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var bluetooth = BluetoothPermissionManager.shared
    @State private var currentPage: IntroductionPage = .splash

    @State private var pollingPage: IntroductionPage? = nil
    @State private var skipAction: IntroductionPage.SkipAction? = nil
    
    @State private var helpActionAlert: IntroductionPage.HelpAction? = nil
    
    let startReceiving: (() -> Void)
    let onFinish: (() -> Void)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                    if colorScheme == .dark {
                        Color.black.opacity(0.2)
                    } else {
                        Color.white
                    }
                }
                .ignoresSafeArea()

                VStack {
                    let topHeight = geo.size.height * 0.35

                    ZStack {
                        Color.gray.opacity(colorScheme == .light ? 0.1 : 0.12)
                        currentPage.topHeader(with: topHeight)
                    }
                    .edgesIgnoringSafeArea(.top)
                    .frame(height: topHeight)

                    Spacer()

                    VStack {
                        Text(currentPage.title.localized())
                            .font(.system(size: 32))
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)

                        Text(currentPage.subtitle.localized())
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .multilineTextAlignment(.center)
                            .padding(.top)
                            .minimumScaleFactor(0.5)
                            .opacity(0.8)
                        
                        if currentPage == .enableShareExtension {
                            EnableExtensionView(canShowIntialCheckmark: true)
                        }
                    }
                    .padding(.horizontal, 40)

                    Spacer()
                    
                    if currentPage == .splash {
                        BottomFootnoteView(type: .privacyBanner)
                    }
                    else {
                        Spacer()
                    }

                    Divider()

                    HStack {
                        if let skipAction = currentPage.skipAction, pollingPage != nil {
                            
                            Button("introduction_skip") {
                                self.skipAction = skipAction
                            }
                            .foregroundColor(.gray)
                            .buttonStyle(.borderless)
                            .alert(item: $skipAction) { action in
                                
                                .init(title: Text(action.warningTitle.localized()), message: Text(action.warningMessage.localized()), primaryButton: .default(Text("introduction_continue".localized()), action: {
                                    
                                    stopPolling()
                                    self.skipAction = nil
                                    
                                    if let nextPage = action.action() {
                                        currentPage = nextPage
                                    }
                                    else {
                                        onFinish()
                                    }
                                }), secondaryButton: .cancel()
                                )
                            }
                        }

                        Spacer()

                        continueArea
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
            }
        }
        .onAppear { pageDidChange(to: currentPage) }
        .onChange(of: currentPage) { newValue in
            pageDidChange(to: newValue)
        }
        .onChange(of: scenePhase) { newValue in
            guard newValue == .active, currentPage == .bluetoothAccess else { return }
            refreshBluetoothPermissionAndAdvanceIfAllowed()
        }
        .task(id: pollingPage) {
            guard let page = pollingPage else { return }
            
            // Poll every 1 second until condition is satisfied or canceled
            while !Task.isCancelled {
                if page.canContinue() {
                    await MainActor.run {
                        // Only advance if we're still on the page we started polling for
                        guard currentPage == page else {
                            stopPolling()
                            return
                        }
                        stopPolling()
                        advance()
                    }
                    return
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    

    @ViewBuilder
    private var continueArea: some View {
        ZStack {
            
            let isLoading = pollingPage != nil
            
            Button("introduction_continue") {
                continueTapped()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .opacity(isLoading ? 0 : 1)
            .overlay (
                LoadingIndicator()
                    .frame(width: 20, height: 20)
                    .opacity(isLoading ? 1 : 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            )
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        
    }
    

    private func pageDidChange(to newPage: IntroductionPage) {
        stopPolling()

        // Cannot perform action, default to loading screen
        if !newPage.canPerformAction {
            pollingPage = newPage
        }
    }
    

    private func continueTapped() {
        if currentPage == .bluetoothAccess {
            continueBluetoothPermission()
            return
        }

        // If already allowed, advance immediately
        if currentPage.canContinue() {
            advance()
            return
        }

        // Not allowed yet: show loading and start polling every 1s
        pollingPage = currentPage
    }
    
    
    private func triggerLocalNetworkPermission() {
        self.startReceiving()
    }

    
    private func continueBluetoothPermission() {
        bluetooth.refresh()

        if bluetooth.isAllowed {
            advance()
            return
        }

        pollingPage = .bluetoothAccess

        guard bluetooth.canRequestPermission else {
            bluetooth.openSystemBluetoothSettings()
            return
        }

        bluetooth.requestPermission { allowed in
            DispatchQueue.main.async {
                guard currentPage == .bluetoothAccess else {
                    stopPolling()
                    return
                }

                if allowed {
                    stopPolling()
                    advance()
                }
                else {
                    pollingPage = .bluetoothAccess
                }
            }
        }
    }


    private func refreshBluetoothPermissionAndAdvanceIfAllowed() {
        bluetooth.refresh()

        guard currentPage == .bluetoothAccess, bluetooth.isAllowed else { return }

        stopPolling()
        advance()
    }


    private func advance() {

        if currentPage == .localNetworkAccess {
            let _ = DeviceToDeviceHeuristicScanner.shared.hasLocalNetworkAccess(completion: {_ in })
            triggerLocalNetworkPermission()
        }

        if let nextPage = currentPage.presentNextPage() {
            currentPage = nextPage
        } else {
            onFinish()
        }
    }

    
    private func stopPolling() {
        // Cancels the .task(id:) by changing the id and resets UI state
        pollingPage = nil
    }
}


enum IntroductionPage: CaseIterable {
    case splash
    case noWifi
    case localNetworkAccess
    case bluetoothAccess
    case enableShareExtension
    case finished
    
    var title: String {
        switch self {
        case .splash:
            return "WelcomeToQuickDrop"
        case .noWifi:
            return "introduction_no_wifi"
        case .localNetworkAccess:
            return "introduction_local_network_access"
        case .bluetoothAccess:
            return "BluetoothPermissionRequiredTitle"
        case .enableShareExtension:
            return "introduction_enable_share_extension"
        case .finished:
            return "introduction_finished"
        }
    }
    
    
    var subtitle: String {
        switch self {
        case .splash:
            return "QuickDropWelcomeDescription"
        case .noWifi:
            return "introduction_no_wifi_description"
        case .localNetworkAccess:
            return "introduction_local_network_access_description".localized(with: "introduction_continue".localized())
        case .bluetoothAccess:
            return "BluetoothPermissionRequiredSubtitle"
        case .enableShareExtension:
            if #available(macOS 13.0, *) {
                return "introduction_enable_share_extension_description".localized(with: "EnableQuickDropExtension".localized())
            }
            else {
                return "introduction_enable_share_extension_description_legacy".localized(with: "EnableQuickDropExtension".localized())
            }
        case .finished:
            return "introduction_finished_description"
        }
    }
    
    
    var skipAction: SkipAction? {
        switch self {
        case .noWifi:
            return .init(action: presentNextPage, warningTitle: "introduction_no_wifi_skip_title", warningMessage: "introduction_no_wifi_skip_message")
        case .bluetoothAccess:
            return .init(action: { .enableShareExtension }, warningTitle: "BluetoothPermissionSkipAlertTitle", warningMessage: "BluetoothPermissionSkipAlertMessage")
        default:
            return nil
        }
    }
    
    
    var canPerformAction: Bool {
        switch self {
            case .noWifi:
                return false
            default:
                return true
        }
    }
    
    
    func presentNextPage() -> IntroductionPage? {
        switch self {
        case .splash:
            return NearbyConnectionManager.shared.isConnectedToLocalNetwork ? firstPermissionPane() : .noWifi
        case .noWifi:
            return firstPermissionPane()
        case .localNetworkAccess:
            return .bluetoothAccess
        case .bluetoothAccess:
            return .enableShareExtension
        case .enableShareExtension:
            return .finished
        case .finished:
            return nil
        }
    }
    
    
    private func firstPermissionPane() -> IntroductionPage {
        if #available(macOS 15.0, *) {
            // Local network access is requested first on macOS 15+
            return .localNetworkAccess
        }
        return .bluetoothAccess
    }
    
    
    func canContinue() -> Bool {
        switch self {
            case .noWifi:
                return NearbyConnectionManager.shared.isConnectedToLocalNetwork
            case .bluetoothAccess:
                return BluetoothPermissionManager.shared.isAllowed
            default:
                return true
        }
    }
    
    
    func topHeader(with height: CGFloat) -> some View {
        ZStack {
            
            switch self {
            case .splash:
                Image(.quickDropMockup)
                    .resizable()
                    .scaledToFit()
                    .padding(.top, height * 0.33)
                    .padding(.bottom, height * 0.1)
            case .noWifi:
                imageView(for: "wifi.slash", with: height)
            case .localNetworkAccess:
                imageView(for: "network", with: height)
            case .bluetoothAccess:
                imageView(for: "antenna.radiowaves.left.and.right", with: height)
            case .enableShareExtension:
                imageView(for: "square.and.arrow.up", with: height)
            case .finished:
                imageView(for: "checkmark.seal.fill", with: height)
            }
            
        }
        .foregroundColor(.blue)
    }
    
    
    private func imageView(for image: String, with height: CGFloat) -> some View {
        Image(systemName: image)
            .resizable()
            .scaledToFit()
            .frame(height: height * 0.5)
            .padding(.top, height * 0.13)
    }

    struct SkipAction: Identifiable {
        let action: () -> IntroductionPage?
        let warningTitle: String
        let warningMessage: String
        
        var id: String { warningTitle }
    }
    
    
    struct HelpAction: Identifiable {
        let question: String
        let answer: String
        
        var id: String { question }
    }
}


#Preview {
    IntroductionView(startReceiving: {}){}
        .frame(width: IntroductionView.width, height: IntroductionView.height)
}
