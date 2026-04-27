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
    private var hostnameResolvers: [UUID: NearbyNetworkScannerHostnameResolver] = [:]
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
        guard let resolver = NearbyNetworkScannerHostnameResolver(result: service, resolveTimeout: 0.5, completion: { [weak self] hostname in
            self?.hostnameResolvers.removeValue(forKey: resolverID)
            completion(hostname)
        }) else {
            completion(nil)
            return
        }

        hostnameResolvers[resolverID] = resolver
        resolver.start()
    }
}


private final class NearbyNetworkScannerHostnameResolver: NSObject, NetServiceDelegate {
    private static let hostnameLookupQueue = DispatchQueue(
        label: "com.leonboettger.quickdrop.networkScannerHostname",
        qos: .utility
    )

    private let service: NetService
    private let resolveTimeout: TimeInterval
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    private var finished = false

    init?(
        result: NWBrowser.Result,
        resolveTimeout: TimeInterval,
        completion: @escaping (String?) -> Void
    ) {
        guard case let NWEndpoint.service(name: name, type: type, domain: domain, interface: _) = result.endpoint else {
            return nil
        }

        self.service = NetService(
            domain: Self.normalizedServiceDomain(domain),
            type: Self.normalizedServiceType(type),
            name: name
        )
        self.resolveTimeout = resolveTimeout
        self.completion = completion
        super.init()
    }

    
    func start() {
        service.delegate = self
        service.resolve(withTimeout: resolveTimeout)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(hostname: nil)
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeout + 1.0, execute: timeoutWorkItem)
    }

    
    func cancel() {
        finish(hostname: nil, notify: false)
    }
    

    func netServiceDidResolveAddress(_ sender: NetService) {
        let numericAddresses = sender.addresses?.compactMap(Self.numericHostString) ?? []
        guard let ipv4Address = numericAddresses.first(where: NearbyNetworkScannerHostLookup.isIPv4Address) else {
            finish(hostname: nil)
            return
        }

        Self.hostnameLookupQueue.async { [weak self] in
            let hostname = NearbyNetworkScannerHostLookup.hostname(forIPv4: ipv4Address)
            DispatchQueue.main.async {
                self?.finish(hostname: hostname)
            }
        }
    }
    

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(hostname: nil)
    }
    

    private func finish(hostname: String?, notify: Bool = true) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        service.stop()
        service.delegate = nil

        let completion = completion
        self.completion = nil

        if notify {
            completion?(hostname)
        }
    }
    

    private static func normalizedServiceDomain(_ domain: String) -> String {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomain.isEmpty else { return "local." }
        return trimmedDomain.hasSuffix(".") ? trimmedDomain : "\(trimmedDomain)."
    }

    
    private static func normalizedServiceType(_ type: String) -> String {
        let trimmedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedType.hasSuffix(".") ? trimmedType : "\(trimmedType)."
    }

    
    private static func numericHostString(from addressData: Data) -> String? {
        addressData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            let result = getnameinfo(
                sockaddrPointer,
                socklen_t(addressData.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { return nil }
            return String(cString: hostBuffer)
                .split(separator: "%")
                .first
                .map(String.init)
        }
    }
}


private enum NearbyNetworkScannerHostLookup {
    static func hostname(forIPv4 address: String) -> String? {
        reverseDNSName(forIPv4: address).flatMap(prettifyDisplayName)
    }

    
    static func isIPv4Address(_ address: String) -> Bool {
        !address.contains(":")
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
