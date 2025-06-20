import Foundation

struct TokenUsage: Codable {
    let inputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let outputTokens: Int
    let serviceTier: String?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case serviceTier = "service_tier"
    }
    
    var totalInputTokens: Int {
        inputTokens + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }
}

struct SessionFile: Codable {
    let sessionID: String
    let startTime: TimeInterval
    let lastUpdate: TimeInterval
}

struct ClaudeMessage: Codable {
    let id: String?
    let type: String
    let content: String?
    let usage: TokenUsage?
    let timestamp: String?
    
    enum CodingKeys: String, CodingKey {
        case id, type, content, usage, timestamp
    }
}

class ClaudeFileParser {
    static let shared = ClaudeFileParser()
    
    private let fileManager = FileManager.default
    private let claudeDirectory = NSHomeDirectory() + "/.claude"
    
    // Model pricing per million tokens
    private let modelPricing: [String: (input: Double, output: Double, cacheWrite: Double, cacheRead: Double)] = [
        "claude-3-5-sonnet": (input: 0.000003, output: 0.000015, cacheWrite: 0.00000375, cacheRead: 0.0000003),     // $3/$15/$3.75/$0.30 per million
        "claude-3-opus": (input: 0.000015, output: 0.000075, cacheWrite: 0.00001875, cacheRead: 0.0000015),         // $15/$75/$18.75/$1.50 per million
        "claude-opus-4": (input: 0.000015, output: 0.000075, cacheWrite: 0.00001875, cacheRead: 0.0000015),         // $15/$75/$18.75/$1.50 per million (Opus 4)
        "claude-3-haiku": (input: 0.00000025, output: 0.00000125, cacheWrite: 0.0000003, cacheRead: 0.000000025)    // $0.25/$1.25/$0.30/$0.025 per million
    ]
    
    // Default to Sonnet pricing if model not detected
    private let defaultInputPrice = 0.000003
    private let defaultOutputPrice = 0.000015
    
    func findActiveSessionFiles() -> [SessionFile] {
        var sessions: [SessionFile] = []
        
        let statsigPath = claudeDirectory + "/statsig"
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: statsigPath)
            
            for file in files {
                if file.hasPrefix("statsig.session_id.") {
                    let filePath = statsigPath + "/" + file
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                       let session = try? JSONDecoder().decode(SessionFile.self, from: data) {
                        sessions.append(session)
                    }
                }
            }
        } catch {
        }
        
        return sessions
    }
    
    func findProjectJSONLFiles(modifiedSince: Date? = nil) -> [(path: String, sessionId: String)] {
        var jsonlFiles: [(path: String, sessionId: String)] = []
        let projectsPath = claudeDirectory + "/projects"
        
        func searchDirectory(at path: String) {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: path)
                
                for item in contents {
                    let itemPath = path + "/" + item
                    var isDirectory: ObjCBool = false
                    
                    if fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory) {
                        if isDirectory.boolValue {
                            searchDirectory(at: itemPath)
                        } else if item.hasSuffix(".jsonl") {
                            // Extract session ID from filename (UUID format)
                            let sessionId = item.replacingOccurrences(of: ".jsonl", with: "")
                            
                            if let modifiedSince = modifiedSince {
                                if let attributes = try? fileManager.attributesOfItem(atPath: itemPath),
                                   let modificationDate = attributes[.modificationDate] as? Date,
                                   modificationDate > modifiedSince {
                                    jsonlFiles.append((path: itemPath, sessionId: sessionId))
                                }
                            } else {
                                jsonlFiles.append((path: itemPath, sessionId: sessionId))
                            }
                        }
                    }
                }
            } catch {
            }
        }
        
        searchDirectory(at: projectsPath)
        return jsonlFiles
    }
    
    func parseTokenUsageFromJSONL(filePath: String) -> (totalInputTokens: Int, totalOutputTokens: Int, lastActivity: Date?) {
        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var lastActivity: Date?
        var detectedModel: String?
        
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                guard !line.isEmpty else { continue }
                
                // Try to parse as JSON to extract usage data
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    // Look for message.usage structure
                    if let message = json["message"] as? [String: Any] {
                        // Extract model if present
                        if let model = message["model"] as? String, detectedModel == nil {
                            detectedModel = model
                        }
                        
                        if let usage = message["usage"] as? [String: Any] {
                            // Only count regular input tokens (not cache tokens)
                            if let inputTokens = usage["input_tokens"] as? Int {
                                totalInput += inputTokens
                            }
                            
                            // Add output tokens
                            if let outputTokens = usage["output_tokens"] as? Int {
                                totalOutput += outputTokens
                            }
                            
                            // Note: cache_creation_input_tokens and cache_read_input_tokens
                            // are intentionally not included in the totals to match ccusage behavior
                        }
                    }
                    
                    // Track timestamp
                    if let timestamp = json["timestamp"] as? String {
                        let formatter = ISO8601DateFormatter()
                        if let date = formatter.date(from: timestamp) {
                            if lastActivity == nil || date > lastActivity! {
                                lastActivity = date
                            }
                        }
                    }
                }
            }
        } catch {
        }
        
        // Store detected model in UserDefaults for the file path
        if let model = detectedModel {
            UserDefaults.standard.set(model, forKey: "model_\(filePath)")
        }
        
        return (totalInput, totalOutput, lastActivity)
    }
    
    func calculateCost(inputTokens: Int, outputTokens: Int, forPath: String? = nil) -> Double {
        var inputPrice = defaultInputPrice
        var outputPrice = defaultOutputPrice
        
        // Try to get model from stored value if path is provided
        if let path = forPath,
           let model = UserDefaults.standard.string(forKey: "model_\(path)") {
            // Find pricing for this model
            for (modelPrefix, pricing) in modelPricing {
                if model.contains(modelPrefix) {
                    inputPrice = pricing.input
                    outputPrice = pricing.output
                    break
                }
            }
        }
        
        return (Double(inputTokens) * inputPrice) + (Double(outputTokens) * outputPrice)
    }
    
    func isSessionActive(sessionId: String, within seconds: TimeInterval = 60) -> Bool {
        // Check if the session's JSONL file was recently modified
        let jsonlFiles = findProjectJSONLFiles()
        
        for (path, sid) in jsonlFiles {
            if sid == sessionId {
                if let attributes = try? fileManager.attributesOfItem(atPath: path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    return Date().timeIntervalSince(modificationDate) < seconds
                }
            }
        }
        
        return false
    }
    
    func extractProjectName(from path: String) -> String {
        // Extract project name from path like:
        // /Users/marshman/.claude/projects/-Users-marshman-dev-tools-claude-code-menu-bar/
        let components = path.components(separatedBy: "/")
        
        // Find the projects directory component
        if let projectsIndex = components.firstIndex(of: "projects"),
           projectsIndex + 1 < components.count {
            let projectDir = components[projectsIndex + 1]
            
            // Convert -Users-marshman-dev-tools-project-name to just project-name
            let parts = projectDir.components(separatedBy: "-")
            
            // Skip the user path parts and get the actual project name
            if parts.count > 4 {
                // Join the remaining parts (after -Users-username-dev-)
                let projectParts = parts.dropFirst(4)
                return projectParts.joined(separator: "-")
            }
        }
        
        // Fallback: just return the filename without extension
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
    
    func getSessionInfo(from jsonlPath: String) -> (sessionId: String?, workingDir: String?) {
        // Read first few lines to get session metadata
        do {
            let content = try String(contentsOfFile: jsonlPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines).prefix(5)
            
            for line in lines {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8) else { continue }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let sessionId = json["sessionId"] as? String
                        let cwd = json["cwd"] as? String
                        if sessionId != nil || cwd != nil {
                            return (sessionId, cwd)
                        }
                    }
                } catch {
                    continue
                }
            }
        } catch {
        }
        
        return (nil, nil)
    }
}