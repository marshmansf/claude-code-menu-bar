import Foundation
import AppKit

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
        // Start the hook server
        hookServer.start()
        
        // Set up hook callbacks
        hookServer.onPreToolUse = { [weak self] hookData in
            self?.handlePreToolUse(hookData)
        }
        
        hookServer.onPostToolUse = { [weak self] hookData in
            self?.handlePostToolUse(hookData)
        }
        
        hookServer.onStop = { [weak self] hookData in
            self?.handleStop(hookData)
        }
        
        hookServer.onNotification = { [weak self] hookData in
            self?.handleNotification(hookData)
        }
        
        // Perform initial scan immediately to reduce startup delay
        performInitialScan()
        
        // Periodically rescan to clean up any orphaned sessions
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
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
                    // Created new session
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
                _ = scriptObject.executeAndReturnError(&error)
                
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
        // Extract and normalize working directory from transcript
        if let workingDir = fileParser.getWorkingDirectory(from: hookData.transcriptPath) {
            let normalizedPath = normalizeWorkingDirectory(workingDir)
            workingDirectoryToHookSession[normalizedPath] = hookData.sessionId
            print("Mapped working directory \(normalizedPath) to hook session \(hookData.sessionId)")
        }
        
        // Find or create session for this hook session ID
        let pid = findOrCreateSession(for: hookData.sessionId, transcriptPath: hookData.transcriptPath)
        
        // Don't process if no matching process found
        guard pid != -1 else { return }
        
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
        // Quick synchronous scan on startup to minimize delay
        let claudeProcesses = processDetector.getAllClaudeProcesses()
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
        
        // Then do the detailed scan in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanForClaudeProcesses()
        }
    }
    
    deinit {
        stopMonitoring()
    }
}