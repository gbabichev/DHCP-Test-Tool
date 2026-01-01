//
//  DHCPSocket.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//
//  Low-level UDP socket I/O for sending DHCP discovers and collecting responses.

import Foundation
import Darwin

struct DHCPPacket {
    let data: Data
    let source: in_addr
}

enum DHCPSocket {
    nonisolated static func sendDiscoverAndCollectResponses(
        discover: Data,
        timeout: TimeInterval,
        maxResponses: Int
    ) throws -> [DHCPPacket] {
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

        let sendResult = unsafe discover.withUnsafeBytes { rawBuffer in
            unsafe withUnsafePointer(to: &dest) {
                unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    unsafe sendto(
                        sock,
                        rawBuffer.baseAddress,
                        rawBuffer.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sendResult >= 0 else {
            throw DHCPError.sendFailed
        }

        var packets: [DHCPPacket] = []
        let deadline = Date().addingTimeInterval(timeout)

        while packets.count < maxResponses && Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }

            var pollFd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let timeoutMs = Int32(min(Double(Int32.max), max(0, remaining * 1000)))
            let ready = unsafe Darwin.poll(&pollFd, 1, timeoutMs)
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

            let recvCount = unsafe withUnsafeMutablePointer(to: &src) {
                unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    unsafe recvfrom(sock, &buffer, buffer.count, 0, $0, &srcLen)
                }
            }
            if recvCount <= 0 {
                continue
            }

            let packet = Data(buffer.prefix(recvCount))
            packets.append(DHCPPacket(data: packet, source: src.sin_addr))
        }

        return packets
    }
}
