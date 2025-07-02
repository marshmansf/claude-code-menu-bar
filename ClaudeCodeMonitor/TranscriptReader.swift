import Foundation

class TranscriptReader {
    static let shared = TranscriptReader()
    
    // Use transcript path as cache key instead of session ID to avoid collisions
    private var cachedTasks: [String: String] = [:] // transcriptPath -> task description
    
    func getTaskDescription(from transcriptPath: String, sessionId: String) -> String? {
        // Check cache using transcript path as key
        if let cached = cachedTasks[transcriptPath] {
            print("Returning cached task for path \(transcriptPath): \(cached)")
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
        
        // Parse JSONL lines
        let lines = content.components(separatedBy: .newlines)
        var summaries: [String] = []
        var lastUserMessage: String?
        var firstAssistantResponse: String?
        
        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            // Look for type field
            if let type = json["type"] as? String {
                if type == "summary" {
                    // Found a summary entry - prefer this over user messages
                    if let summary = json["summary"] as? String {
                        summaries.append(summary)
                        print("Found summary: \(summary)")
                    }
                } else if type == "user" {
                    // Fallback: New format user message - keep updating to get the last one
                    if let message = json["message"] as? [String: Any],
                       let role = message["role"] as? String,
                       let content = message["content"] as? String {
                        if role == "user" {
                            lastUserMessage = content
                            print("Found user message: \(content.prefix(100))...")
                        }
                    }
                } else if type == "assistant" && firstAssistantResponse == nil && lastUserMessage != nil {
                    // Assistant response for fallback (just need first one for context)
                    if let message = json["message"] as? [String: Any],
                       let role = message["role"] as? String,
                       let content = message["content"] as? String {
                        if role == "assistant" {
                            firstAssistantResponse = content
                        }
                    }
                } else if type == "conversation" {
                    // Fallback: Old format - keep updating to get the last user message
                    if let message = json["message"] as? [String: Any],
                       let role = message["role"] as? String,
                       let content = message["content"] as? String {
                        if role == "user" {
                            lastUserMessage = content
                            print("Found user message (old format): \(content.prefix(100))...")
                        } else if role == "assistant" && firstAssistantResponse == nil && lastUserMessage != nil {
                            firstAssistantResponse = content
                        }
                    }
                }
            }
        }
        
        // Prefer summaries over user messages
        let taskDescription: String
        if let latestSummary = summaries.last {
            // Use the most recent summary
            taskDescription = latestSummary
            print("Using summary as task description: \(taskDescription)")
        } else if let userMessage = lastUserMessage {
            // Fallback to extracted task summary from last user message
            taskDescription = extractTaskSummary(from: userMessage, assistantResponse: firstAssistantResponse)
            print("Using extracted task from last user message: \(taskDescription)")
        } else {
            print("No summary or user message found in transcript: \(transcriptPath)")
            return nil
        }
        
        // Cache by transcript path, not session ID
        cachedTasks[transcriptPath] = taskDescription
        print("Cached task for \(transcriptPath): \(taskDescription)")
        return taskDescription
    }
    
    private func extractTaskSummary(from userMessage: String, assistantResponse: String?) -> String {
        // Clean and truncate the user message to extract key task
        var summary = userMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to extract key action words or phrases
        let actionPhrases = [
            "help me", "can you", "please", "i need", "i want", "create", "build", "fix", 
            "debug", "implement", "add", "update", "modify", "refactor", "analyze", "explain"
        ]
        
        // Find the most relevant part of the message
        for phrase in actionPhrases {
            if let range = summary.lowercased().range(of: phrase) {
                let startIndex = summary.index(range.lowerBound, offsetBy: 0)
                summary = String(summary[startIndex...])
                break
            }
        }
        
        // Truncate to a reasonable length
        if summary.count > 60 {
            let words = summary.split(separator: " ").prefix(8)
            summary = words.joined(separator: " ") + "..."
        }
        
        // Clean up common prefixes
        summary = summary
            .replacingOccurrences(of: "help me ", with: "")
            .replacingOccurrences(of: "can you ", with: "")
            .replacingOccurrences(of: "please ", with: "")
            .replacingOccurrences(of: "i need to ", with: "")
            .replacingOccurrences(of: "i want to ", with: "")
        
        // Capitalize first letter
        if let firstChar = summary.first {
            summary = String(firstChar).uppercased() + summary.dropFirst()
        }
        
        return summary
    }
    
    func clearCache() {
        cachedTasks.removeAll()
    }
}