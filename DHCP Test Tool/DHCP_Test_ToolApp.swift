//
//  DHCP_Test_ToolApp.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//

import SwiftUI


@main
struct DHCP_Test_ToolApp: App {
    
    @State private var isAboutPresented: Bool = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .sheet(isPresented: $isAboutPresented) {
                    AboutView()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    isAboutPresented = true
                } label: {
                    Label("About DHCP Test Tool", systemImage: "info.circle")
                }
            }
        }
    }
}
