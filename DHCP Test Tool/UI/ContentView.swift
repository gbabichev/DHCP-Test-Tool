//
//  ContentView.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("timeoutSeconds") private var timeout: Int = 5
    @AppStorage("maxResponses") private var count: Int = 5
    @State private var macAddress: String = ""
    @State private var hostname: String = DHCPClient.defaultHostname()
    @State private var interfaces: [NetworkInterface] = []
    @State private var selectedInterfaceName: String = ""
    @State private var isRunning = false
    @State private var hasRun = false
    @State private var errorMessage: String?
    @State private var results: [DHCPServerInfo] = []
    
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        let labelWidth: CGFloat = 220
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Timeout (sec): \(timeout)")
                            Slider(
                                value: Binding(
                                    get: { Double(timeout) },
                                    set: { timeout = Int($0) }
                                ),
                                in: 1...10,
                                step: 1
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Max responses: \(count)")
                            Slider(
                                value: Binding(
                                    get: { Double(count) },
                                    set: { count = Int($0) }
                                ),
                                in: 1...10,
                                step: 1
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Network Device")
                                    Text("Selects the interface used for DHCP discovery.")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(width: labelWidth, alignment: .leading)
                                HStack(spacing: 12) {
                                    Picker("", selection: $selectedInterfaceName) {
                                        ForEach(interfaces) { device in
                                            Text(device.displayName)
                                                .tag(device.name)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        refreshInterfaces()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Reload active network devices")
                                }
                            }
                            if interfaces.isEmpty {
                                Text("No active network interfaces detected.")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spoof MAC Address")
                                Text("Overrides the client MAC used in the DHCP discover.")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: labelWidth, alignment: .leading)
                            HStack(spacing: 8) {
                                TextField("Client MAC (optional)", text: $macAddress)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    macAddress = randomMacAddress()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Generate a random MAC address")
                            }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Client Hostname")
                                Text("Sets the hostname option sent to DHCP servers.")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: labelWidth, alignment: .leading)
                            HStack(spacing: 8) {
                                TextField("Hostname", text: $hostname)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    hostname = DHCPClient.defaultHostname()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Reset to the default hostname")
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Text("Query Settings")
                        .bold()
                        .font(.title2)
                }
                
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if hasRun && !isRunning && results.isEmpty {
                    Text("No DHCP servers responded.")
                        .foregroundStyle(.secondary)
                }
                
                
                GroupBox {
                    if results.isEmpty {
                        Text(hasRun ? "No responses yet." : "Run a query to list responding DHCP servers.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)
                                ],
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(results) { server in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(server.id)
                                            .font(.headline)
                                        InfoRow(label: "Offer", value: server.offer)
                                        if let subnet = server.subnet {
                                            InfoRow(label: "Subnet", value: subnet)
                                        }
                                        if !server.router.isEmpty {
                                            InfoRow(label: "Router", value: server.router.joined(separator: ", "))
                                        }
                                        if !server.dns.isEmpty {
                                            InfoRow(label: "DNS", value: server.dns.joined(separator: ", "))
                                        }
                                        if let lease = server.lease {
                                            InfoRow(label: "Lease", value: "\(lease)s")
                                        }
                                        if let vendor = server.vendor, !vendor.isEmpty {
                                            InfoRow(label: "Vendor", value: vendor)
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .padding(.top, 4)
                        }
                        .frame(minHeight: 180)
                    }
                } label: {
                    Text("Responses")
                        .bold()
                        .font(.title2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(isRunning)
            
            if isRunning {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    ProgressView("Listening for DHCP responses...")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.8))
                        )
                }
            }
        }
//        .overlay(alignment: .bottomTrailing) {
//            BetaTag()
//                .padding(12)
//        }
        .frame(minWidth: 520, minHeight: 550)
        .onAppear {
            refreshInterfaces()
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text("DHCP Test Tool")
                    .padding(12)
                    .bold()
            }
            ToolbarItemGroup {
                Button {
                    results = []
                    errorMessage = nil
                    hasRun = false
                } label: {
                    Label("Clear Results", systemImage: "xmark.circle")
                }
                .disabled(isRunning || (results.isEmpty && errorMessage == nil))
                
                Button {
                    runQuery()
                } label: {
                    Label(isRunning ? "Querying..." : "Query DHCP Servers", systemImage: "play.fill")
                }
                .disabled(isRunning)
            }
        }
    }
    
    private func runQuery() {
        isRunning = true
        errorMessage = nil
        results = []
        hasRun = true
        
        let config = DHCPQueryConfig(
            timeout: Double(timeout),
            count: count,
            mac: macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : macAddress,
            hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hostname,
            interfaceName: selectedInterfaceName.isEmpty ? nil : selectedInterfaceName
        )
        
        Task {
            do {
                let servers = try await DHCPClient().query(config: config)
                await MainActor.run {
                    results = servers
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }
    
    private func refreshInterfaces() {
        let devices = activeNetworkInterfaces()
        interfaces = devices
        if selectedInterfaceName.isEmpty, let first = devices.first {
            selectedInterfaceName = first.name
        }
    }

    private func randomMacAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...UInt8.max) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes
            .map { byte -> String in
                let hex = String(byte, radix: 16, uppercase: true)
                return hex.count == 1 ? "0" + hex : hex
            }
            .joined(separator: ":")
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
