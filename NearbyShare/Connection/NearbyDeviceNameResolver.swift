//
//  NearbyDeviceNameResolver.swift
//  QuickDrop
//
//  Created by Leon Böttger on 25.04.2026.
//

import Darwin
import Foundation
import Network

final class NearbyDeviceNameResolver {
    private static let hostnameLookupQueue = DispatchQueue(
        label: "com.leonboettger.quickdrop.deviceNameHostnameLookup",
        qos: .utility
    )

    private var hostnameResolvers: [UUID: NearbyBonjourServiceResolver] = [:]
    private var lookupTokens: [String: UUID] = [:]
    
    func needsLookup(for endpointInfo: EndpointInfo?) -> Bool {
        let cleanedName = endpointInfo?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedName?.isEmpty != false
    }
    

    func resolveName(for service: NWBrowser.Result, endpointID: String, completion: @escaping (String) -> Void) {
        let lookupToken = UUID()
        lookupTokens[endpointID] = lookupToken

        resolveAdvertisedHostname(for: service) { [weak self] hostname in
            guard let self else { return }
            guard self.lookupTokens[endpointID] == lookupToken else { return }
            self.lookupTokens.removeValue(forKey: endpointID)
            guard let hostname else { return }
            completion(hostname)
        }
    }

    
    func cancelLookup(for endpointID: String) {
        lookupTokens.removeValue(forKey: endpointID)
    }

    
    func cancelAll() {
        lookupTokens.removeAll()
        hostnameResolvers.values.forEach { $0.cancel() }
        hostnameResolvers.removeAll()
    }
    

    private func resolveAdvertisedHostname(for service: NWBrowser.Result, completion: @escaping (String?) -> Void) {
        let resolverID = UUID()
        guard let resolver = NearbyBonjourServiceResolver(
            result: service,
            resolveTimeout: 0.5,
            watchdogGracePeriod: 1.0,
            completion: { [weak self] endpoints in
                self?.hostnameResolvers.removeValue(forKey: resolverID)
                guard let ipv4Address = endpoints.first(where: \.isIPv4)?.host else {
                    completion(nil)
                    return
                }

                Self.hostnameLookupQueue.async {
                    let hostname = NearbyHostLookup.hostname(forIPv4: ipv4Address)
                    DispatchQueue.main.async {
                        completion(hostname)
                    }
                }
            }
        ) else {
            completion(nil)
            return
        }

        hostnameResolvers[resolverID] = resolver
        resolver.start()
    }
}


private enum NearbyHostLookup {
    static func hostname(forIPv4 address: String) -> String? {
        reverseDNSName(forIPv4: address).flatMap(prettifyDisplayName)
    }

    
    private static func reverseDNSName(forIPv4 address: String) -> String? {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)

        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            return nil
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }

        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }
    

    private static func prettifyDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let withoutZone = value.split(separator: "%").first.map(String.init) ?? value
        let withoutDomain = withoutZone.split(separator: ".").first.map(String.init) ?? withoutZone
        let prettified = withoutDomain
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prettified.isEmpty else { return nil }
        return prettified.capitalized
    }
}
