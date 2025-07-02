import Foundation
import Network

class HookServer: ObservableObject {
    static let shared = HookServer()
    
    private var listener: NWListener?
    private let port: UInt16 = 8737
    private let queue = DispatchQueue(label: "com.claudecode.hookserver", attributes: .concurrent)
    
    // Callbacks for hook events
    var onPreToolUse: ((HookData) -> Void)?
    var onPostToolUse: ((HookData) -> Void)?
    var onStop: ((HookData) -> Void)?
    var onNotification: ((HookData) -> Void)?
    
    init() {}
    
    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        let port = NWEndpoint.Port(integerLiteral: self.port)
        
        listener = try? NWListener(using: parameters, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: queue)
        print("Hook server started on port \(self.port)")
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        print("Hook server stopped")
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.processRequest(data: data, connection: connection)
            }
            
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else { return }
        
        // Parse HTTP request
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2 else { return }
        
        let method = components[0]
        let path = components[1]
        
        // Only process POST requests
        guard method == "POST" else {
            sendResponse(connection: connection, statusCode: 405, body: "Method Not Allowed")
            return
        }
        
        // Extract body (JSON payload)
        if let bodyStart = request.range(of: "\r\n\r\n") {
            let bodyData = data.advanced(by: bodyStart.upperBound.utf16Offset(in: request))
            
            do {
                let hookData = try JSONDecoder().decode(HookData.self, from: bodyData)
                
                // Dispatch to appropriate handler based on path
                DispatchQueue.main.async { [weak self] in
                    switch path {
                    case "/hook/pretooluse":
                        self?.onPreToolUse?(hookData)
                    case "/hook/posttooluse":
                        self?.onPostToolUse?(hookData)
                    case "/hook/stop":
                        self?.onStop?(hookData)
                    case "/hook/notification":
                        self?.onNotification?(hookData)
                    default:
                        break
                    }
                }
                
                // Send success response
                sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"ok\"}")
                
            } catch {
                print("Failed to parse hook data: \(error)")
                sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            }
        }
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let statusText = statusCode == 200 ? "OK" : statusCode == 400 ? "Bad Request" : "Method Not Allowed"
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        \(body)
        """
        
        let data = response.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// Hook data models
struct HookData: Codable {
    let sessionId: String
    let transcriptPath: String
    let toolName: String?
    let toolDetails: ToolDetails?
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolDetails = "tool_details"
    }
}

struct ToolDetails: Codable {
    // Common fields
    let command: String?
    let filePath: String?
    let pattern: String?
    
    // Tool-specific fields
    let oldString: String?
    let newString: String?
    let content: String?
    let limit: Int?
    let offset: Int?
    
    enum CodingKeys: String, CodingKey {
        case command
        case filePath = "file_path"
        case pattern
        case oldString = "old_string"
        case newString = "new_string"
        case content
        case limit
        case offset
    }
}