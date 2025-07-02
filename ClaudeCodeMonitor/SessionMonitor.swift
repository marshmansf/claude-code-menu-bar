import Foundation
import AppKit
import SwiftUI

// MARK: - Debug Logging

class DebugLog: ObservableObject {
    static let shared = DebugLog()
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel
        
        var color: Color {
            switch level {
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            case .success: return .green
            }
        }
    }
    
    enum LogLevel {
        case info
        case warning
        case error
        case success
    }
    
    @Published var entries: [LogEntry] = []
    private let maxEntries = 1000
    
    func log(_ message: String, level: LogLevel = .info) {
        DispatchQueue.main.async {
            self.entries.append(LogEntry(
                timestamp: Date(),
                message: message,
                level: level
            ))
            
            // Limit the number of entries
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            
            // Also print to console
            print(message)
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }
}

// Convenience function
func debugLog(_ message: String, level: DebugLog.LogLevel = .info) {
    DebugLog.shared.log(message, level: level)
}

class SessionMonitor: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isInitialLoadComplete = false
    var onSessionsChanged: (() -> Void)?
    private var sessionOrder: [Int32] = []  // Track PID order
    
    private let fileParser = ClaudeFileParser.shared
    private let processDetector = ProcessDetector.shared
    private let terminalParser = TerminalContentParser.shared
    private let hookServer = HookServer.shared
    private let transcriptReader = TranscriptReader.shared
    
    // Map hook session IDs to process PIDs
    private var hookSessionToPID: [String: Int32] = [:]
    // Map process PIDs to their terminal TTYs for window focusing
    private var pidToTTY: [Int32: String] = [:]
    // Persistent mapping of PID to JSONL file path from hooks
    private var pidToJsonlPath: [Int32: String] = [:]
    // Map PID to transcript path for accurate token counting
    private var pidToTranscriptPath: [Int32: String] = [:]
    // Track when hook sessions first appear for time correlation
    private var hookSessionFirstSeen: [String: Date] = [:]
    // Track mapping confidence scores
    private var mappingConfidence: [String: Double] = [:]
    
    // Enhanced working directory mapping
    private var pidToWorkingDirectory: [Int32: String] = [:] // Normalized working directories by PID
    private var workingDirectoryToHookSession: [String: String] = [:] // Map normalized cwd to hook session ID
    
    // Session mapping attempt results
    struct SessionMapping {
        let sessionId: String
        let pid: Int32
        let confidence: Double
        let method: MappingMethod
        let timestamp: Date
    }
    
    enum MappingMethod {
        case workingDirectoryMatch
        case startTimeCorrelation  
        case projectNameMatch
        case firstAvailable
    }
    
    func startMonitoring() {
        debugLog("=== Starting Claude Code Monitor ===", level: .success)
        
        // Start the hook server
        hookServer.start()
        debugLog("Hook server started")
        
        // Set up hook callbacks
        hookServer.onPreToolUse = { [weak self] hookData in
            debugLog("📥 HOOK: PreToolUse - Session: \(hookData.sessionId), Tool: \(hookData.toolName)", level: .info)
            self?.handlePreToolUse(hookData)
        }
        
        hookServer.onPostToolUse = { [weak self] hookData in
            debugLog("📤 HOOK: PostToolUse - Session: \(hookData.sessionId), Tool: \(hookData.toolName)", level: .info)
            self?.handlePostToolUse(hookData)
        }
        
        hookServer.onStop = { [weak self] hookData in
            debugLog("🛑 HOOK: Stop - Session: \(hookData.sessionId)", level: .warning)
            self?.handleStop(hookData)
        }
        
        hookServer.onNotification = { [weak self] hookData in
            debugLog("🔔 HOOK: Notification - Session: \(hookData.sessionId)", level: .warning)
            self?.handleNotification(hookData)
        }
        
        // Perform initial scan immediately to reduce startup delay
        performInitialScan()
        
        // Periodically rescan to clean up any orphaned sessions
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            debugLog("⏰ Periodic session scan triggered", level: .info)
            self?.scanForClaudeProcesses()
        }
    }
    
    func stopMonitoring() {
        hookServer.stop()
    }
    
    private func scanForClaudeProcesses() {
        // Initial scan to find Claude processes and set up basic session info
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            let claudeProcesses = self.processDetector.getAllClaudeProcesses()
            debugLog("🔍 Found \(claudeProcesses.count) Claude process(es)", level: .info)
            
            var updatedSessions: [Session] = []
            
            for process in claudeProcesses {
                // Check if we already have a session for this PID to preserve all hook data
                var session: Session
                if let existingSession = self.sessions.first(where: { $0.processID == process.pid }) {
                    // Update existing session but preserve ALL important hook-provided data
                    session = existingSession
                    session.lastUpdateTime = Date()
                    session.terminalAppName = process.terminalWindow
                    session.terminalTTY = process.terminalWindow
                    session.workingDirectory = process.workingDirectory
                    
                    // Don't overwrite hook-provided data
                    // Preserving existing session data
                } else {
                    // Create new session for new process
                    session = Session(processID: process.pid, commandLine: process.commandLine)
                    session.lastUpdateTime = Date()
                    session.terminalAppName = process.terminalWindow
                    session.terminalTTY = process.terminalWindow
                    session.workingDirectory = process.workingDirectory
                    debugLog("📍 New session detected - PID: \(process.pid), TTY: \(process.terminalWindow ?? "unknown")", level: .success)
                }
                
                // Store TTY for window focusing
                if let tty = process.terminalWindow {
                    self.pidToTTY[process.pid] = tty
                }
                
                // Get terminal window title for project name
                if let windowTitle = self.terminalParser.getTerminalWindowTitle(for: session) {
                    var cleanTitle = windowTitle.replacingOccurrences(of: " (claude)", with: "")
                    cleanTitle = cleanTitle.trimmingCharacters(in: CharacterSet(charactersIn: "✳✶"))
                    cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
                    
                    if cleanTitle.contains("/") {
                        let components = cleanTitle.split(separator: "/")
                        if let lastComponent = components.last {
                            session.projectName = String(lastComponent)
                        }
                    } else {
                        session.projectName = cleanTitle
                    }
                }
                
                // Try to extract task description from JSONL if we have one and don't already have it
                // Only update if we don't have a task description AND we have a JSONL file
                if session.taskDescription == nil || session.taskDescription == "Claude Session" {
                    if let jsonlFile = self.pidToJsonlPath[process.pid] {
                        print("PID \(process.pid) mapped to transcript: \(jsonlFile)")
                        if let newTaskDescription = self.transcriptReader.getTaskDescription(
                            from: jsonlFile,
                            sessionId: "scan-\(process.pid)"
                        ) {
                            session.taskDescription = newTaskDescription
                        }
                    } else {
                        print("PID \(process.pid) has no mapped transcript file")
                    }
                } else {
                    // Already has task description
                }
                
                // Update working directory mapping
                if let workingDir = process.workingDirectory {
                    let normalizedPath = self.normalizeWorkingDirectory(workingDir)
                    self.pidToWorkingDirectory[process.pid] = normalizedPath
                    
                    // Check if we have a hook session for this working directory
                    if let hookSessionId = self.workingDirectoryToHookSession[normalizedPath],
                       self.hookSessionToPID[hookSessionId] == nil {
                        // Map this PID to the hook session
                        self.hookSessionToPID[hookSessionId] = process.pid
                        print("Mapped idle PID \(process.pid) to hook session \(hookSessionId) via working directory")
                    }
                }
                
                // Set up JSONL mapping if we don't have one from hooks
                if self.pidToJsonlPath[process.pid] == nil {
                    // Try to find JSONL file that matches this session's working directory
                    if let workingDir = session.workingDirectory {
                        let normalizedWorkingDir = self.normalizeWorkingDirectory(workingDir)
                        let allJsonlFiles = self.fileParser.findProjectJSONLFiles()
                        
                        // Look for JSONL files that match the working directory
                        for jsonlFile in allJsonlFiles {
                            if let fileWorkingDir = self.fileParser.getWorkingDirectory(from: jsonlFile.path) {
                                let normalizedFileDir = self.normalizeWorkingDirectory(fileWorkingDir)
                                if normalizedFileDir == normalizedWorkingDir {
                                    self.pidToJsonlPath[process.pid] = jsonlFile.path
                                    print("Mapped PID \(process.pid) to JSONL based on working directory: \(jsonlFile.path)")
                                    
                                    // Extract task description immediately
                                    session.taskDescription = self.transcriptReader.getTaskDescription(
                                        from: jsonlFile.path,
                                        sessionId: "scan-\(process.pid)"
                                    )
                                    break
                                }
                            }
                        }
                        
                        if self.pidToJsonlPath[process.pid] == nil {
                            print("No JSONL found for working directory \(normalizedWorkingDir) for PID \(process.pid)")
                        }
                    } else {
                        print("No working directory for PID \(process.pid), cannot map to JSONL")
                    }
                }
                
                updatedSessions.append(session)
            }
            
            DispatchQueue.main.async {
                self.sessions = updatedSessions
                
                // Log session summary
                debugLog("📊 Session Summary:", level: .info)
                for (index, session) in updatedSessions.enumerated() {
                    let hookInfo = session.hookSessionId != nil ? "Hook: \(session.hookSessionId!)" : "No hook"
                    let workingDir = session.workingDirectory ?? "unknown"
                    let status = session.isWorking ? "🟢 Working" : "🟡 Waiting"
                    
                    // Detect terminal app and tmux for each session
                    let terminalApp = self.detectTerminalApp(for: session.processID)
                    let tmuxInfo = session.terminalTTY != nil ? self.getTmuxInfo(for: session.terminalTTY!) : nil
                    let tmuxStatus = tmuxInfo != nil ? "📺 tmux:\(tmuxInfo!.sessionName):\(tmuxInfo!.windowIndex).\(tmuxInfo!.paneIndex)" : "No tmux"
                    
                    debugLog("  [\(index + 1)] PID: \(session.processID) | \(status) | \(terminalApp) | \(tmuxStatus) | \(hookInfo) | Dir: \(workingDir)")
                }
                
                self.onSessionsChanged?()
            }
        }
    }
    
    func focusTerminalWindow(for session: Session) {
        debugLog("=== focusTerminalWindow called ===")
        debugLog("Session PID: \(session.processID)")
        debugLog("Session terminal app name: \(session.terminalAppName ?? "nil")")
        debugLog("Session TTY: \(session.terminalTTY ?? "nil")")
        
        // Clear the waiting flag when focusing
        if let index = sessions.firstIndex(where: { $0.processID == session.processID }) {
            sessions[index].hasOutput = false
            onSessionsChanged?()
        }
        
        // Close the popover first to ensure it doesn't interfere
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.closePopover()
        }
        
        // Detect which terminal app owns this process
        let terminalApp = self.detectTerminalApp(for: session.processID)
        debugLog("Detected terminal app: \(terminalApp)")
        
        // Update the session with the detected terminal app
        if let index = sessions.firstIndex(where: { $0.processID == session.processID }) {
            sessions[index].terminalAppName = terminalApp
        }
        
        // Activate the appropriate terminal app first
        if terminalApp == "iTerm2" {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) {
                let result = app.activate(options: [])
                debugLog("iTerm2 activation result: \(result)", level: result ? .success : .warning)
            } else {
                debugLog("iTerm2 not found in running applications!", level: .error)
            }
        } else if terminalApp == "Terminal" {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
                let result = app.activate(options: [])
                debugLog("Terminal activation result: \(result)", level: result ? .success : .warning)
            } else {
                debugLog("Terminal.app not found in running applications!", level: .error)
            }
        }
        
        // Then handle window/pane focusing after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            // Try to focus the specific terminal window using the TTY
            if let tty = session.terminalTTY {
                debugLog("Using TTY for focusing: \(tty)")
                switch terminalApp {
                case "iTerm2":
                    self.focusITerm2Window(tty: tty)
                case "Terminal":
                    self.focusTerminalAppWindow(tty: tty)
                default:
                    debugLog("Unknown terminal app, using generic approach", level: .warning)
                    // Try generic approach
                    self.focusWindowByPID(session.processID)
                }
            } else {
                debugLog("No TTY info, using fallback", level: .warning)
                // Fallback if we don't have TTY info
                self.focusWindowByPID(session.processID)
            }
        }
    }
    
    private func detectTerminalApp(for pid: Int32) -> String {
        debugLog("🔍 Detecting terminal app for PID: \(pid)")
        
        // First check if this process is in tmux
        if let tty = pidToTTY[pid], let tmuxInfo = getTmuxInfo(for: tty) {
            debugLog("   Process is in tmux session: \(tmuxInfo.sessionName)")
            
            // Method 1: Check tmux client TTY
            if let hostTTY = tmuxInfo.hostTTY {
                debugLog("   Found tmux client TTY: \(hostTTY)")
                
                // Look for processes that have this TTY
                let psTask = Process()
                psTask.launchPath = "/bin/ps"
                psTask.arguments = ["-t", hostTTY.replacingOccurrences(of: "/dev/", with: ""), "-o", "command="]
                
                let psPipe = Pipe()
                psTask.standardOutput = psPipe
                psTask.standardError = Pipe()
                
                psTask.launch()
                psTask.waitUntilExit()
                
                if let psOutput = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    debugLog("   Processes on host TTY: \(psOutput)")
                    
                    // Check each line for terminal apps
                    let lines = psOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
                    for line in lines {
                        // Look for iTerm2 process patterns
                        if line.contains("/Applications/iTerm.app") || 
                           line.contains("iTerm2") ||
                           line.contains("-psn_") {  // Process Serial Number indicates GUI app
                            debugLog("   ✅ Detected iTerm2 via tmux client TTY", level: .success)
                            return "iTerm2"
                        }
                        // Look for Terminal.app patterns
                        if line.contains("/System/Applications/Utilities/Terminal.app") ||
                           line.contains("Terminal.app") {
                            debugLog("   ✅ Detected Terminal.app via tmux client TTY", level: .success)
                            return "Terminal"
                        }
                    }
                }
            }
            
            // Method 2: Check all iTerm2 windows for this tmux session
            debugLog("   Checking iTerm2 windows for tmux session")
            let checkIterm = Process()
            checkIterm.launchPath = "/usr/bin/osascript"
            checkIterm.arguments = ["-e", """
                tell application "System Events"
                    if exists application process "iTerm2" then
                        return "iTerm2"
                    else
                        return "not running"
                    end if
                end tell
                """]
            
            let checkPipe = Pipe()
            checkIterm.standardOutput = checkPipe
            checkIterm.launch()
            checkIterm.waitUntilExit()
            
            if let output = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
               output.trimmingCharacters(in: .whitespacesAndNewlines) == "iTerm2" {
                // iTerm2 is running, assume it's the host for tmux
                debugLog("   ✅ iTerm2 is running, assuming it hosts tmux", level: .success)
                return "iTerm2"
            }
        }
        
        // Walk up the process tree until we find a terminal app
        var currentPid = pid
        var depth = 0
        let maxDepth = 10  // Prevent infinite loops
        
        while depth < maxDepth {
            // Get the parent process
            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments = ["-p", String(currentPid), "-o", "ppid="]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            task.launch()
            task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8),
                      let ppid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)),
                      ppid > 0 else {
                    debugLog("   Could not get parent PID for \(currentPid)")
                    break
                }
                
                // Get the parent process command
                let parentTask = Process()
                parentTask.launchPath = "/bin/ps"
                parentTask.arguments = ["-p", String(ppid), "-o", "command="]
                
                let parentPipe = Pipe()
                parentTask.standardOutput = parentPipe
                
                parentTask.launch()
                parentTask.waitUntilExit()
                
                let parentData = parentPipe.fileHandleForReading.readDataToEndOfFile()
                if let parentOutput = String(data: parentData, encoding: .utf8) {
                    let command = parentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    debugLog("   Depth \(depth): PID \(ppid) - \(command)")
                    
                    // Check for terminal apps in the command
                    if command.contains("iTerm") || command.contains("iTermServer") || 
                       command.contains("/Applications/iTerm.app") {
                        debugLog("   ✅ Detected iTerm2", level: .success)
                        return "iTerm2"
                    } else if command.contains("Terminal.app") || 
                              command.contains("/System/Applications/Utilities/Terminal.app") {
                        debugLog("   ✅ Detected Terminal.app", level: .success)
                        return "Terminal"
                    } else if command.contains("tmux") {
                        debugLog("   Found tmux in process tree, checking if iTerm2 is running")
                        // If we hit tmux, check if iTerm2 is running at all
                        if NSWorkspace.shared.runningApplications.contains(where: { 
                            $0.bundleIdentifier == "com.googlecode.iterm2" 
                        }) {
                            debugLog("   ✅ iTerm2 is running, assuming it hosts tmux", level: .success)
                            return "iTerm2"
                        }
                        break
                    }
                }
                
                currentPid = ppid
                depth += 1
        }
        
        debugLog("   ⚠️ Could not detect terminal app", level: .warning)
        return "Unknown"
    }
    
    private func focusITerm2Window(tty: String) {
        debugLog("=== focusITerm2Window called ===")
        debugLog("TTY: \(tty)")
        
        // Normalize TTY - ps gives us "s009" or "ttys009" but tmux uses "/dev/ttys009"
        let ttyNormalized: String
        if tty.hasPrefix("/dev/") {
            ttyNormalized = tty
        } else if tty.hasPrefix("tty") {
            ttyNormalized = "/dev/\(tty)"
        } else {
            ttyNormalized = "/dev/tty\(tty)"
        }
        let ttyShort = ttyNormalized.replacingOccurrences(of: "/dev/tty", with: "")
        
        debugLog("Normalized TTY: \(ttyNormalized), Short: \(ttyShort)")
        
        // First check if this TTY is in a tmux session
        if let tmuxInfo = getTmuxInfo(for: tty) {
            debugLog("Found tmux info: \(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)", level: .success)
            focusITerm2TmuxPane(tmuxInfo: tmuxInfo)
            return
        }
        debugLog("No tmux session found for TTY \(tty)", level: .warning)
        
        // Try the focus operation with retry on failure
        var attempts = 0
        let maxAttempts = 3
        
        while attempts < maxAttempts {
            attempts += 1
            if attempts > 1 {
                Thread.sleep(forTimeInterval: 0.2) // Small delay before retry
            }
        
        let script = """
        on run
            set targetTTY to "\(tty)"
            set targetTTYShort to "\(ttyShort)"
            
            tell application "iTerm2"
                set foundWindow to missing value
                set foundTab to missing value
                set foundSession to missing value
                
                -- Search all windows
                try
                    repeat with w in windows
                        set windowTabs to tabs of w
                        repeat with t in windowTabs
                            set tabSessions to sessions of t
                            repeat with s in tabSessions
                                try
                                    set sessionTTY to tty of s
                                    if sessionTTY contains targetTTY or sessionTTY contains targetTTYShort then
                                        set foundWindow to w
                                        set foundTab to t
                                        set foundSession to s
                                        exit repeat
                                    end if
                                end try
                            end repeat
                            if foundSession is not missing value then exit repeat
                        end repeat
                        if foundSession is not missing value then exit repeat
                    end repeat
                on error errMsg
                    return "Error searching windows: " & errMsg
                end try
                
                if foundSession is not missing value then
                    -- Select the session and tab (but don't set frontmost on window)
                    try
                        tell foundWindow
                            select foundTab
                            tell foundTab
                                select foundSession
                            end tell
                            -- Only set index, not frontmost (avoids -10000 error)
                            set index to 1
                        end tell
                    on error errMsg
                        -- If direct selection fails, try alternative approach
                        try
                            set current window to foundWindow
                            set current tab of foundWindow to foundTab
                        end try
                    end try
                    
                    -- Activate the application (this works without error)
                    activate
                    
                    -- Additional activation using System Events as backup
                    tell application "System Events"
                        set frontmost of process "iTerm2" to true
                    end tell
                    
                    -- Alternative: Try using URL scheme if available
                    try
                        do shell script "open 'iterm2://focus'"
                    end try
                    
                    return "Found and focused session with TTY: " & targetTTY
                else
                    return "No session found with TTY: " & targetTTY
                end if
            end tell
        end run
        """
        
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                let result = scriptObject.executeAndReturnError(&error)
                
                if let error = error {
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                    print("AppleScript error: \(errorNumber) - \(error["NSAppleScriptErrorMessage"] ?? "Unknown")")
                    
                    // -10000 is "AppleEvent handler failed" - this should be fixed now
                    // but if we still get it, use fallback instead of retry
                    if errorNumber == -10000 {
                        print("Got -10000 error, using fallback activation")
                        // Use shell command as fallback
                        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "iTerm2"])
                        return
                    }
                } else {
                    print("Successfully focused iTerm2 window")
                    if let resultString = result.stringValue {
                        print("Result: \(resultString)")
                    }
                    return // Success!
                }
            }
            
            // If we get here and haven't returned, break out of retry loop
            break
        }
    }
    
    private func focusTerminalAppWindow(tty: String) {
        print("\n=== focusTerminalAppWindow called ===")
        print("TTY: \(tty)")
        
        // First check if this TTY is in a tmux session
        if let tmuxInfo = getTmuxInfo(for: tty) {
            print("Found tmux info: \(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)")
            focusTerminalTmuxPane(tmuxInfo: tmuxInfo)
            return
        }
        print("No tmux session found for TTY \(tty)")
        
        let script = """
        tell application "Terminal"
            activate
            
            -- Search through all windows and tabs
            set allWindows to windows
            repeat with w in allWindows
                set allTabs to tabs of w
                repeat with t in allTabs
                    if tty of t contains "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        tell application "System Events" to tell process "Terminal"
                            set frontmost to true
                        end tell
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            
        }
    }
    
    private func focusWindowByPID(_ pid: Int32) {
        // Generic approach: bring the app with this PID to front
        // This will switch Spaces automatically
        let script = """
        tell application "System Events"
            set targetProcess to first process whose unix id is \(pid)
            set frontmost of targetProcess to true
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            
            if error != nil {
                // Try activating parent process
                activateParentProcess(of: pid)
            }
        }
    }
    
    private func activateParentProcess(of pid: Int32) {
        // Get parent PID and try to activate that
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "ppid="]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        task.launch()
        task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let ppid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                
                let script = """
                tell application "System Events"
                    set targetProcess to first process whose unix id is \(ppid)
                    set frontmost of targetProcess to true
                end tell
                """
                
                var error: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    scriptObject.executeAndReturnError(&error)
                }
            }
    }
    
    func moveSession(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        // Update the order tracking
        sessionOrder = sessions.map { $0.processID }
        onSessionsChanged?()
    }
    
    func refreshTokenData(for session: Session) {
        // Use the transcript path from hooks if available, otherwise fall back to old method
        let transcriptPath = pidToTranscriptPath[session.processID] ?? pidToJsonlPath[session.processID]
        guard let jsonlPath = transcriptPath else { 
            print("No transcript path found for PID \(session.processID)")
            return 
        }
        
        // Set refreshing state
        DispatchQueue.main.async { [weak self] in
            if let index = self?.sessions.firstIndex(where: { $0.processID == session.processID }) {
                self?.sessions[index].isRefreshingTokens = true
                self?.onSessionsChanged?()
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let (inputTokens, outputTokens, _) = self.fileParser.parseTokenUsageFromJSONL(filePath: jsonlPath)
            let cost = self.fileParser.calculateCost(inputTokens: inputTokens, outputTokens: outputTokens, forPath: jsonlPath)
            
            DispatchQueue.main.async {
                if let index = self.sessions.firstIndex(where: { $0.processID == session.processID }) {
                    self.sessions[index].inputTokens = inputTokens
                    self.sessions[index].outputTokens = outputTokens
                    self.sessions[index].costUSD = cost
                    self.sessions[index].tokensLastRefreshed = Date()
                    self.sessions[index].isRefreshingTokens = false
                    self.onSessionsChanged?()
                }
            }
        }
    }
    
    // MARK: - Hook Handlers
    
    private func handlePreToolUse(_ hookData: HookData) {
        debugLog("🔧 Processing PreToolUse hook:", level: .info)
        debugLog("   Tool: \(hookData.toolName)")
        debugLog("   Session ID: \(hookData.sessionId)")
        debugLog("   Transcript: \(hookData.transcriptPath)")
        
        // Extract and normalize working directory from transcript
        if let workingDir = fileParser.getWorkingDirectory(from: hookData.transcriptPath) {
            let normalizedPath = normalizeWorkingDirectory(workingDir)
            workingDirectoryToHookSession[normalizedPath] = hookData.sessionId
            debugLog("   Working Dir: \(normalizedPath)")
        }
        
        // Find or create session for this hook session ID
        let pid = findOrCreateSession(for: hookData.sessionId, transcriptPath: hookData.transcriptPath)
        
        // Don't process if no matching process found
        guard pid != -1 else { 
            debugLog("   ⚠️ No matching process found for hook session", level: .warning)
            return 
        }
        
        debugLog("   Matched to PID: \(pid)", level: .success)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.sessions.firstIndex(where: { $0.processID == pid }) {
                self.sessions[index].isWorking = true
                self.sessions[index].hasOutput = false
                self.sessions[index].currentTool = hookData.toolName
                self.sessions[index].currentToolDetails = self.extractToolDetails(hookData.toolDetails)
                self.sessions[index].lastHookTimestamp = Date()
                self.sessions[index].hookSessionId = hookData.sessionId
                
                // Store the transcript path for this PID
                self.pidToTranscriptPath[pid] = hookData.transcriptPath
                
                // Extract task description from transcript if we don't have it yet or refresh it
                let newTaskDescription = self.transcriptReader.getTaskDescription(
                    from: hookData.transcriptPath,
                    sessionId: hookData.sessionId
                )
                if let newDescription = newTaskDescription {
                    self.sessions[index].taskDescription = newDescription
                    print("Hook: Set task description for PID \(pid): \(newDescription)")
                }
                
                self.onSessionsChanged?()
            }
        }
    }
    
    private func handlePostToolUse(_ hookData: HookData) {
        guard let pid = hookSessionToPID[hookData.sessionId] else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.sessions.firstIndex(where: { $0.processID == pid }) {
                // Keep working state true - only Stop hook marks it false
                self.sessions[index].lastHookTimestamp = Date()
                self.onSessionsChanged?()
            }
        }
    }
    
    private func handleStop(_ hookData: HookData) {
        guard let pid = hookSessionToPID[hookData.sessionId] else { return }
        
        // Store the transcript path for this PID
        pidToTranscriptPath[pid] = hookData.transcriptPath
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.sessions.firstIndex(where: { $0.processID == pid }) {
                self.sessions[index].isWorking = false
                self.sessions[index].hasOutput = true
                self.sessions[index].currentTool = nil
                self.sessions[index].currentToolDetails = nil
                self.sessions[index].lastHookTimestamp = Date()
                
                // Extract task description from transcript if we don't have it yet or refresh it
                let newTaskDescription = self.transcriptReader.getTaskDescription(
                    from: hookData.transcriptPath,
                    sessionId: hookData.sessionId
                )
                if let newDescription = newTaskDescription {
                    self.sessions[index].taskDescription = newDescription
                    print("Hook: Set task description for PID \(pid): \(newDescription)")
                }
                
                // Play notification sound
                PreferencesManager.shared.playCurrentSound()
                
                self.onSessionsChanged?()
            }
        }
    }
    
    private func handleNotification(_ hookData: HookData) {
        guard let pid = hookSessionToPID[hookData.sessionId] else { return }
        
        // Store the transcript path for this PID
        pidToTranscriptPath[pid] = hookData.transcriptPath
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.sessions.firstIndex(where: { $0.processID == pid }) {
                self.sessions[index].isWorking = false
                self.sessions[index].hasOutput = true
                self.sessions[index].currentTool = nil
                self.sessions[index].currentToolDetails = nil
                self.sessions[index].lastHookTimestamp = Date()
                
                // Extract task description from transcript if we don't have it yet or refresh it
                let newTaskDescription = self.transcriptReader.getTaskDescription(
                    from: hookData.transcriptPath,
                    sessionId: hookData.sessionId
                )
                if let newDescription = newTaskDescription {
                    self.sessions[index].taskDescription = newDescription
                    print("Hook: Set task description for PID \(pid): \(newDescription)")
                }
                
                // Play notification sound for waiting state
                PreferencesManager.shared.playCurrentSound()
                
                self.onSessionsChanged?()
            }
        }
    }
    
    private func findOrCreateSession(for hookSessionId: String, transcriptPath: String) -> Int32 {
        // Check if we already know this session
        if let pid = hookSessionToPID[hookSessionId] {
            return pid
        }
        
        // Track when we first see this session for timing correlation
        if hookSessionFirstSeen[hookSessionId] == nil {
            hookSessionFirstSeen[hookSessionId] = Date()
        }
        
        // Get available Claude processes
        let claudeProcesses = processDetector.getAllClaudeProcesses()
        let unmappedProcesses = claudeProcesses.filter { process in
            !hookSessionToPID.values.contains(process.pid)
        }
        
        guard !unmappedProcesses.isEmpty else {
            print("Warning: Hook event received for session \(hookSessionId) but no unmapped Claude processes found")
            return -1
        }
        
        // Try multiple mapping methods with confidence scoring
        var mappingCandidates: [SessionMapping] = []
        
        // Method 1: Working Directory Matching (highest confidence)
        if let sessionWorkingDir = fileParser.getWorkingDirectory(from: transcriptPath) {
            let normalizedSessionDir = normalizeWorkingDirectory(sessionWorkingDir)
            
            // First refresh working directory mappings
            updateWorkingDirectoryMappings()
            
            for process in unmappedProcesses {
                if let processWorkingDir = pidToWorkingDirectory[process.pid],
                   processWorkingDir == normalizedSessionDir {
                    mappingCandidates.append(SessionMapping(
                        sessionId: hookSessionId,
                        pid: process.pid,
                        confidence: 0.95,
                        method: .workingDirectoryMatch,
                        timestamp: Date()
                    ))
                    print("Found working directory match: PID \(process.pid) with \(normalizedSessionDir)")
                }
            }
        }
        
        // Method 2: Start Time Correlation (high confidence for recent sessions)
        if let sessionFirstSeen = hookSessionFirstSeen[hookSessionId] {
            for process in unmappedProcesses {
                let timeDifference = abs(sessionFirstSeen.timeIntervalSince(process.startTime))
                if timeDifference < 30.0 { // Within 30 seconds
                    let confidence = max(0.5, 0.9 - (timeDifference / 60.0)) // Decreases with time gap
                    mappingCandidates.append(SessionMapping(
                        sessionId: hookSessionId,
                        pid: process.pid,
                        confidence: confidence,
                        method: .startTimeCorrelation,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        // Method 3: Enhanced Project Name Matching (medium confidence)
        let projectName = fileParser.extractProjectName(from: transcriptPath)
        for process in unmappedProcesses {
            var tempSession = Session(processID: process.pid, commandLine: process.commandLine)
            tempSession.terminalAppName = process.terminalWindow
            
            if let windowTitle = terminalParser.getTerminalWindowTitle(for: tempSession) {
                var cleanTitle = windowTitle.replacingOccurrences(of: " (claude)", with: "")
                cleanTitle = cleanTitle.trimmingCharacters(in: CharacterSet(charactersIn: "✳✶"))
                cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
                
                if cleanTitle.contains("/") {
                    let components = cleanTitle.split(separator: "/")
                    if let lastComponent = components.last {
                        cleanTitle = String(lastComponent)
                    }
                }
                
                // Calculate string similarity confidence
                let confidence = calculateStringSimilarity(projectName, cleanTitle)
                if confidence > 0.3 { // Minimum similarity threshold
                    mappingCandidates.append(SessionMapping(
                        sessionId: hookSessionId,
                        pid: process.pid,
                        confidence: confidence * 0.7, // Scale down confidence
                        method: .projectNameMatch,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        // Select the best mapping candidate
        if let bestMapping = mappingCandidates.max(by: { $0.confidence < $1.confidence }) {
            hookSessionToPID[hookSessionId] = bestMapping.pid
            mappingConfidence[hookSessionId] = bestMapping.confidence
            print("Mapped session \(hookSessionId) to PID \(bestMapping.pid) using \(bestMapping.method) (confidence: \(bestMapping.confidence))")
            return bestMapping.pid
        }
        
        // Fallback: Use first available unmapped process (lowest confidence)
        if let process = unmappedProcesses.first {
            hookSessionToPID[hookSessionId] = process.pid
            mappingConfidence[hookSessionId] = 0.1
            print("Mapped session \(hookSessionId) to PID \(process.pid) using fallback method (confidence: 0.1)")
            return process.pid
        }
        
        return -1
    }
    
    private func calculateStringSimilarity(_ str1: String, _ str2: String) -> Double {
        let s1 = str1.lowercased()
        let s2 = str2.lowercased()
        
        // Check for exact match
        if s1 == s2 { return 1.0 }
        
        // Check for substring matches
        if s1.contains(s2) || s2.contains(s1) { return 0.8 }
        
        // Simple Levenshtein-inspired similarity
        let maxLength = max(s1.count, s2.count)
        guard maxLength > 0 else { return 0.0 }
        
        let commonChars = Set(s1).intersection(Set(s2)).count
        return Double(commonChars) / Double(maxLength)
    }
    
    private func extractToolDetails(_ details: ToolDetails?) -> String? {
        guard let details = details else { return nil }
        
        if let command = details.command {
            return command
        } else if let filePath = details.filePath {
            return filePath
        } else if let pattern = details.pattern {
            return pattern
        }
        
        return nil
    }
    
    private func normalizeWorkingDirectory(_ path: String) -> String {
        // Normalize the path by resolving symlinks and removing trailing slashes
        let url = URL(fileURLWithPath: path)
        let resolved = url.standardizedFileURL.path
        return resolved.hasSuffix("/") && resolved != "/" ? String(resolved.dropLast()) : resolved
    }
    
    private func updateWorkingDirectoryMappings() {
        // Update working directory mappings for all active processes
        for process in processDetector.getAllClaudeProcesses() {
            if let workingDir = process.workingDirectory {
                let normalizedPath = normalizeWorkingDirectory(workingDir)
                pidToWorkingDirectory[process.pid] = normalizedPath
                print("Updated working directory for PID \(process.pid): \(normalizedPath)")
            }
        }
    }
    
    private func performInitialScan() {
        debugLog("🚀 Performing initial session scan...", level: .info)
        
        // Quick synchronous scan on startup to minimize delay
        let claudeProcesses = processDetector.getAllClaudeProcesses()
        debugLog("🔍 Initial scan found \(claudeProcesses.count) Claude process(es)", level: .info)
        
        var initialSessions: [Session] = []
        
        for process in claudeProcesses {
            var session = Session(processID: process.pid, commandLine: process.commandLine)
            session.lastUpdateTime = Date()
            session.terminalAppName = process.terminalWindow
            session.terminalTTY = process.terminalWindow
            session.workingDirectory = process.workingDirectory
            
            // Store TTY for window focusing
            if let tty = process.terminalWindow {
                self.pidToTTY[process.pid] = tty
            }
            
            initialSessions.append(session)
        }
        
        // Update UI immediately
        self.sessions = initialSessions
        self.isInitialLoadComplete = true
        self.onSessionsChanged?()
        
        debugLog("✅ Initial scan complete. Found \(initialSessions.count) session(s)", level: .success)
        for (index, session) in initialSessions.enumerated() {
            let terminalApp = self.detectTerminalApp(for: session.processID)
            let tmuxInfo = session.terminalTTY != nil ? self.getTmuxInfo(for: session.terminalTTY!) : nil
            let tmuxStatus = tmuxInfo != nil ? "in tmux" : "not in tmux"
            debugLog("  [\(index + 1)] PID: \(session.processID), TTY: \(session.terminalTTY ?? "unknown"), Terminal: \(terminalApp), \(tmuxStatus)")
        }
        
        // Then do the detailed scan in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanForClaudeProcesses()
        }
    }
    
    // MARK: - Tmux Support
    
    private struct TmuxInfo {
        let sessionName: String
        let windowIndex: Int
        let paneIndex: Int
        let paneTTY: String
        let hostTTY: String?  // The TTY of the terminal hosting tmux
    }
    
    private func getTmuxInfo(for tty: String) -> TmuxInfo? {
        debugLog("=== getTmuxInfo called ===")
        debugLog("Looking for TTY: \(tty)")
        
        // First check if tmux is running at all
        let checkTask = Process()
        checkTask.launchPath = "/usr/bin/env"
        checkTask.arguments = ["tmux", "list-sessions"]
        
        let checkPipe = Pipe()
        checkTask.standardOutput = checkPipe
        checkTask.standardError = Pipe()
        
        checkTask.launch()
        checkTask.waitUntilExit()
        
        if checkTask.terminationStatus != 0 {
            debugLog("tmux is not running or no sessions found", level: .warning)
            return nil
        }
        
        // Run tmux command to find the pane with this TTY
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["tmux", "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { 
            debugLog("No output from tmux list-panes", level: .error)
            return nil 
        }
            
            debugLog("Tmux panes output:")
            debugLog(output)
            
            // Normalize the TTY we're looking for
            let ttyNormalized: String
            if tty.hasPrefix("/dev/") {
                ttyNormalized = tty
            } else if tty.hasPrefix("tty") {
                ttyNormalized = "/dev/\(tty)"
            } else {
                ttyNormalized = "/dev/tty\(tty)"
            }
            let ttyShort = tty.replacingOccurrences(of: "/dev/tty", with: "")
            
            debugLog("Normalized TTY: \(ttyNormalized), Short: \(ttyShort)")
            
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                debugLog("Checking line: \(line)")
                // Check if line contains either the full path or short version
                if line.contains(ttyNormalized) || line.contains(ttyShort) {
                    debugLog("Found matching line: \(line)", level: .success)
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        let sessionPaneInfo = String(parts[0])
                        let paneTTY = String(parts[1])
                        
                        // Parse session:window.pane format
                        if let colonIndex = sessionPaneInfo.firstIndex(of: ":") {
                            let sessionName = String(sessionPaneInfo[..<colonIndex])
                            let windowPaneInfo = String(sessionPaneInfo[sessionPaneInfo.index(after: colonIndex)...])
                            
                            if let dotIndex = windowPaneInfo.firstIndex(of: ".") {
                                let windowIndexStr = String(windowPaneInfo[..<dotIndex])
                                let paneIndexStr = String(windowPaneInfo[windowPaneInfo.index(after: dotIndex)...])
                                
                                if let windowIndex = Int(windowIndexStr),
                                   let paneIndex = Int(paneIndexStr) {
                                    
                                    // Find the host terminal TTY for this tmux session
                                    let hostTTY = findTmuxHostTTY(sessionName: sessionName)
                                    
                                    return TmuxInfo(
                                        sessionName: sessionName,
                                        windowIndex: windowIndex,
                                        paneIndex: paneIndex,
                                        paneTTY: paneTTY,
                                        hostTTY: hostTTY
                                    )
                                }
                            }
                        }
                    }
                }
            }
        
        return nil
    }
    
    private func findTmuxHostTTY(sessionName: String) -> String? {
        // Find the TTY of the terminal that's hosting the tmux session
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["tmux", "list-clients", "-t", sessionName, "-F", "#{client_tty}"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        let ttys = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        return ttys.first
    }
    
    private func focusITerm2TmuxPane(tmuxInfo: TmuxInfo) {
        debugLog("Focusing iTerm2 tmux pane: \(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)")
        debugLog("Host TTY: \(tmuxInfo.hostTTY ?? "unknown")")
        
        // iTerm2 should already be activated by focusTerminalWindow
        // Just switch to the correct tmux window/pane
        
        
        // Step 3: Switch to the correct tmux window and pane
        // Short delay to ensure iTerm2 is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            debugLog("Switching to tmux window/pane: \(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)")
            
            // First check current window/pane
            let checkTask = Process()
            checkTask.launchPath = "/usr/bin/env"
            checkTask.arguments = ["tmux", "display-message", "-p", "#S:#I.#P"]
            
            let checkPipe = Pipe()
            checkTask.standardOutput = checkPipe
            checkTask.launch()
            checkTask.waitUntilExit()
            
            if let output = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                debugLog("Current tmux position: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            
            // First select the window
            let windowTask = Process()
            windowTask.launchPath = "/usr/bin/env"
            windowTask.arguments = [
                "tmux",
                "select-window",
                "-t", "\(tmuxInfo.sessionName):\(tmuxInfo.windowIndex)"
            ]
            
            do {
                try windowTask.run()
                windowTask.waitUntilExit()
                debugLog("Window select exit code: \(windowTask.terminationStatus)")
                
                // Small delay between commands
                Thread.sleep(forTimeInterval: 0.1)
                
                // Then select the pane
                let paneTask = Process()
                paneTask.launchPath = "/usr/bin/env"
                paneTask.arguments = [
                    "tmux",
                    "select-pane",
                    "-t", "\(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)"
                ]
                
                try paneTask.run()
                paneTask.waitUntilExit()
                debugLog("Pane select exit code: \(paneTask.terminationStatus)")
                
                // Final check
                let finalCheckTask = Process()
                finalCheckTask.launchPath = "/usr/bin/env"
                finalCheckTask.arguments = ["tmux", "display-message", "-p", "#S:#I.#P"]
                
                let finalPipe = Pipe()
                finalCheckTask.standardOutput = finalPipe
                finalCheckTask.launch()
                finalCheckTask.waitUntilExit()
                
                if let output = String(data: finalPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    debugLog("Final tmux position: \(output.trimmingCharacters(in: .whitespacesAndNewlines))", level: .success)
                }
                
                debugLog("Tmux commands executed successfully", level: .success)
            } catch {
                debugLog("Failed to select tmux pane: \(error)", level: .error)
            }
        }
    }
    
    private func focusTerminalTmuxPane(tmuxInfo: TmuxInfo) {
        print("Focusing Terminal tmux pane: \(tmuxInfo.sessionName):\(tmuxInfo.windowIndex).\(tmuxInfo.paneIndex)")
        
        // First, focus the Terminal window containing the tmux session
        if let hostTTY = tmuxInfo.hostTTY {
            let focusWindowScript = """
            tell application "Terminal"
                activate
                
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t contains "\(hostTTY)" then
                            set selected of t to true
                            set index of w to 1
                            tell application "System Events" to tell process "Terminal"
                                set frontmost to true
                            end tell
                            exit repeat
                        end if
                    end repeat
                end repeat
            end tell
            """
            
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: focusWindowScript) {
                scriptObject.executeAndReturnError(&error)
            }
        }
        
    }
    
    
    deinit {
        stopMonitoring()
    }
}