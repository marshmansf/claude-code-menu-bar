import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var sessionMonitor: SessionMonitor!
    private var menuBarView: MenuBarView!
    private var eventMonitor: Any?
    private var preferencesWindow: NSWindow?
    private var previousWaitingCount = 0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app is properly activated
        NSApp.setActivationPolicy(.accessory)
        
        // Configure hooks on startup
        HookConfigManager.shared.ensureHooksConfigured()
        
        setupMenuBar()
        setupSessionMonitor()
        setupEventMonitor()
        setupNotificationObservers()
        
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Load custom Claude icon
            if let iconPath = Bundle.main.path(forResource: "ClaudeIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                // Resize icon for menu bar
                icon.size = NSSize(width: 22, height: 22)
                icon.isTemplate = PreferencesManager.shared.useTemplateIcon
                button.image = icon
            } else {
                // Fallback to system icon
                button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Code Monitor")
                button.image?.isTemplate = true
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.behavior = .transient
        popover.animates = true
        
        sessionMonitor = SessionMonitor()
        menuBarView = MenuBarView(sessionMonitor: sessionMonitor)
        popover.contentViewController = NSHostingController(rootView: menuBarView)
        
        updateStatusItemView()
    }
    
    private func setupSessionMonitor() {
        sessionMonitor.onSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItemView()
            }
        }
        sessionMonitor.startMonitoring()
    }
    
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if self?.popover.isShown == true {
                self?.closePopover()
            }
        }
    }
    
    private func updateStatusItemView() {
        guard let button = statusItem.button else { return }
        
        let workingCount = sessionMonitor.sessions.filter { $0.isWorking }.count
        let waitingCount = sessionMonitor.sessions.filter { !$0.isWorking }.count
        let totalSessions = sessionMonitor.sessions.count
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Always update the icon with current template setting
            if let iconPath = Bundle.main.path(forResource: "ClaudeIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.size = NSSize(width: 22, height: 22)
                icon.isTemplate = PreferencesManager.shared.useTemplateIcon
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Code Monitor")
                button.image?.isTemplate = true
            }
            
            // Clear the title and use an attributed string instead
            if totalSessions == 0 {
                button.attributedTitle = NSAttributedString()
            } else {
                // Create an attributed string with overlaid numbers
                let attributedString = self.createStatusAttributedString(workingCount: workingCount, waitingCount: waitingCount)
                button.attributedTitle = attributedString
                
                // Check if waiting count increased for animation
                if waitingCount > self.previousWaitingCount {
                    // Trigger a brief animation by updating again after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.updateStatusItemView()
                    }
                }
                self.previousWaitingCount = waitingCount
            }
        }
    }
    
    private func createStatusAttributedString(workingCount: Int, waitingCount: Int) -> NSAttributedString {
        let mutableString = NSMutableAttributedString()
        
        // Add a small space before the circles
        mutableString.append(NSAttributedString(string: " "))
        
        if workingCount > 0 {
            // Create blue circle with number
            let blueCircle = createCircleWithNumber(color: .systemBlue, number: workingCount)
            mutableString.append(blueCircle)
        }
        
        if workingCount > 0 && waitingCount > 0 {
            // Add space between circles
            mutableString.append(NSAttributedString(string: " "))
        }
        
        if waitingCount > 0 {
            // Create orange circle with number
            let orangeCircle = createCircleWithNumber(color: .systemOrange, number: waitingCount)
            mutableString.append(orangeCircle)
        }
        
        return mutableString
    }
    
    private func createCircleWithNumber(color: NSColor, number: Int) -> NSAttributedString {
        // Create an image with the circle and number
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // Draw circle
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 20, height: 20))
        color.setFill()
        circlePath.fill()
        
        // Draw number
        let numberString = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        
        let textSize = numberString.size(withAttributes: attributes)
        let textRect = NSRect(x: (20 - textSize.width) / 2,
                              y: (20 - textSize.height) / 2,
                              width: textSize.width,
                              height: textSize.height)
        
        numberString.draw(in: textRect, withAttributes: attributes)
        
        image.unlockFocus()
        
        // Create attachment with the image
        let attachment = NSTextAttachment()
        attachment.image = image
        
        // Adjust the bounds to align properly
        attachment.bounds = NSRect(x: 0, y: -5, width: 20, height: 20)
        
        return NSAttributedString(attachment: attachment)
    }
    
    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                closePopover()
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    func closePopover() {
        popover.performClose(nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iconModeChanged),
            name: .iconModeChanged,
            object: nil
        )
    }
    
    @objc private func iconModeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusItemView()
        }
    }
    
    @objc public func showPreferences() {
        if preferencesWindow == nil {
            let preferencesView = PreferencesView(onDismiss: { [weak self] in
                self?.preferencesWindow?.close()
                self?.preferencesWindow = nil
            })
            let hostingController = NSHostingController(rootView: preferencesView)
            
            preferencesWindow = NSWindow(contentViewController: hostingController)
            preferencesWindow?.title = "Claude Code Monitor Preferences"
            preferencesWindow?.styleMask = [.titled, .closable, .miniaturizable]
            preferencesWindow?.isReleasedWhenClosed = false
            preferencesWindow?.center()
            preferencesWindow?.delegate = self
        }
        
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == preferencesWindow {
            preferencesWindow = nil
        }
    }
}