import Foundation

class HookConfigManager {
    static let shared = HookConfigManager()
    
    private let settingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    
    func ensureHooksConfigured() {
        // Create .claude directory if it doesn't exist
        let claudeDir = NSString(string: "~/.claude").expandingTildeInPath
        if !FileManager.default.fileExists(atPath: claudeDir) {
            try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }
        
        // Read existing settings or create new ones
        var settings: [String: Any] = [:]
        
        if FileManager.default.fileExists(atPath: settingsPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    settings = json
                }
            } catch {
                print("Error reading settings.json: \(error)")
            }
        }
        
        // Check if hooks are already configured
        if let hooks = settings["hooks"] as? [String: Any],
           hooks["PreToolUse"] != nil,
           hooks["PostToolUse"] != nil,
           hooks["Stop"] != nil,
           hooks["Notification"] != nil {
            print("Hooks already configured")
            return
        }
        
        // Add hook configuration
        let hookConfig: [String: Any] = [
            "PreToolUse": [[
                "matcher": ".*",
                "hooks": [[
                    "type": "command",
                    "command": "curl -X POST http://localhost:8737/hook/pretooluse -H 'Content-Type: application/json' -d @- 2>/dev/null || true"
                ]]
            ]],
            "PostToolUse": [[
                "matcher": ".*",
                "hooks": [[
                    "type": "command",
                    "command": "curl -X POST http://localhost:8737/hook/posttooluse -H 'Content-Type: application/json' -d @- 2>/dev/null || true"
                ]]
            ]],
            "Stop": [[
                "matcher": ".*",
                "hooks": [[
                    "type": "command",
                    "command": "curl -X POST http://localhost:8737/hook/stop -H 'Content-Type: application/json' -d @- 2>/dev/null || true"
                ]]
            ]],
            "Notification": [[
                "matcher": ".*",
                "hooks": [[
                    "type": "command",
                    "command": "curl -X POST http://localhost:8737/hook/notification -H 'Content-Type: application/json' -d @- 2>/dev/null || true"
                ]]
            ]]
        ]
        
        settings["hooks"] = hookConfig
        
        // Write updated settings
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: settingsPath))
            print("Hook configuration added to settings.json")
        } catch {
            print("Error writing settings.json: \(error)")
        }
    }
}