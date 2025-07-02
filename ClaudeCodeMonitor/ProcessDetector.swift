import Foundation
import AppKit

struct ClaudeProcess {
    let pid: Int32
    let startTime: Date
    let terminalWindow: String?
    let commandLine: String
    let cpuUsage: Double
    let memoryUsage: Int64
    let workingDirectory: String?
}

class ProcessDetector {
    static let shared = ProcessDetector()
    private var workingDirectoryCache: [Int32: String] = [:]
    private var cacheTimestamp: Date?
    
    func getAllClaudeProcesses() -> [ClaudeProcess] {
        var processes: [ClaudeProcess] = []
        
        // Clear cache if it's older than 5 seconds
        if let timestamp = cacheTimestamp, Date().timeIntervalSince(timestamp) > 5 {
            workingDirectoryCache.removeAll()
            cacheTimestamp = nil
        }
        
        // Try a simpler approach first
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["ax", "-o", "pid,user,tty,stat,start,command"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            
            let outputHandle = pipe.fileHandleForReading
            task.launch()
            
            // Read data before waiting for exit
            let data = outputHandle.readDataToEndOfFile()
            task.waitUntilExit()
            
            guard let output = String(data: data, encoding: .utf8) else {
                return processes
            }
            
            let lines = output.components(separatedBy: "\n")
            
            var claudeLines = 0
                
                for (index, line) in lines.enumerated() {
                    // Skip header line
                    if index == 0 && line.contains("PID") {
                        continue
                    }
                    
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.isEmpty {
                        continue
                    }
                    
                    // Look for lines ending with "claude"
                    if trimmedLine.hasSuffix("claude") && 
                       !line.contains("grep") && 
                       !line.contains("ClaudeCodeMonitor") &&
                       !line.contains("/Applications/Claude.app") {
                        
                        
                        // Parse the line with new format: PID USER TTY STAT START COMMAND
                        let components = line.split(separator: " ", omittingEmptySubsequences: true)
                        if components.count >= 6 {
                            if let pid = Int32(String(components[0])) {
                                let tty = String(components[2])
                                let startTimeStr = String(components[4])
                                
                                // Check if it has a terminal (not ??)
                                if tty != "??" && (tty.hasPrefix("s") || tty.hasPrefix("ttys")) {
                                    claudeLines += 1
                                    
                                    // Parse start time (format could be like "9:23AM" or "Dec19")
                                    let startTime = parseProcessStartTime(startTimeStr)
                                    
                                    // Get working directory for this process (using cache)
                                    let workingDir = getCachedWorkingDirectory(for: pid)
                                    
                                    // Create ClaudeProcess manually since we have different format
                                    let process = ClaudeProcess(
                                        pid: pid,
                                        startTime: startTime,
                                        terminalWindow: tty,
                                        commandLine: "claude",
                                        cpuUsage: 0.0,
                                        memoryUsage: 0,
                                        workingDirectory: workingDir
                                    )
                                    processes.append(process)
                                }
                            }
                        }
                    }
                }
        } catch {
        }
        
        return processes
    }
    
    private func parseProcessLine(_ line: String) -> ClaudeProcess? {
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        
        if components.count < 11 {
            return nil
        }
        
        guard let pid = Int32(components[1]) else {
            return nil
        }
        
        // Parse CPU usage (column 3)
        let cpuUsage = Double(components[2]) ?? 0.0
        
        // Parse memory usage in KB (column 5)
        let memoryKB = Int64(components[5]) ?? 0
        
        // Command line starts from column 10 onwards
        let commandLine = components.dropFirst(10).joined(separator: " ")
        
        // Try to determine terminal window (this is simplified)
        let terminalWindow = getTerminalWindowForPID(pid)
        
        // For now, use current time as start time (we'd need more complex parsing for actual start time)
        let startTime = Date()
        
        // Get working directory for this process (using cache)
        let workingDirectory = getCachedWorkingDirectory(for: pid)
        
        return ClaudeProcess(
            pid: pid,
            startTime: startTime,
            terminalWindow: terminalWindow,
            commandLine: commandLine,
            cpuUsage: cpuUsage,
            memoryUsage: memoryKB * 1024, // Convert to bytes
            workingDirectory: workingDirectory
        )
    }
    
    func getTerminalWindowForPID(_ pid: Int32) -> String? {
        // Use lsof to find the terminal associated with the process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-a", "-d", "0"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse terminal info from lsof output
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    if line.contains("/dev/ttys") {
                        let components = line.split(separator: " ", omittingEmptySubsequences: true)
                        if components.count > 8 {
                            return String(components[8])
                        }
                    }
                }
            }
        } catch {
            // Silent fail - terminal detection is optional
        }
        
        return nil
    }
    
    private func getCachedWorkingDirectory(for pid: Int32) -> String? {
        // Check cache first
        if let cached = workingDirectoryCache[pid] {
            return cached
        }
        
        // Get fresh value
        if let workingDir = getWorkingDirectory(for: pid) {
            workingDirectoryCache[pid] = workingDir
            if cacheTimestamp == nil {
                cacheTimestamp = Date()
            }
            return workingDir
        }
        
        return nil
    }
    
    func getWorkingDirectory(for pid: Int32) -> String? {
        // Use lsof to get the current working directory of the process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-a", "-d", "cwd", "-F", "n"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // lsof -F n output format: lines starting with 'n' contain the name/path
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    if line.hasPrefix("n") && line.count > 1 {
                        let path = String(line.dropFirst()) // Remove the 'n' prefix
                        if path != "/" && !path.isEmpty { // Skip root and empty paths
                            return path
                        }
                    }
                }
            }
        } catch {
            // Silent fail - working directory detection is optional
        }
        
        return nil
    }
    
    func isProcessActive(_ pid: Int32) -> Bool {
        // Check if process is actively using CPU (not just idle)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "state="]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let state = output.trimmingCharacters(in: .whitespacesAndNewlines)
                // R = Running, S = Sleeping but interruptible
                // If the process has '+' it means it's in the foreground
                return state.contains("R") || state.contains("+")
            }
        } catch {
            return false
        }
        
        return false
    }
    
    private func parseProcessStartTime(_ timeStr: String) -> Date {
        // Handle different ps time formats
        // Examples: "9:23AM", "10:45PM", "Dec19", "2:34"
        
        let now = Date()
        let calendar = Calendar.current
        
        // Check if it's a time today (contains AM/PM or just time)
        if timeStr.contains("AM") || timeStr.contains("PM") || timeStr.contains(":") {
            // Parse time like "9:23AM" or "14:34"
            let formatter = DateFormatter()
            formatter.dateFormat = timeStr.contains("M") ? "h:mma" : "HH:mm"
            
            if let time = formatter.date(from: timeStr.uppercased()) {
                // Combine with today's date
                let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
                if let todayWithTime = calendar.date(bySettingHour: timeComponents.hour ?? 0,
                                                     minute: timeComponents.minute ?? 0,
                                                     second: 0,
                                                     of: now) {
                    return todayWithTime
                }
            }
        }
        
        // For date formats like "Dec19", just return current time
        // as we'd need more complex parsing for these
        return now
    }
}