//
//  FluxBarApp.swift
//  FluxBar
//
//  Created by noah on 2026/3/13.
//

import SwiftUI

@main
struct FluxBarApp: App {
    @NSApplicationDelegateAdaptor(FluxBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
