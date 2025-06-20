# Changelog

All notable changes to Claude Code Monitor will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-12-20

### Added
- Initial release of Claude Code Monitor
- Real-time monitoring of Claude CLI sessions
- Menu bar display showing working/waiting session counts with colored indicators
- Session list with project names, PIDs, and status
- Token usage tracking (input/output) with manual refresh
- Cost calculation based on model pricing (Opus, Sonnet, Haiku)
- Auto-compaction percentage display
- Drag-and-drop session reordering
- Sound notifications when Claude finishes working
- Preferences window with:
  - Icon appearance toggle (template/colored)
  - Window height adjustment
  - Notification sound selection (30+ options)
- Click to focus terminal windows
- Dark/light mode support

### Technical Features
- Efficient process monitoring using ps commands
- Terminal content extraction via AppleScript
- JSONL file parsing for token usage data
- Persistent session-to-JSONL mapping
- SwiftUI interface with AppKit integration