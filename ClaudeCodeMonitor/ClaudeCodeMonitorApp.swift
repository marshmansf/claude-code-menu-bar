import SwiftUI

@main
struct ClaudeCodeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            PreferencesView()
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    if NSApp.activationPolicy() == .accessory {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
