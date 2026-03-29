//
//  ScreenMaskRecorderApp.swift
//  ScreenMaskRecorder
//
//  Created on 2025-03-29.
//

import SwiftUI

@main
struct ScreenMaskRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .navigationTitle("Miro Cap")
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
