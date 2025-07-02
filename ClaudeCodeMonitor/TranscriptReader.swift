import Foundation

class TranscriptReader {
    static let shared = TranscriptReader()
    
    // Use transcript path + session ID as cache key to ensure proper session isolation
    private var cachedTasks: [String: String] = [:] // "transcriptPath|sessionId" -> task description
    
    func getTaskDescription(from transcriptPath: String, sessionId: String) -> String? {
        // Create cache key combining transcript path and session ID
        let cacheKey = "\(transcriptPath)|\(sessionId)"
        
        // Check cache using combined key
        if let cached = cachedTasks[cacheKey] {
            print("Returning cached task for session \(sessionId): \(cached)")
            return cached
        }
        
        print("Reading transcript for session \(sessionId) from: \(transcriptPath)")
        
        // Read the transcript file
        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            print("Failed to open transcript file at: \(transcriptPath)")
            return nil
        }
        
        defer { fileHandle.closeFile() }
        
        // Read content to find summary or first user message
        let maxBytesToRead = 100000 // Read up to 100KB to find summary entries
        let data = fileHandle.readData(ofLength: maxBytesToRead)
        
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Parse JSONL lines to find the most recent user message
        let lines = content.components(separatedBy: .newlines)
        var lastUserMessage: String?
        
        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            // Look for type field
            if let type = json["type"] as? String {
                if type == "user" {
                    // New format user message - keep updating to get the last one
                    if let message = json["message"] as? [String: Any],
                       let role = message["role"] as? String,
                       let content = message["content"] as? String {
                        if role == "user" {
                            lastUserMessage = content
                            print("Found user message: \(content.prefix(100))...")
                        }
                    }
                } else if type == "conversation" {
                    // Old format - keep updating to get the last user message
                    if let message = json["message"] as? [String: Any],
                       let role = message["role"] as? String,
                       let content = message["content"] as? String {
                        if role == "user" {
                            lastUserMessage = content
                            print("Found user message (old format): \(content.prefix(100))...")
                        }
                    }
                }
            }
        }
        
        // Use the most recent user message as the task description
        let taskDescription: String
        if let userMessage = lastUserMessage {
            taskDescription = formatUserPrompt(userMessage)
            print("Using most recent user prompt: \(taskDescription)")
        } else {
            print("No user message found in transcript: \(transcriptPath)")
            return nil
        }
        
        // Cache using combined key to ensure session isolation
        cachedTasks[cacheKey] = taskDescription
        print("Cached task for session \(sessionId): \(taskDescription)")
        return taskDescription
    }
    
    private func formatUserPrompt(_ userMessage: String) -> String {
        // Clean the user message and preserve more of the original text
        var prompt = userMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Truncate to show more characters (increased from ~60 to ~120)
        if prompt.count > 120 {
            let words = prompt.split(separator: " ").prefix(15)
            prompt = words.joined(separator: " ") + "..."
        }
        
        // Capitalize first letter if needed
        if let firstChar = prompt.first, firstChar.isLowercase {
            prompt = String(firstChar).uppercased() + prompt.dropFirst()
        }
        
        return prompt
    }
    
    func clearCache() {
        cachedTasks.removeAll()
    }
    
    func clearCacheForSession(_ sessionId: String) {
        // Remove all cache entries for a specific session
        let keysToRemove = cachedTasks.keys.filter { $0.hasSuffix("|\(sessionId)") }
        for key in keysToRemove {
            cachedTasks.removeValue(forKey: key)
        }
    }
}