//
//  ApIsolationIssueView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 15.05.25.
//

import SwiftUI
import Foundation
import AppKit
import Network
import LUI

fileprivate let routerCheckQueue = DispatchQueue(label: "routerCheckQueue")

struct ApIsolationIssueView: View {
    
    @Environment(\.colorScheme) var colorScheme
    let closeView : () -> Void
    
    let scanner = DeviceToDeviceHeuristicScanner.shared
    
    var body: some View {
        
        IssueView(image: .router, header: "ApIsolationHeader".localized(), description: "ApIsolationDescription".localized(), actionLabel: "ApIsolationAction".localized()) {
            await openRouterSettingsPage()
        }
        .onAppear {
            checkIfApIsolationStillEnabled()
        }
    }
    
    
    func checkIfApIsolationStillEnabled() {
        scanner.scan { isConnectionAllowed in
            if isConnectionAllowed {
                
                log("AP Isolation is no longer enabled. Exiting...")
                
                DispatchQueue.main.async {
                    closeView()
                }
            }
            else {
                log("AP Isolation is still enabled. Checking again in 10 seconds...")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    checkIfApIsolationStillEnabled()
                }
            }
        }
    }
}


func openRouterSettingsPage() async {
    let routerIP: String? = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let ip = getDefaultGatewayIP()
            continuation.resume(returning: ip)
        }
    }

    guard let routerIP else {
        DispatchQueue.main.async {
            AudioManager.playErrorSound()
            let alert = NSAlert()
            alert.alertStyle = .critical

            alert.messageText = "ApIsolationFindRouterFailedHeader".localized()
            alert.informativeText = "ApIsolationFindRouterFailedDescription".localized()
            alert.addButton(withTitle: "CloseAlert".localized())

            ModelessAlertPresenter.present(alert)
        }
        return
    }

    if let url = URL(string: "http://\(routerIP)") {
        NSWorkspace.shared.open(url)
    }
}


/// Attempts to get the default gateway IP address (e.g., 192.168.1.1)
/// and ensures it's reachable. Returns nil if unreachable or not found.
func getDefaultGatewayIP() -> String? {
    let output = shell("netstat -rn | grep default")
    let lines = output.components(separatedBy: .newlines)

    for line in lines {
        let components = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if components.count >= 2 {
            let gateway = components[1]
            if isHostReachable(gateway) {
                return gateway
            } else {
                log("Gateway \(gateway) not reachable.")
                return nil
            }
        }
    }
    return nil
}


/// Executes a shell command and returns the output
@discardableResult
func shell(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()

    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}


/// Checks if a host (IP address or hostname) is reachable on port 80
func isHostReachable(_ host: String) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var reachable = false

    let hostEndpoint = NWEndpoint.Host(host)
    let port: NWEndpoint.Port = 80

    let connection = NWConnection(host: hostEndpoint, port: port, using: .tcp)

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            reachable = true
            connection.cancel()
            semaphore.signal()
        case .failed(_), .cancelled:
            connection.cancel()
            semaphore.signal()
        default:
            break
        }
    }

    connection.start(queue: .global())
    _ = semaphore.wait(timeout: .now() + 3)  // wait max 3 seconds

    return reachable
}


#Preview {
    ApIsolationIssueView(closeView: {})
        .frame(width: issueViewWidth, height: issueViewHeight)
}

