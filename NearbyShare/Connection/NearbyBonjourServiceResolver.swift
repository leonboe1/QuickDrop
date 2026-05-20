//
//  NearbyBonjourServiceResolver.swift
//  QuickDrop
//
//  Created by Leon Böttger on 19.05.26.
//

import Darwin
import Foundation
import Network

struct NearbyResolvedBonjourEndpoint {
    let endpoint: NWEndpoint
    /// Numeric host string; IPv6 link-local hosts may include a `%scopeID` suffix for NWEndpoint routing.
    let host: String
    let port: UInt16
    let interface: NWInterface?
    let description: String
    let isIPv4: Bool
    let isLinkLocal: Bool
}


final class NearbyBonjourServiceResolver: NSObject, NetServiceDelegate {
    private static let defaultWatchdogGracePeriod: TimeInterval = 0.5

    private let service: NetService
    private let resolveTimeout: TimeInterval
    private let watchdogGracePeriod: TimeInterval
    private let interface: NWInterface?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: (([NearbyResolvedBonjourEndpoint]) -> Void)?
    private var finished = false

    init?(
        result: NWBrowser.Result,
        resolveTimeout: TimeInterval,
        watchdogGracePeriod: TimeInterval = defaultWatchdogGracePeriod,
        completion: @escaping ([NearbyResolvedBonjourEndpoint]) -> Void
    ) {
        guard let components = Self.serviceEndpointComponents(from: result) else {
            return nil
        }

        self.service = NetService(
            domain: Self.normalizedServiceDomain(components.domain),
            type: Self.normalizedServiceType(components.type),
            name: components.name
        )
        self.resolveTimeout = resolveTimeout
        self.watchdogGracePeriod = watchdogGracePeriod
        self.interface = components.interface
        self.completion = completion
        super.init()
    }


    private static func serviceEndpointComponents(
        from result: NWBrowser.Result
    ) -> (name: String, type: String, domain: String, interface: NWInterface?)? {
        guard case let NWEndpoint.service(name: name, type: type, domain: domain, interface: interface) = result.endpoint else {
            return nil
        }

        return (name: name, type: type, domain: domain, interface: interface)
    }


    func start() {
        service.delegate = self
        service.resolve(withTimeout: resolveTimeout)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(endpoints: [])
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeout + watchdogGracePeriod, execute: timeoutWorkItem)
    }


    func cancel() {
        finish(endpoints: [], notify: false)
    }


    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(endpoints: Self.resolvedEndpoints(from: sender, interface: interface))
    }


    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(endpoints: [])
    }


    private func finish(endpoints: [NearbyResolvedBonjourEndpoint], notify: Bool = true) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        service.stop()
        service.delegate = nil

        let completion = completion
        self.completion = nil

        if notify {
            DispatchQueue.main.async {
                completion?(endpoints)
            }
        }
    }


    private static func resolvedEndpoints(
        from service: NetService,
        interface: NWInterface?
    ) -> [NearbyResolvedBonjourEndpoint] {
        let endpoints = (service.addresses ?? [])
            .compactMap { resolvedEndpoint(from: $0, interface: interface) }

        var seenDescriptions = Set<String>()
        let uniqueEndpoints = endpoints.filter { endpoint in
            seenDescriptions.insert(endpoint.description).inserted
        }

        return uniqueEndpoints.sorted { lhs, rhs in
            if lhs.isIPv4 != rhs.isIPv4 {
                return lhs.isIPv4
            }
            if lhs.isLinkLocal != rhs.isLinkLocal {
                return !lhs.isLinkLocal
            }
            return lhs.description < rhs.description
        }
    }


    private static func resolvedEndpoint(
        from addressData: Data,
        interface: NWInterface?
    ) -> NearbyResolvedBonjourEndpoint? {
        addressData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }

            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            let addressFamily = Int32(sockaddrPointer.pointee.sa_family)

            guard addressFamily == AF_INET || addressFamily == AF_INET6 else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var portBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
            let result = getnameinfo(
                sockaddrPointer,
                socklen_t(addressData.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                &portBuffer,
                socklen_t(portBuffer.count),
                NI_NUMERICHOST | NI_NUMERICSERV
            )

            guard result == 0 else { return nil }

            var host = String(cString: hostBuffer)
            if addressFamily == AF_INET6 {
                host = scopedIPv6Host(host, addressData: addressData)
            }

            guard let portRawValue = UInt16(String(cString: portBuffer)),
                  let port = NWEndpoint.Port(rawValue: portRawValue) else {
                return nil
            }

            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            let description: String
            if addressFamily == AF_INET6 {
                description = "[\(host)]:\(portRawValue)"
            } else {
                description = "\(host):\(portRawValue)"
            }

            let isIPv6LinkLocal = addressFamily == AF_INET6 && host.lowercased().hasPrefix("fe80:")

            return NearbyResolvedBonjourEndpoint(
                endpoint: endpoint,
                host: host,
                port: portRawValue,
                interface: isIPv6LinkLocal ? interface : nil,
                description: description,
                isIPv4: addressFamily == AF_INET,
                isLinkLocal: isIPv6LinkLocal
            )
        }
    }


    private static func scopedIPv6Host(
        _ host: String,
        addressData: Data
    ) -> String {
        guard !host.contains("%"),
              host.lowercased().hasPrefix("fe80:") else {
            return host
        }

        guard let scopeID = ipv6ScopeID(from: addressData), scopeID != 0 else {
            return host
        }

        return "\(host)%\(scopeID)"
    }


    private static func ipv6ScopeID(from addressData: Data) -> UInt32? {
        addressData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard Int32(sockaddrPointer.pointee.sa_family) == AF_INET6 else { return nil }
            return baseAddress.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_scope_id
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
}
