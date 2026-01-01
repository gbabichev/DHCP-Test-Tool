//
//  DHCPClient.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//

import Foundation
import Darwin

struct DHCPQueryConfig {
    var timeout: TimeInterval
    var count: Int
    var mac: String?
    var hostname: String?
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
            macBytes = defaultMacBytes()
        }

        let xid = UInt32.random(in: 0...UInt32.max)
        let discover = buildDiscover(mac: macBytes, xid: xid, hostname: config.hostname)

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            throw DHCPError.socketFailed
        }
        defer { close(sock) }

        var yes: Int32 = 1
        unsafe setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(68).bigEndian
        bindAddr.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = unsafe withUnsafePointer(to: &bindAddr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            if errno == EACCES {
                throw DHCPError.permissionDenied
            }
            throw DHCPError.bindFailed
        }

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(67).bigEndian
        dest.sin_addr = in_addr(s_addr: in_addr_t(INADDR_BROADCAST).bigEndian)

        let sendResult = discover.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, rawBuffer.baseAddress, rawBuffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult >= 0 else {
            throw DHCPError.sendFailed
        }

        var servers: [String: DHCPServerInfo] = [:]
        let deadline = Date().addingTimeInterval(config.timeout)

        while servers.count < config.count && Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }

            var pollFd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let timeoutMs = Int32(min(Double(Int32.max), max(0, remaining * 1000)))
            let ready = Darwin.poll(&pollFd, 1, timeoutMs)
            if ready == 0 {
                break
            }
            if ready < 0 {
                throw DHCPError.receiveFailed
            }
            if (pollFd.revents & Int16(POLLIN)) == 0 {
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 2048)
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let recvCount = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(sock, &buffer, buffer.count, 0, $0, &srcLen)
                }
            }
            if recvCount <= 0 {
                continue
            }

            let packet = Data(buffer.prefix(recvCount))
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

            let serverId = ipString(from: options[54]) ?? ipString(from: src.sin_addr) ?? "unknown"

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

nonisolated private func ipString(from option: Data?) -> String? {
    guard let option, option.count == 4 else { return nil }
    var value: in_addr_t = 0
    _ = withUnsafeMutableBytes(of: &value) { option.copyBytes(to: $0) }
    return ipString(from: in_addr(s_addr: value))
}

nonisolated private func ipString(from addr: in_addr) -> String? {
    var addr = addr
    guard let cString = inet_ntoa(addr) else { return nil }
    return String(cString: cString)
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

nonisolated private func defaultMacBytes() -> [UInt8] {
    var result: [UInt8] = []
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer {
        defer { freeifaddrs(ifaddrPointer) }
        var pointer = first
        while true {
            let ifaddr = pointer.pointee
            let name = String(cString: ifaddr.ifa_name)
            if let addr = ifaddr.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let sdlPtr = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self)
                let sdl = sdlPtr.pointee
                if sdl.sdl_alen == 6, let base = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) {
                    let start = base + Int(sdl.sdl_nlen)
                    let macPtr = UnsafeRawPointer(sdlPtr)
                        .advanced(by: start)
                        .assumingMemoryBound(to: UInt8.self)
                    let bytes = (0..<Int(sdl.sdl_alen)).map { macPtr[$0] }
                    if bytes.count == 6 {
                        result = bytes
                        if name == "en0" {
                            return result
                        }
                    }
                }
            }
            if let next = ifaddr.ifa_next {
                pointer = next
            } else {
                break
            }
        }
    }

    if result.count == 6 {
        return result
    }

    return (0..<6).map { _ in UInt8.random(in: 0...255) }
}

private extension Data {
    nonisolated mutating func appendUInt8(_ value: UInt8) {
        append(contentsOf: [value])
    }

    nonisolated mutating func appendUInt16(_ value: UInt16) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    nonisolated mutating func appendUInt32(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    nonisolated func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        return self[self.startIndex.advanced(by: index)]
    }

    nonisolated func readUInt32(at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= count else { return nil }
        let slice = self[index..<(index + 4)]
        return UInt32(slice[slice.startIndex]) << 24
            | UInt32(slice[slice.startIndex.advanced(by: 1)]) << 16
            | UInt32(slice[slice.startIndex.advanced(by: 2)]) << 8
            | UInt32(slice[slice.startIndex.advanced(by: 3)])
    }
}
