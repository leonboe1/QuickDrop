//
//  TutorialView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 05.03.25.
//

import AppKit
import LUI
import SwiftUI

struct TutorialView: View {
    
    let tab: Tab
    let openAppAdvertisementView: () -> Void
    
    var body: some View {
        
        LargeAppIconView(title: tab.title) {
            VStack {
                Group {
                    if tab == .troubleshooting {
                        FAQView(faqItems: [
                            .init(question: "FaqNotVisibleOrConnectingQuestion", answer: "FaqNotVisibleOrConnectingAnswer"),
                            .init(question: "FaqPhotoDateNotPreservedQuestion", answer: "FaqPhotoDateNotPreservedAnswer"),
                            .init(question: "FaqAndroidDeviceNotVisibleQuestion", answer: "FaqAndroidDeviceNotVisibleAnswer"),
                            .init(question: "FaqTrustedDevicesQuestion", answer: "FaqTrustedDevicesAnswer"),
                            .init(question: "MultipleFilesSendingQuestion", answer: "MultipleFilesSendingAnswer"),
                            .init(question: "FaqBugQuestion", answer: "FaqBugAnswer"),
                        ])
                        .padding(.top)
                    }
                    else {
                        Text(tab.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                    }
                }
                .frame(width: 550)
                
                if tab == .receive {
                    Button {
                        showSamsungOneUI85Alert()
                    } label: {
                        Text("SamsungOneUI85HelpLink".localized())
                            .underline()
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .opacity(0.7)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                else if tab == .send {
                    EnableExtensionView()
                }
                else if tab == .notificationSync || tab == .clipboardSync {
                    Button {
                        openAppAdvertisementView()
                    } label: {
                        Text("DownloadMobileApp".localized())
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
        }
    }
    
    private func showSamsungOneUI85Alert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SamsungOneUI85AlertTitle".localized()
        alert.informativeText = "SamsungOneUI85AlertMessage".localized()
        alert.addButton(withTitle: "CloseAlert".localized())

        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        }
        else {
            alert.runModal()
        }
    }
}


struct EnableExtensionView: View {
    @State private var showSharePicker = false
    @State private var shareItems: [Any] = []

    @State private var isExtensionEnabled = false
    @State private var showSuccessCheckmark = false
    @State private var animateCheckmark = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    init(canShowIntialCheckmark: Bool = false) {
        let isEnabled = Self.isEnabled()
        
        _isExtensionEnabled = State(initialValue: isEnabled)
        
        if canShowIntialCheckmark && isEnabled {
            _showSuccessCheckmark = State(initialValue: true)
            _animateCheckmark = State(initialValue: true)
        }
    }

    var body: some View {
        if !isExtensionEnabled {
            Button("EnableQuickDropExtension".localized()) {
                shareItems = [
                    "EnableQuickDropExtensionDescription".localized()
                ]
                showSharePicker = true
            }
            .background(
                SharingPickerPresenter(
                    isPresented: $showSharePicker,
                    sharingItems: shareItems
                )
            )
            .padding()
            .onReceive(timer) { _ in
                updateEnabledState()
            }
        }
        else if showSuccessCheckmark {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.green)
                .background(Circle().foregroundColor(.white).frame(width: 18, height: 18))
                .scaleEffect(animateCheckmark ? 1.0 : 0.5)
                .animation(.easeOut(duration: 0.4), value: animateCheckmark)
                .onAppear {
                    animateCheckmark = true
                }
                .padding()
        }
    }

    private func updateEnabledState() {
        let enabled = Self.isEnabled()
        if enabled != isExtensionEnabled {
            withAnimation(.smooth) {
                isExtensionEnabled = enabled
                
                if enabled {
                    showSuccessCheckmark = true
                }
            }
        }
    }

    private static func isEnabled() -> Bool {
        NSSharingService(
            named: NSSharingService.Name("com.leonboettger.neardrop.ShareExtension")
        ) != nil
    }
}


private struct SharingPickerPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let sharingItems: [Any]

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented else { return }

        let picker = NSSharingServicePicker(items: sharingItems)

        DispatchQueue.main.async {
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            isPresented = false
        }
    }
}


#Preview {
    WelcomeScreen(openPlusScreen: {}, openAppAdvertisementView: {}, openCableTransmissionView: {}, checkForNetworkIssues: {}, navigationState: WelcomeScreenNavigationState())
}
