import Foundation

struct Session: Identifiable, Equatable {
    let id = UUID()
    let processID: Int32
    let terminalWindowID: String?
    let startTime: Date
    var lastUpdateTime: Date
    var isWorking: Bool
    var hasOutput: Bool
    var compactionPercentage: Double
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    var terminalAppName: String?
    var commandLine: String
    var projectName: String?
    var sessionId: String?
    var workingDirectory: String?
    var tokensLastRefreshed: Date?
    var isRefreshingTokens: Bool
    
    // Hook-based state tracking
    var hookSessionId: String?
    var currentTool: String?
    var currentToolDetails: String?
    var lastHookTimestamp: Date?
    var taskDescription: String? // Extracted from transcript
    
    // Terminal association
    var terminalTTY: String? // Used for window focusing only
    
    init(processID: Int32, commandLine: String) {
        self.processID = processID
        self.commandLine = commandLine
        self.terminalWindowID = nil
        self.startTime = Date()
        self.lastUpdateTime = Date()
        self.isWorking = false
        self.hasOutput = false
        self.compactionPercentage = 0.0
        self.inputTokens = 0
        self.outputTokens = 0
        self.costUSD = 0.0
        self.terminalAppName = nil
        self.projectName = nil
        self.sessionId = nil
        self.workingDirectory = nil
        self.tokensLastRefreshed = nil
        self.isRefreshingTokens = false
        self.hookSessionId = nil
        self.currentTool = nil
        self.currentToolDetails = nil
        self.lastHookTimestamp = nil
        self.taskDescription = nil
        self.terminalTTY = nil
    }
    
    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.processID == rhs.processID
    }
    
    var totalTokens: Int {
        inputTokens + outputTokens
    }
    
    var statusDescription: String {
        if isWorking {
            if let tool = currentTool {
                return toolDisplayName(for: tool)
            }
            return "Working"
        } else if hasOutput {
            return "Waiting"
        } else {
            return "Idle"
        }
    }
    
    func toolDisplayName(for tool: String) -> String {
        switch tool {
        case "Bash":
            return "Running command"
        case "Edit", "MultiEdit":
            return "Editing file"
        case "Write":
            return "Writing file"
        case "Read":
            return "Reading file"
        case "Grep":
            return "Searching files"
        case "Glob":
            return "Finding files"
        case "WebSearch":
            return "Searching web"
        case "WebFetch":
            return "Fetching web"
        case "Task":
            return "Running task"
        case "LS":
            return "Listing files"
        default:
            return tool
        }
    }
    
    func toolIcon(for tool: String) -> String {
        switch tool {
        case "Bash":
            return "🔨"
        case "Edit", "MultiEdit":
            return "📝"
        case "Write":
            return "💾"
        case "Read":
            return "📖"
        case "Grep", "Glob":
            return "🔍"
        case "WebSearch", "WebFetch":
            return "🌐"
        case "Task":
            return "🤖"
        case "LS":
            return "📁"
        default:
            return "⚙️"
        }
    }
    
    var formattedCost: String {
        String(format: "$%.4f", costUSD)
    }
    
    var formattedCompaction: String {
        String(format: "%.0f%%", compactionPercentage)
    }
    
    var timeSinceTokenRefresh: String? {
        guard let refreshDate = tokensLastRefreshed else { return nil }
        
        let elapsed = Date().timeIntervalSince(refreshDate)
        
        if elapsed < 60 {
            return "\(Int(elapsed)) secs ago"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60)) mins ago"
        } else {
            return "\(Int(elapsed / 3600)) hrs ago"
        }
    }
}