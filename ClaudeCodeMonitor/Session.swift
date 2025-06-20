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
    
    // Working state details
    var workingPhrase: String?
    var workingElapsedSeconds: Int?
    var workingCurrentTokens: Int?
    
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
        self.workingPhrase = nil
        self.workingElapsedSeconds = nil
        self.workingCurrentTokens = nil
        self.tokensLastRefreshed = nil
        self.isRefreshingTokens = false
    }
    
    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.processID == rhs.processID
    }
    
    var totalTokens: Int {
        inputTokens + outputTokens
    }
    
    var statusDescription: String {
        if isWorking {
            if let phrase = workingPhrase, let seconds = workingElapsedSeconds {
                return "\(phrase)… (\(seconds)s)"
            }
            return "Working"
        } else if hasOutput {
            return "Waiting"
        } else {
            return "Idle"
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