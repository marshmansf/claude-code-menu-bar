import Foundation
import AppKit

class TerminalContentParser {
    static let shared = TerminalContentParser()
    
    // Pattern to detect working state: "✶ Harmonizing… (56s · ⚒ 110 tokens · esc to interrupt)"
    // Match any single character as the working indicator (Claude uses various symbols)
    // The working phrase should be on a single line (no newlines)
    // Support both ellipsis (…) and three dots (...)
    // Also support variations with different spacing and token indicators
    private let workingPattern = #"^(.)\s*([^\n…\.]+?)(?:\.\.\.|…)\s*\((\d+)s\s*·\s*.\s*([\d,\.]+)k?\s*tokens?\s*·\s*esc\s+to\s+interrupt\)"#
    
    // Pattern to detect context percentage: "Context left until auto-compact: 26%"
    private let contextPattern = #"Context left until auto-compact:\s*(\d+)%"#
    
    // Cached regex objects for performance
    private lazy var workingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: workingPattern, options: [.anchorsMatchLines])
    }()
    
    private lazy var contextRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: contextPattern, options: [])
    }()
    
    struct WorkingState {
        let isWorking: Bool
        let workingPhrase: String? // e.g., "Harmonizing"
        let elapsedSeconds: Int?
        let currentTokens: Int?
    }
    
    struct ContextInfo {
        let percentageLeft: Int
    }
    
    func getTerminalContent(for session: Session) -> String? {
        guard let tty = session.terminalAppName else { return nil }
        
        
        // Use AppleScript to get terminal content
        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            set sessionTTY to tty of aSession
                            if sessionTTY contains "\(tty)" then
                                -- Get the text from the session, focusing on the bottom
                                set sessionText to contents of aSession
                                -- Get only the last portion of text (last 2000 chars should include the status)
                                if length of sessionText > 2000 then
                                    set sessionText to text -2000 thru -1 of sessionText
                                end if
                                return sessionText
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            
            if error == nil, let output = result.stringValue {
                return output
            }
        }
        
        return nil
    }
    
    func parseWorkingState(from content: String) -> WorkingState {
        if let regex = try? NSRegularExpression(pattern: workingPattern, options: [.anchorsMatchLines]) {
            let range = NSRange(location: 0, length: content.utf16.count)
            
            if let match = regex.firstMatch(in: content, options: [], range: range) {
                var workingPhrase: String?
                var elapsedSeconds: Int?
                var currentTokens: Int?
                
                // Group 1 is now the symbol, group 2 is the phrase
                if match.numberOfRanges > 2,
                   let phraseRange = Range(match.range(at: 2), in: content) {
                    workingPhrase = String(content[phraseRange])
                }
                
                // Group 3 is the elapsed seconds
                if match.numberOfRanges > 3,
                   let secondsRange = Range(match.range(at: 3), in: content) {
                    elapsedSeconds = Int(content[secondsRange])
                }
                
                // Group 4 is the token count
                if match.numberOfRanges > 4,
                   let tokensRange = Range(match.range(at: 4), in: content) {
                    let tokenString = String(content[tokensRange])
                    // Handle "1.7k" format
                    if tokenString.hasSuffix("k") {
                        let numStr = tokenString.dropLast()
                        if let num = Double(numStr) {
                            currentTokens = Int(num * 1000)
                        }
                    } else {
                        // Handle regular number with possible commas
                        let cleanedTokens = tokenString.replacingOccurrences(of: ",", with: "")
                        currentTokens = Int(cleanedTokens)
                    }
                }
                
                return WorkingState(
                    isWorking: true,
                    workingPhrase: workingPhrase,
                    elapsedSeconds: elapsedSeconds,
                    currentTokens: currentTokens
                )
            }
        }
        
        return WorkingState(
            isWorking: false,
            workingPhrase: nil,
            elapsedSeconds: nil,
            currentTokens: nil
        )
    }
    
    func parseContextPercentage(from content: String) -> ContextInfo? {
        if let regex = try? NSRegularExpression(pattern: contextPattern, options: []) {
            let range = NSRange(location: 0, length: content.utf16.count)
            
            if let match = regex.firstMatch(in: content, options: [], range: range) {
                if match.numberOfRanges > 1,
                   let percentRange = Range(match.range(at: 1), in: content),
                   let percentage = Int(content[percentRange]) {
                    return ContextInfo(percentageLeft: percentage)
                }
            }
        }
        
        return nil
    }
    
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
    
    func updateSessionWithTerminalContent(_ session: inout Session) {
        // Reset working state first
        session.isWorking = false
        session.workingPhrase = nil
        session.workingElapsedSeconds = nil
        session.workingCurrentTokens = nil
        
        guard let content = getTerminalContent(for: session) else {
            return
        }
        
        
        // Parse working state
        let workingState = parseWorkingState(from: content)
        
        // Store previous state for comparison
        let previousWorking = session.isWorking
        let previousPhrase = session.workingPhrase
        
        session.isWorking = workingState.isWorking
        session.workingPhrase = workingState.workingPhrase
        session.workingElapsedSeconds = workingState.elapsedSeconds
        session.workingCurrentTokens = workingState.currentTokens
        
        
        // Parse context percentage
        if let contextInfo = parseContextPercentage(from: content) {
            // Store the percentage as shown in terminal (X% until auto-compact)
            session.compactionPercentage = Double(contextInfo.percentageLeft)
        } else {
            // Set to 0 to indicate no percentage available
            session.compactionPercentage = 0.0
        }
        
        // If not working and has output, mark as waiting
        if !workingState.isWorking && content.count > 100 {
            session.hasOutput = true
        }
    }
}
