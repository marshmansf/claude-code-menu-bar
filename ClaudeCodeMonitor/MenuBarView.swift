import SwiftUI
import AppKit

// MARK: - Extensions

extension DateFormatter {
    static let debugTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Debug Drawer

// MARK: - Debug View

struct DebugView: View {
    @ObservedObject var debugLog: DebugLog
    @State private var autoScroll = true
    @State private var selectedText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.headline)
                
                Spacer()
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                
                Button("Copy All") {
                    copyAllLogs()
                }
                .buttonStyle(.bordered)
                
                Button("Clear") {
                    debugLog.clear()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log content as selectable text
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let allText = debugLog.entries.map { entry in
                            let timeFormatter = DateFormatter()
                            timeFormatter.dateFormat = "h:mm:ss a"
                            let timeString = timeFormatter.string(from: entry.timestamp)
                            return "\(timeString) \(entry.message)"
                        }.joined(separator: "\n")
                        
                        Text(allText)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                            .id("logContent")
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: debugLog.entries.count) { _ in
                    if autoScroll {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("logContent", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private func copyAllLogs() {
        let allText = debugLog.entries.map { entry in
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm:ss a"
            let timeString = timeFormatter.string(from: entry.timestamp)
            return "\(timeString) \(entry.message)"
        }.joined(separator: "\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }
}

struct SessionDropDelegate: DropDelegate {
    let sessions: [Session]
    let currentIndex: Int
    let sessionMonitor: SessionMonitor
    
    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [.plainText]).first else { return false }
        
        itemProvider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { (data, error) in
            guard let data = data as? Data,
                  let string = String(data: data, encoding: .utf8),
                  let sourceIndex = Int(string) else { return }
            
            guard sourceIndex != currentIndex else { return }
            
            DispatchQueue.main.async {
                let sourceIndexSet = IndexSet(integer: sourceIndex)
                let destinationIndex = currentIndex > sourceIndex ? currentIndex + 1 : currentIndex
                sessionMonitor.moveSession(from: sourceIndexSet, to: destinationIndex)
            }
        }
        
        return true
    }
}

struct MenuBarView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var preferencesManager = PreferencesManager.shared
    @ObservedObject var debugLog = DebugLog.shared
    @State private var showingPreferences = false
    @State private var showingDebug = false
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if !sessionMonitor.isInitialLoadComplete {
                loadingView
            } else if sessionMonitor.sessions.isEmpty {
                emptyStateView
            } else {
                sessionListView
            }
            
            // Debug drawer
            if showingDebug {
                debugDrawerView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: showingDebug)
            }
            
            Divider()
            
            footerView
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 500, height: showingDebug ? preferencesManager.windowHeight + 300 : preferencesManager.windowHeight)
        .animation(.easeInOut(duration: 0.3), value: showingDebug)
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(onDismiss: {
                showingPreferences = false
            })
                .frame(width: 450, height: 420)
        }
    }
    
    private var headerView: some View {
        let workingCount = sessionMonitor.sessions.filter { $0.isWorking }.count
        let waitingCount = sessionMonitor.sessions.filter { !$0.isWorking }.count
        let totalCount = sessionMonitor.sessions.count
        
        return VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code sessions")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack(spacing: 20) {
                StatView(
                    label: "Total",
                    value: "\(totalCount)",
                    color: .primary,
                    showCircle: false
                )
                
                Divider()
                    .frame(height: 30)
                
                StatView(
                    label: "Working",
                    value: "\(workingCount)",
                    color: .blue,
                    showCircle: true
                )
                
                StatView(
                    label: "Waiting",
                    value: "\(waitingCount)",
                    color: .orange,
                    showCircle: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var sessionListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(sessionMonitor.sessions.enumerated()), id: \.element.id) { index, session in
                    HStack(spacing: 8) {
                        // Drag handle
                        Image(systemName: "line.3.horizontal")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .frame(width: 30)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .onDrag {
                                NSItemProvider(object: String(index) as NSString)
                            }
                        
                        SessionRowView(session: session, sessionMonitor: sessionMonitor) {
                            DebugLog.shared.log("Menu bar click detected for session \(session.processID)")
                            DebugLog.shared.log("Session TTY: \(session.terminalTTY ?? "nil")")
                            DebugLog.shared.log("Session terminalAppName: \(session.terminalAppName ?? "nil")")
                            sessionMonitor.focusTerminalWindow(for: session)
                        }
                    }
                    .onDrop(of: [.plainText], delegate: SessionDropDelegate(
                        sessions: sessionMonitor.sessions,
                        currentIndex: index,
                        sessionMonitor: sessionMonitor
                    ))
                }
            }
            .padding()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Scanning for Claude sessions...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Claude Code sessions detected")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Start a claude-code session in Terminal to see it here")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var debugDrawerView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                
                Button("Clear") {
                    debugLog.clear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Close") {
                    showingDebug = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(debugLog.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(DateFormatter.debugTime.string(from: entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(entry.color)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                        }
                    }
                    .id("logContent")
                }
                .frame(height: 280)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: debugLog.entries.count) { _ in
                    if autoScroll {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("logContent", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var footerView: some View {
        HStack {
            Button(action: { showingPreferences = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.caption)
                    Text("Preferences")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button(action: { showingDebug.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showingDebug ? "chevron.down" : "chevron.up")
                        .font(.caption)
                    Text("Debug")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Spacer()
            
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.caption)
                    Text("Quit")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
        }
    }
}

struct StatView: View {
    let label: String
    let value: String
    let color: Color
    var showCircle: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if showCircle {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
}

struct SessionRowView: View {
    let session: Session
    let sessionMonitor: SessionMonitor
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                statusIndicator
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // Show working directory first if available
                            if let workingDir = session.workingDirectory {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.system(.caption2))
                                        .foregroundColor(.secondary)
                                    Text(URL(fileURLWithPath: workingDir).lastPathComponent)
                                        .font(.system(.callout))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .help("Working directory: \(workingDir)")
                            }
                            
                            Text(session.taskDescription ?? session.projectName ?? "Claude Session")
                                .font(.system(.body))
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .help(session.taskDescription ?? session.workingDirectory ?? "Working directory unknown")
                            
                            HStack(spacing: 16) {
                                if let projectName = session.projectName {
                                    Label(projectName, systemImage: "folder")
                                        .font(.system(.caption))
                                        .foregroundColor(.secondary)
                                }
                                
                                Text("PID: \(String(session.processID))")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .help("Process ID: \(session.processID)\nTerminal: \(session.terminalAppName ?? "Unknown")")
                                
                                if session.compactionPercentage > 0 {
                                    Label("\(Int(session.compactionPercentage))% to auto-compact", systemImage: "archivebox")
                                        .font(.system(.caption, weight: session.compactionPercentage <= 10 ? .bold : .regular))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            if session.isWorking, let tool = session.currentTool {
                                Text(session.toolIcon(for: tool))
                                    .font(.caption)
                            }
                            Text(session.statusDescription)
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusBackgroundColor)
                        .foregroundColor(statusForegroundColor)
                        .cornerRadius(4)
                        .help(toolHelpText)
                    }
                    
                    Button(action: {
                        sessionMonitor.refreshTokenData(for: session)
                    }) {
                        HStack(alignment: .center, spacing: 16) {
                            HStack(spacing: 4) {
                                Image(systemName: "iphone.and.arrow.right.inward")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(session.inputTokens)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 4) {
                                Image(systemName: "iphone.and.arrow.right.outward")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(session.outputTokens)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Label(session.formattedCost, systemImage: "dollarsign.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                if let timeAgo = session.timeSinceTokenRefresh {
                                    Text(timeAgo)
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.7))
                                } else {
                                    Text("fetch")
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.7))
                                }

                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .rotationEffect(.degrees(session.isRefreshingTokens ? 360 : 0))
                                    .animation(session.isRefreshingTokens ? 
                                        .linear(duration: 0.333).repeatForever(autoreverses: false) : 
                                        .default, value: session.isRefreshingTokens)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isRefreshingTokens)
                    .help("Click to refresh usage metrics")
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private var statusIndicator: some View {
        Circle()
            .fill(statusIndicatorColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(statusIndicatorColor.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .opacity(session.isWorking ? 1 : 0)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: session.isWorking)
            )
    }
    
    private var statusIndicatorColor: Color {
        if session.isWorking {
            return .blue
        } else if session.hasOutput {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var statusBackgroundColor: Color {
        if session.isWorking {
            return .blue.opacity(0.1)
        } else if session.hasOutput {
            return .orange.opacity(0.1)
        } else {
            return .gray.opacity(0.1)
        }
    }
    
    private var statusForegroundColor: Color {
        if session.isWorking {
            return .blue
        } else if session.hasOutput {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var toolHelpText: String {
        if session.isWorking {
            if let _ = session.currentTool, let details = session.currentToolDetails {
                return "Claude is \(session.statusDescription.lowercased()): \(details)"
            } else if session.currentTool != nil {
                return "Claude is \(session.statusDescription.lowercased())"
            }
            return "Claude is currently processing"
        } else if session.hasOutput {
            return "Claude has output waiting for your input"
        } else {
            return "Claude is idle"
        }
    }
}
