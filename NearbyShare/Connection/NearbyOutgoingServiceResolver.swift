//
//  NearbyOutgoingServiceResolver.swift
//  QuickDrop
//
//  Created by Leon Böttger on 19.05.26.
//

import Foundation
import Network

final class NearbyOutgoingServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let resolveTimeout: TimeInterval
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: (([NearbyResolvedServiceEndpoint]) -> Void)?
    private var finished = false

    init?(
        result: NWBrowser.Result,
        resolveTimeout: TimeInterval,
        completion: @escaping ([NearbyResolvedServiceEndpoint]) -> Void
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
            self?.finish(endpoints: [])
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeout + 0.5, execute: timeoutWorkItem)
    }


    func cancel() {
        finish(endpoints: [], notify: false)
    }


    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(endpoints: Self.resolvedEndpoints(from: sender))
    }


    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(endpoints: [])
    }


    private func finish(endpoints: [NearbyResolvedServiceEndpoint], notify: Bool = true) {
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


    private static func resolvedEndpoints(from service: NetService) -> [NearbyResolvedServiceEndpoint] {
        let endpoints = (service.addresses ?? [])
            .compactMap(resolvedEndpoint)

        var seenDescriptions = Set<String>()
        let uniqueEndpoints = endpoints.filter { endpoint in
            seenDescriptions.insert(endpoint.description).inserted
        }

        return uniqueEndpoints.sorted { lhs, rhs in
            if lhs.isIPv4 != rhs.isIPv4 {
                return lhs.isIPv4
            }
            return lhs.description < rhs.description
        }
    }


    private static func resolvedEndpoint(from addressData: Data) -> NearbyResolvedServiceEndpoint? {
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

            let host = String(cString: hostBuffer)
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

            return NearbyResolvedServiceEndpoint(
                endpoint: endpoint,
                description: description,
                isIPv4: addressFamily == AF_INET
            )
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


struct NearbyResolvedServiceEndpoint {
    let endpoint: NWEndpoint
    let description: String
    let isIPv4: Bool
}
