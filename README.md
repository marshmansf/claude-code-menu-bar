# Claude Code Monitor

A macOS menu bar application that monitors active Claude Code CLI sessions using the Claude Code Hooks feature, providing real-time status updates, notifications when a Claude Code session finishes working and is waiting for you, usage metrics, and quick access to jump to your Claude Code terminal windows.

<img src="assets/screenshot.png" alt="Menu Bar and Sessions View" width="400">
<img src="assets/screenshot-preferences.png" alt="Preferences View" width="400">

Naturally, Claude Code did most of the work making this app.

## Features

### Real-Time Session Monitoring (via Claude Code Hooks)
- **Live Status Updates**: Shows which Claude sessions are currently working, waiting, or idle using Claude Code's hooks feature
- **Menu Bar Indicators**: Colored circles with counts (🔵 working, 🟠 waiting)
- **Working State Details**: Displays current tool being used (e.g., "🔍 Searching files", "✏️ Editing code", "🖥️ Running commands")
- **Auto-Compaction Tracking**: Shows percentage until context window compaction
- **Task Description**: Shows the most recent user prompt for each session
- **Working Directory**: Displays the current project folder prominently

### Token Usage & Cost Tracking
- **Token Counting**: Tracks input and output tokens for each session
- **Cost Calculation**: Automatic pricing based on detected model (Opus, Sonnet)
- **Automatic Updates**: Token counts update automatically when Claude Code sends hook events
- **Session Matching**: Uses working directory and session ID for accurate JSONL file matching

The token usage and cost tracking is provided by Claude Code's transcript files and ought to be accurate for sessions that have transcript data available, but this has not been validated.

### Interactive Interface
- **Click to Focus**: Click any session to bring its terminal window to front
- **Drag & Drop Reordering**: Organize sessions in your preferred order
- **Sound Notifications**: Plays a sound when Claude finishes working (customizable)

### Preferences
- **Icon Style**: Toggle between template (adapts to menu bar) or colored icon
- **Window Height**: Adjustable popover height (300-800px)
- **Notification Sounds**: Choose from 30+ sound options or disable
- **Launch at Login**: Start automatically when you log in

### Debug Panel
- **Raw Hook Events**: View all Claude Code hook events in real-time
- **Claude Session Debugging**: Useful for debugging Claude Code session and process detection, and click-to-focus functionality



## Installation

### Option 1: Build from Source
1. Clone this repository
2. Open `ClaudeCodeMonitor.xcodeproj` in Xcode
3. Select your development team (or use personal team)
4. Build and run (⌘+R)

### Option 2: Download Release

1. Download the latest release from [Releases](https://github.com/marshmansf/claude-code-menu-bar/releases)
2. Unzip the file
3. Move `ClaudeCodeMonitor.app` to your Applications folder
4. **Important**: Since the app isn't code-signed, you need to remove the quarantine attribute:
   - Open Terminal
   - Run: `xattr -cr /Applications/ClaudeCodeMonitor.app`
5. Right-click `ClaudeCodeMonitor.app` and select "Open"
6. Click "Open" in the security dialog
7. The app will now run normally

**Note**: Steps 4-6 are only needed on first launch. The app is safe and open-source, but macOS requires these steps for apps without an Apple Developer certificate.

## Usage

1. **Launch**: The app runs in your menu bar (look for the <img src="assets/icon-44px.png" alt="Menu Bar App Icon" width="44"> icon)
2. **View Sessions**: Click the menu bar icon to see active sessions
3. **Focus Terminal**: Click any session to switch to its terminal window (supports iTerm2, Terminal.app, and tmux)
4. **View Token Usage**: Refresh the displayed token count usage
5. **Reorder Sessions**: Drag the handle (≡) to reorder sessions
6. **Access Preferences**: Click the preferences button at the bottom
7. **Debug Mode**: Toggle debug panel to see raw hook events (useful for troubleshooting)

## How It Works

The app monitors Claude CLI sessions using the Claude Code Hooks feature:
1. Registers hooks in your ~/.claude/settings.json for the menu bar app
2. Listens on a local HTTP server (port 8124) for hook events from Claude Code
3. Reads the JSONL transcript files (as reported by the hooks) from `~/.claude/projects/` for working directory, prompt, and token data
4. Matches sessions by working directory to handle multiple concurrent sessions
5. Calculates costs based on detected model pricing
6. Supports terminal window focusing for iTerm2, Terminal.app, and tmux sessions

## System Requirements

- macOS 13.0 (Ventura) or later
- Claude CLI installed and configured (with hooks support)
- iTerm2 or Terminal.app, with optional tmux

## Privacy & Security

- **Local Only**: All monitoring happens locally on your machine
- **No Network Calls**: No data is sent to external servers
- **Read-Only**: Only reads Claude's local files with the exception of registering hooks in your ~/.claude/settings.json; never modifies any other Claude files

## Troubleshooting

### App doesn't show sessions
- Ensure Claude Code hooks are configured in your ~/.claude/settings.json
- Check that at least one Claude CLI is running (`claude` command in terminal)
- Verify the app is running (look for the icon in menu bar)
- Check the Debug panel to see if hook events are being received or Claude processes detected

### Token counts show zero
- Token data comes from Claude Code transcript files
- Some sessions may not have token data immediately
- Check that `~/.claude/projects/` directory is accessible

### Can't focus terminal windows
- Grant accessibility permissions when prompted
- For tmux sessions, ensure tmux is running in a supported terminal
- Check that you're using iTerm2, Terminal.app, and/or tmux

## Development

### Architecture
- **Language**: Swift 5 with SwiftUI
- **Frameworks**: AppKit, SwiftUI, Cocoa
- **Key Components**:
  - `SessionMonitor`: Core monitoring logic with hooks integration
  - `HookServer`: HTTP server listening for Claude Code hook events
  - `ClaudeFileParser`: Reads JSONL token data
  - `TranscriptReader`: Parses Claude Code transcript files
  - `MenuBarView`: SwiftUI interface with drag & drop support
  - `DebugView`: Real-time hook event viewer

### Building
```bash
# Clone repository
git clone https://github.com/marshmansf/claude-code-menu-bar.git
cd claude-code-menu-bar

# Open in Xcode
open ClaudeCodeMonitor.xcodeproj

# Or build from command line
xcodebuild -project ClaudeCodeMonitor.xcodeproj -scheme ClaudeCodeMonitor
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

Put your Claude engines to work and enhance this tool!

## License

MIT License - see [LICENSE](LICENSE) file for details

## Acknowledgments

- Built for the Claude CLI community
- Icon design inspired by Anthropic's Claude
- Sound effects from freesound.org contributors; all sounds used are Creatives Commons 0 licensed