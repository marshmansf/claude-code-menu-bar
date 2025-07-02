import Foundation
import AppKit

class TerminalContentParser {
    static let shared = TerminalContentParser()
    
    // Only keep the method for getting terminal window titles
    func getTerminalWindowTitle(for session: Session) -> String? {
        guard let tty = session.terminalAppName else { return nil }
        
        // Use AppleScript to get window title
        let script = """
        on run
            set targetTTY to "\(tty)"
            
            tell application "iTerm2"
                set windows_list to windows
                repeat with w in windows_list
                    set tabs_list to tabs of w
                    repeat with t in tabs_list
                        set sessions_list to sessions of t
                        repeat with s in sessions_list
                            try
                                set sessionTTY to tty of s
                                if sessionTTY contains targetTTY then
                                    -- Try to get the session name first
                                    try
                                        set sessionName to name of s
                                        if sessionName is not missing value and sessionName is not "" then
                                            return sessionName
                                        end if
                                    end try
                                    
                                    -- Fall back to tab name
                                    try
                                        set tabName to name of t
                                        if tabName is not missing value and tabName is not "" then
                                            return tabName
                                        end if
                                    end try
                                    
                                    -- Fall back to window name
                                    try
                                        set windowName to name of w
                                        return windowName
                                    end try
                                    
                                    return "Claude Session"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            
            return missing value
        end run
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            
            if error == nil, let title = result.stringValue {
                return title
            }
        }
        
        return nil
    }
}