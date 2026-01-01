//
//  DHCPClient.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//
//  High-level DHCP query orchestration: builds packets, parses responses, and aggregates server info.

import Foundation
import Darwin

struct DHCPQueryConfig {
    var timeout: TimeInterval
    var count: Int
    var mac: String?
    var hostname: String?
    var interfaceName: String?
}

struct DHCPServerInfo: Identifiable, Hashable {
    let id: String
    let offer: String
    let subnet: String?
    let router: [String]
    let dns: [String]
    let lease: Int?
    let vendor: String?
}

enum DHCPError: LocalizedError {
    case permissionDenied
    case socketFailed
    case bindFailed
    case sendFailed
    case invalidMac
    case receiveFailed
    case interfaceUnavailable
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permission denied binding to UDP/68. Try running the app with elevated privileges."
        case .socketFailed:
            return "Failed to create a UDP socket."
        case .bindFailed:
            return "Failed to bind UDP/68."
        case .sendFailed:
            return "Failed to send DHCP discover."
        case .invalidMac:
            return "MAC must be 6 bytes like aa:bb:cc:dd:ee:ff."
        case .receiveFailed:
            return "Failed while receiving DHCP responses."
        case .interfaceUnavailable:
            return "Selected network interface is unavailable."
        }
    }
}

final class DHCPClient {
    nonisolated static func defaultHostname() -> String {
        Host.current().localizedName ?? Host.current().name ?? "SwiftDHCP"
    }
    
    nonisolated func query(config: DHCPQueryConfig) async throws -> [DHCPServerInfo] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.querySync(config: config)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    nonisolated private func querySync(config: DHCPQueryConfig) throws -> [DHCPServerInfo] {
        let macBytes: [UInt8]
        if let mac = config.mac, !mac.isEmpty {
            guard let parsed = parseMac(mac) else {
                throw DHCPError.invalidMac
            }
            macBytes = parsed
        } else {
            if let interfaceName = config.interfaceName,
               let interfaceMac = macBytesForInterface(interfaceName) {
                macBytes = interfaceMac
            } else if config.interfaceName != nil {
                throw DHCPError.interfaceUnavailable
            } else {
                macBytes = defaultMacBytes()
            }
        }
        
        let xid = UInt32.random(in: 0...UInt32.max)
        let discover = buildDiscover(mac: macBytes, xid: xid, hostname: config.hostname)
        
        let packets = try DHCPSocket.sendDiscoverAndCollectResponses(
            discover: discover,
            timeout: config.timeout,
            maxResponses: config.count,
            interfaceName: config.interfaceName
        )
        
        var servers: [String: DHCPServerInfo] = [:]
        for packetInfo in packets {
            let packet = packetInfo.data
            if packet.count < 240 {
                continue
            }
            
            guard let op = packet.byte(at: 0), op == 2 else { continue }
            guard let htype = packet.byte(at: 1), let hlen = packet.byte(at: 2), htype == 1, hlen == 6 else { continue }
            
            guard let responseXid = packet.readUInt32(at: 4) else { continue }
            guard responseXid == xid else { continue }
            
            let yiaddr = packet.subdata(in: 16..<20)
            let offer = ipString(from: yiaddr) ?? "0.0.0.0"
            
            let options = parseOptions(from: packet)
            if let messageType = options[53], !(messageType == Data([2]) || messageType == Data([5])) {
                continue
            }
            
            let serverId = ipString(from: options[54]) ?? ipString(from: packetInfo.source) ?? "unknown"
            
            let info = DHCPServerInfo(
                id: serverId,
                offer: offer,
                subnet: ipString(from: options[1]),
                router: listFromOption(options[3]),
                dns: listFromOption(options[6]),
                lease: secondsFromOption(options[51]),
                vendor: options[60].flatMap { String(data: $0, encoding: .ascii) }
            )
            servers[serverId] = info
        }
        
        return servers.keys.sorted().compactMap { servers[$0] }
    }
}

nonisolated private func buildDiscover(mac: [UInt8], xid: UInt32, hostname: String?) -> Data {
    var data = Data()
    data.appendUInt8(1)
    data.appendUInt8(1)
    data.appendUInt8(6)
    data.appendUInt8(0)
    data.appendUInt32(xid)
    data.appendUInt16(0)
    data.appendUInt16(0x8000)
    data.appendUInt32(0)
    data.appendUInt32(0)
    data.appendUInt32(0)
    data.appendUInt32(0)
    
    var chaddr = mac
    if chaddr.count < 16 {
        chaddr += Array(repeating: 0, count: 16 - chaddr.count)
    }
    data.append(contentsOf: chaddr)
    data.append(contentsOf: Array(repeating: 0, count: 64))
    data.append(contentsOf: Array(repeating: 0, count: 128))
    
    data.append(contentsOf: [0x63, 0x82, 0x53, 0x63])
    data.append(contentsOf: [0x35, 0x01, 0x01])
    
    if let hostname, !hostname.isEmpty {
        let name = hostname.data(using: .ascii, allowLossyConversion: true) ?? Data()
        let clipped = name.prefix(63)
        data.appendUInt8(0x0c)
        data.appendUInt8(UInt8(clipped.count))
        data.append(clipped)
    }
    
    data.append(contentsOf: [0x37, 0x03, 0x01, 0x03, 0x06])
    data.appendUInt8(0xff)
    return data
}

nonisolated private func parseOptions(from packet: Data) -> [UInt8: Data] {
    let cookie = Data([0x63, 0x82, 0x53, 0x63])
    guard let range = packet.range(of: cookie) else {
        return [:]
    }
    
    var index = range.upperBound
    var options: [UInt8: Data] = [:]
    
    while index < packet.count {
        let code = packet[index]
        if code == 255 { break }
        if code == 0 {
            index += 1
            continue
        }
        if index + 1 >= packet.count { break }
        let length = Int(packet[index + 1])
        let start = index + 2
        let end = start + length
        if end > packet.count { break }
        options[code] = packet.subdata(in: start..<end)
        index = end
    }
    
    return options
}

nonisolated private func listFromOption(_ option: Data?) -> [String] {
    guard let option, option.count % 4 == 0 else { return [] }
    var result: [String] = []
    for i in stride(from: 0, to: option.count, by: 4) {
        let chunk = option.subdata(in: i..<(i + 4))
        if let ip = ipString(from: chunk) {
            result.append(ip)
        }
    }
    return result
}

nonisolated private func secondsFromOption(_ option: Data?) -> Int? {
    guard let option, option.count == 4 else { return nil }
    guard let value = option.readUInt32(at: 0) else { return nil }
    return Int(value)
}

nonisolated private func parseMac(_ mac: String) -> [UInt8]? {
    let parts = mac.split(separator: ":")
    guard parts.count == 6 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
        guard let value = UInt8(part, radix: 16) else { return nil }
        bytes.append(value)
    }
    return bytes
}
