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
        VStack(alignment: .leading, spacing: 16) {

            GroupBox("Query Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Timeout (sec)")
                        TextField("", value: $timeout, format: .number)
                            .frame(width: 80)
                    }
                    Stepper("Max responses: \(count)", value: $count, in: 1...25)
                    TextField("Client MAC (optional)", text: $macAddress)
                    TextField("Hostname", text: $hostname)
                }
                .padding(.top, 4)
            }

            if isRunning {
                ProgressView("Listening for DHCP responses...")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if hasRun && results.isEmpty {
                Text("No DHCP servers responded.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Responses") {
                if results.isEmpty {
                    Text(hasRun ? "No responses yet." : "Run a query to list responding DHCP servers.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                } else {
                    List(results) { server in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(server.id)
                                .font(.headline)
                            Text("offer: \(server.offer)")
                            if let subnet = server.subnet {
                                Text("subnet: \(subnet)")
                            }
                            if !server.router.isEmpty {
                                Text("router: \(server.router.joined(separator: ", "))")
                            }
                            if !server.dns.isEmpty {
                                Text("dns: \(server.dns.joined(separator: ", "))")
                            }
                            if let lease = server.lease {
                                Text("lease: \(lease)s")
                            }
                            if let vendor = server.vendor, !vendor.isEmpty {
                                Text("vendor: \(vendor)")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .padding()
        //.frame(minWidth: 520, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItemGroup {
                Button(isRunning ? "Querying..." : "Query DHCP Servers") {
                    runQuery()
                }
                .disabled(isRunning)

                Button("Clear Results") {
                    results = []
                    errorMessage = nil
                    hasRun = false
                }
                .disabled(isRunning || (results.isEmpty && errorMessage == nil))
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
