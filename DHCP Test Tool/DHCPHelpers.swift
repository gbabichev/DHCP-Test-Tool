//
//  DHCPHelpers.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//
//  Shared helpers for packet encoding/decoding and low-level address/MAC utilities.

import Foundation
import Darwin

nonisolated func ipString(from option: Data?) -> String? {
    guard let option, option.count == 4 else { return nil }
    var value: in_addr_t = 0
    _ = unsafe withUnsafeMutableBytes(of: &value) { unsafe option.copyBytes(to: $0) }
    return ipString(from: in_addr(s_addr: value))
}

nonisolated func ipString(from addr: in_addr) -> String? {
    let addr = addr
    guard let cString = unsafe inet_ntoa(addr) else { return nil }
    return unsafe String(cString: cString)
}

nonisolated func defaultMacBytes() -> [UInt8] {
    var result: [UInt8] = []
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    if unsafe getifaddrs(&ifaddrPointer) == 0, let first = unsafe ifaddrPointer {
        defer { unsafe freeifaddrs(ifaddrPointer) }
        var pointer = unsafe first
        while true {
            let ifaddr = unsafe pointer.pointee
            let name = unsafe String(cString: ifaddr.ifa_name)
            if let addr = unsafe ifaddr.ifa_addr, unsafe addr.pointee.sa_family == UInt8(AF_LINK) {
                let sdlPtr = unsafe UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self)
                let sdl = unsafe sdlPtr.pointee
                if sdl.sdl_alen == 6, let base = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) {
                    let start = base + Int(sdl.sdl_nlen)
                    let macPtr = unsafe UnsafeRawPointer(sdlPtr)
                        .advanced(by: start)
                        .assumingMemoryBound(to: UInt8.self)
                    let bytes = (0..<Int(sdl.sdl_alen)).map { unsafe macPtr[$0] }
                    if bytes.count == 6 {
                        result = bytes
                        if name == "en0" {
                            return result
                        }
                    }
                }
            }
            if let next = unsafe ifaddr.ifa_next {
                unsafe pointer = unsafe next
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

extension Data {
    nonisolated mutating func appendUInt8(_ value: UInt8) {
        append(contentsOf: [value])
    }

    nonisolated mutating func appendUInt16(_ value: UInt16) {
        var big = value.bigEndian
        unsafe Swift.withUnsafeBytes(of: &big) { unsafe append(contentsOf: $0) }
    }

    nonisolated mutating func appendUInt32(_ value: UInt32) {
        var big = value.bigEndian
        unsafe Swift.withUnsafeBytes(of: &big) { unsafe append(contentsOf: $0) }
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
