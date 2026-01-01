//
//  ContentView.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//

import SwiftUI

struct ContentView: View {
    @State private var timeout: Double = 3.0
    @State private var count: Int = 5
    @State private var macAddress: String = ""
    @State private var hostname: String = DHCPClient.defaultHostname()
    @State private var isRunning = false
    @State private var hasRun = false
    @State private var errorMessage: String?
    @State private var results: [DHCPServerInfo] = []
    
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Timeout (sec)")
                            TextField("", value: $timeout, format: .number)
                                .frame(width: 80)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Max responses: \(count)")
                            Slider(
                                value: Binding(
                                    get: { Double(count) },
                                    set: { count = Int($0) }
                                ),
                                in: 1...25,
                                step: 1
                            )
                        }
                        TextField("Client MAC (optional)", text: $macAddress)
                        TextField("Hostname", text: $hostname)
                    }
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
            
            if isRunning {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    ProgressView("Listening for DHCP responses...")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .toolbar {
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
            timeout: timeout,
            count: count,
            mac: macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : macAddress,
            hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hostname
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
