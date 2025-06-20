import Foundation
import AppKit

class SessionMonitor: ObservableObject {
    @Published var sessions: [Session] = []
    var onSessionsChanged: (() -> Void)?
    private var sessionOrder: [Int32] = []  // Track PID order
    
    private var timer: Timer?
    private let updateInterval: TimeInterval = 2.0
    private let fileParser = ClaudeFileParser.shared
    private let processDetector = ProcessDetector.shared
    private let terminalParser = TerminalContentParser.shared
    private var lastTokenCounts: [Int32: (input: Int, output: Int)] = [:]
    private var updateCount = 0
    
    // Track state changes to prevent false positives
    private var stateChangeTracking: [Int32: (wasWorking: Bool, notWorkingCount: Int)] = [:]
    
    // Persistent mapping of PID to JSONL file path to prevent reassignments
    private var pidToJsonlPath: [Int32: String] = [:]
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateSessions()
        }
        // Run first update after a short delay to avoid startup issues
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateSessions()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateSessions() {
        // Run process scanning on background queue to avoid blocking UI
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            
            // Get running Claude processes
            let claudeProcesses = self.processDetector.getAllClaudeProcesses()
            
            // Get active session files
            let sessionFiles = self.fileParser.findActiveSessionFiles()
            
            // Get ALL JSONL files and sort by modification time
            let allJsonlFiles = self.fileParser.findProjectJSONLFiles()
            
            // Sort by modification date (most recent first)
            let sortedJsonlFiles = allJsonlFiles.sorted { (first, second) in
                let firstMod = (try? FileManager.default.attributesOfItem(atPath: first.path))?[.modificationDate] as? Date ?? Date.distantPast
                let secondMod = (try? FileManager.default.attributesOfItem(atPath: second.path))?[.modificationDate] as? Date ?? Date.distantPast
                return firstMod > secondMod
            }
            
            
            var updatedSessions: [Session] = []
            var usedJsonlPaths = Set<String>()
            
            // Sort processes by PID to ensure consistent assignment
            let sortedProcesses = claudeProcesses.sorted { $0.pid < $1.pid }
            
            for (index, process) in sortedProcesses.enumerated() {
                // Always create a fresh session to avoid stale data
                var session = Session(processID: process.pid, commandLine: process.commandLine)
                
                // Copy over persistent data from existing session if it exists
                if let existingSession = self.sessions.first(where: { $0.processID == process.pid }) {
                    session.sessionId = existingSession.sessionId
                    session.projectName = existingSession.projectName
                    session.workingDirectory = existingSession.workingDirectory
                }
                
                session.lastUpdateTime = Date()
                session.terminalAppName = process.terminalWindow
                
                // Get terminal window title
                if let windowTitle = self.terminalParser.getTerminalWindowTitle(for: session) {
                    
                    // Extract project name from window title
                    // Remove "(claude)" suffix if present
                    var cleanTitle = windowTitle.replacingOccurrences(of: " (claude)", with: "")
                    
                    // Remove any leading emoji/symbols
                    cleanTitle = cleanTitle.trimmingCharacters(in: CharacterSet(charactersIn: "✳✶"))
                    cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
                    
                    // If it contains a path, extract the last component
                    if cleanTitle.contains("/") {
                        let components = cleanTitle.split(separator: "/")
                        if let lastComponent = components.last {
                            session.projectName = String(lastComponent)
                        }
                    } else {
                        session.projectName = cleanTitle
                    }
                }
                
                // Update terminal content data (working state, context percentage)
                self.terminalParser.updateSessionWithTerminalContent(&session)
                
                // Track state changes to prevent false positives
                let pid = process.pid
                if let tracking = self.stateChangeTracking[pid] {
                    if tracking.wasWorking && !session.isWorking {
                        // Session stopped working, increment counter
                        self.stateChangeTracking[pid] = (wasWorking: tracking.wasWorking, notWorkingCount: tracking.notWorkingCount + 1)
                        
                        // Only play sound after 2 consecutive "not working" states
                        if tracking.notWorkingCount >= 1 { // This will be the 2nd time
                            DispatchQueue.main.async {
                                PreferencesManager.shared.playCurrentSound()
                            }
                            // Reset tracking after playing sound
                            self.stateChangeTracking[pid] = (wasWorking: false, notWorkingCount: 0)
                        }
                    } else if session.isWorking {
                        // Session is working, reset tracking
                        self.stateChangeTracking[pid] = (wasWorking: true, notWorkingCount: 0)
                    }
                } else {
                    // First time seeing this session
                    self.stateChangeTracking[pid] = (wasWorking: session.isWorking, notWorkingCount: 0)
                }
                
                // Try to find associated JSONL file for this session
                var foundTokenData = false
                var bestMatch: (path: String, sessionId: String)?
                
                // Check if we already have a persistent mapping for this PID
                if let existingPath = self.pidToJsonlPath[process.pid],
                   sortedJsonlFiles.contains(where: { $0.path == existingPath }) {
                    // Use the existing mapping
                    bestMatch = sortedJsonlFiles.first(where: { $0.path == existingPath })
                    usedJsonlPaths.insert(existingPath)
                }
                
                // Try to find JSONL file based on project name match if no existing mapping
                if bestMatch == nil, let projectName = session.projectName, !projectName.isEmpty {
                    // Clean up the project name for better matching
                    let cleanProjectName = projectName
                        .replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: " ", with: "-")
                        .lowercased()
                    
                    // First, try exact match based on project name in path
                    for (jsonlPath, sessionId) in sortedJsonlFiles {
                        if !usedJsonlPaths.contains(jsonlPath) {
                            let lowerPath = jsonlPath.lowercased()
                            if lowerPath.contains(cleanProjectName) ||
                               lowerPath.contains(projectName.lowercased()) {
                                bestMatch = (path: jsonlPath, sessionId: sessionId)
                                usedJsonlPaths.insert(jsonlPath)
                                break
                            }
                        }
                    }
                    
                    // If no exact match, try fuzzy match with individual words
                    if bestMatch == nil {
                        let projectWords = projectName.split(separator: " ").map { $0.lowercased() }
                        for (jsonlPath, sessionId) in sortedJsonlFiles {
                            if !usedJsonlPaths.contains(jsonlPath) {
                                let jsonlProjectName = self.fileParser.extractProjectName(from: jsonlPath).lowercased()
                                
                                // Check if any significant words match
                                let matchCount = projectWords.filter { word in
                                    word.count > 2 && jsonlProjectName.contains(word)
                                }.count
                                
                                if matchCount > 0 {
                                    bestMatch = (path: jsonlPath, sessionId: sessionId)
                                    usedJsonlPaths.insert(jsonlPath)
                                    break
                                }
                            }
                        }
                    }
                }
                
                // If still no match, fall back to time-based matching
                if bestMatch == nil {
                    for (jsonlPath, sessionId) in sortedJsonlFiles {
                        if !usedJsonlPaths.contains(jsonlPath) {
                            bestMatch = (path: jsonlPath, sessionId: sessionId)
                            usedJsonlPaths.insert(jsonlPath)
                            break
                        }
                    }
                }
                
                if let match = bestMatch {
                    // Only parse session info (not token data) for performance
                    let (sessionId, workingDir) = self.fileParser.getSessionInfo(from: match.path)
                    session.sessionId = sessionId
                    session.workingDirectory = workingDir
                    
                    // Store the mapping persistently
                    self.pidToJsonlPath[process.pid] = match.path
                    
                    // Keep existing token data if we have it
                    if let existingSession = self.sessions.first(where: { $0.processID == process.pid }) {
                        session.inputTokens = existingSession.inputTokens
                        session.outputTokens = existingSession.outputTokens
                        session.costUSD = existingSession.costUSD
                        session.tokensLastRefreshed = existingSession.tokensLastRefreshed
                        session.isRefreshingTokens = existingSession.isRefreshingTokens
                    }
                    
                    foundTokenData = true
                }
                
                // If we didn't find token data, keep previous values
                if !foundTokenData && self.sessions.contains(where: { $0.processID == process.pid }) {
                    if let existingSession = self.sessions.first(where: { $0.processID == process.pid }) {
                        session.inputTokens = existingSession.inputTokens
                        session.outputTokens = existingSession.outputTokens
                        session.costUSD = existingSession.costUSD
                        session.compactionPercentage = existingSession.compactionPercentage
                        session.projectName = existingSession.projectName
                        session.sessionId = existingSession.sessionId
                        session.workingDirectory = existingSession.workingDirectory
                    }
                }
                
                updatedSessions.append(session)
            }
            
            // Apply custom ordering if available, otherwise sort by PID
            if !self.sessionOrder.isEmpty {
                updatedSessions.sort { session1, session2 in
                    let index1 = self.sessionOrder.firstIndex(of: session1.processID) ?? Int.max
                    let index2 = self.sessionOrder.firstIndex(of: session2.processID) ?? Int.max
                    return index1 < index2
                }
            } else {
                // Default: sort by PID
                updatedSessions.sort { $0.processID < $1.processID }
            }
            
            // Update session order to include any new sessions
            let currentPIDs = Set(updatedSessions.map { $0.processID })
            let orderedPIDs = self.sessionOrder.filter { currentPIDs.contains($0) }
            let newPIDs = currentPIDs.subtracting(Set(orderedPIDs))
            self.sessionOrder = orderedPIDs + newPIDs.sorted()
            
            // Clean up tracking for sessions that no longer exist
            let deadPIDs = Set(self.stateChangeTracking.keys).subtracting(currentPIDs)
            for pid in deadPIDs {
                self.stateChangeTracking.removeValue(forKey: pid)
                self.pidToJsonlPath.removeValue(forKey: pid)
            }
            
            DispatchQueue.main.async {
                self.sessions = updatedSessions
                self.onSessionsChanged?()
                
            }
        }
    }
    
    func focusTerminalWindow(for session: Session) {
        // Clear the waiting flag when focusing
        if let index = sessions.firstIndex(where: { $0.processID == session.processID }) {
            sessions[index].hasOutput = false
            onSessionsChanged?()
        }
        
        // Close the popover first to ensure it doesn't interfere
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.closePopover()
        }
        
        // Add a small delay to ensure popover is closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            // First, detect which terminal app owns this process
            let terminalApp = self.detectTerminalApp(for: session.processID)
            
            // Try to focus the specific terminal window using the terminal device
            if let terminalDevice = session.terminalAppName {
                switch terminalApp {
                case "iTerm2":
                    self.focusITerm2Window(tty: terminalDevice)
                case "Terminal":
                    self.focusTerminalAppWindow(tty: terminalDevice)
                default:
                    // Try generic approach
                    self.focusWindowByPID(session.processID)
                }
            } else {
                // Fallback if we don't have terminal device info
                self.focusWindowByPID(session.processID)
            }
        }
    }
    
    private func detectTerminalApp(for pid: Int32) -> String {
        
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
                    // Check for terminal apps in the command
                    if command.contains("iTerm") || command.contains("iTermServer") {
                        return "iTerm2"
                    } else if command.contains("Terminal.app") || (command == "Terminal" && ppid > 1) {
                        return "Terminal"
                    }
                }
                
                currentPid = ppid
                depth += 1
        }
        
        return "Unknown"
    }
    
    private func focusITerm2Window(tty: String) {
        
        // iTerm2 returns TTY with full path like /dev/ttys011
        // So we need to check both ways
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
        
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
                    -- Select the session, tab, and window
                    try
                        tell foundWindow
                            select foundTab
                            tell foundTab
                                select foundSession
                            end tell
                            set index to 1
                            set frontmost to true
                        end tell
                    on error errMsg
                        -- If direct selection fails, try alternative approach
                        try
                            set current window to foundWindow
                            set current tab of foundWindow to foundTab
                        end try
                    end try
                    
                    -- Use multiple activation methods to ensure space switching
                    activate
                    
                    -- Force space switch using open command
                    do shell script "open -a iTerm2"
                    
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
                    
                    // -10000 is "AppleEvent handler failed" - retry if we get this
                    if errorNumber == -10000 && attempts < maxAttempts {
                        continue // Try again
                    }
                } else {
                    return // Success!
                }
            }
            
            // If we get here and haven't returned, break out of retry loop
            break
        }
    }
    
    private func focusTerminalAppWindow(tty: String) {
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
            
            if let error = error {
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
        guard let jsonlPath = pidToJsonlPath[session.processID] else { return }
        
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
    
    deinit {
        stopMonitoring()
    }
}