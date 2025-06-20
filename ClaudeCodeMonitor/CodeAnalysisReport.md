# ClaudeCodeMonitor Code Analysis Report

## 1. Unused Functions, Variables, and Imports

### AppDelegate.swift
- **Duplicate Code**: The `PreferencesManager` and `PreferencesView` classes are duplicated in AppDelegate.swift (lines 5-175). These already exist in separate files and should be removed.
- **Unused Import**: No unused imports detected.

### PreferencesManager.swift
- **Unused Sounds**: The `availableSounds` array in PreferencesManager.swift (lines 20-36) contains fewer sounds than the duplicate in AppDelegate.swift. The AppDelegate version has more sounds that are never accessible.

### PreferencesView.swift
- **Unused Import**: `PreferencesView_Previews` (lines 67-71) is never used in production and could be removed or wrapped in `#if DEBUG`.

### Session.swift
- **Unused Properties**: 
  - `terminalWindowID` (line 6) is initialized to nil and never used
  - `startTime` (line 7) is set but never accessed

### Other Files
- No significant unused code detected in other files.

## 2. Error Handling Issues

### Force Unwraps (!)
1. **SessionMonitor.swift:244** - `lastActivity!` force unwrap in date comparison
   ```swift
   if lastActivity == nil || date > lastActivity! {
   ```
   Should use optional binding instead.

2. **Multiple AppleScript executions** - No force unwraps but missing error handling in many places

### Unhandled Errors
1. **ProcessDetector.swift** - Multiple silent error catches without logging:
   - Line 92: Empty catch block
   - Line 161: Silent fail comment but no logging
   - Line 189: Returns false on error without indication

2. **ClaudeFileParser.swift** - Silent failures:
   - Lines 76-77: JSON parsing errors ignored
   - Lines 113-114: File system errors ignored
   - Lines 174-175: File reading errors ignored

3. **SessionMonitor.swift** - AppleScript errors not properly logged:
   - Lines 493-495: Error occurs but not logged
   - Lines 510-516: Error handling but no user feedback

4. **TerminalContentParser.swift** - Missing nil checks:
   - Line 60: Result could be nil but not handled properly

## 3. Memory Leaks - Retain Cycles

### Potential Retain Cycles
1. **SessionMonitor.swift:233** - Weak self used correctly in closure ✓
2. **AppDelegate.swift:233** - Weak self used correctly in closure ✓
3. **MenuBarView.swift** - No retain cycles detected ✓

### Memory Management Issues
1. **SessionMonitor.swift** - `pidToJsonlPath` dictionary (line 21) grows indefinitely:
   - Entries are only removed when sessions end (line 255)
   - Could accumulate if processes crash or terminate abnormally

2. **AppDelegate.swift:239** - Global event monitor not properly cleaned up if app crashes
   - Only removed in `applicationWillTerminate` (line 366)

## 4. Performance Issues

### Main Thread Operations
1. **Heavy AppleScript execution on main thread**:
   - **TerminalContentParser.swift:57** - `getTerminalContent` runs AppleScript synchronously
   - **TerminalContentParser.swift:193** - `getTerminalWindowTitle` runs AppleScript synchronously
   - These are called from `updateSessions` which runs on background queue, but still blocks

2. **File I/O on main thread**:
   - **PreferencesManager.swift:48** - Sound loading happens on main thread
   - Should be loaded once and cached

3. **Inefficient operations**:
   - **SessionMonitor.swift:102-104** - Terminal content parsing happens for every session every 2 seconds
   - **ClaudeFileParser.swift:130-176** - Parsing entire JSONL files repeatedly
   - Should implement incremental parsing or caching

4. **Regex compilation**:
   - **TerminalContentParser.swift:69, 124** - Regex compiled on every parse
   - Should be compiled once and reused

## Recommendations

### High Priority
1. Remove duplicate PreferencesManager and PreferencesView code from AppDelegate.swift
2. Fix the force unwrap in SessionMonitor.swift line 244
3. Move AppleScript execution to background queues
4. Implement proper error logging for silent failures

### Medium Priority
1. Cache compiled regex patterns
2. Implement incremental JSONL parsing
3. Add proper cleanup for pidToJsonlPath dictionary
4. Cache sound files after first load

### Low Priority
1. Remove unused properties from Session struct
2. Wrap preview providers in DEBUG conditionals
3. Add user-facing error messages for critical failures

## Code Quality Notes
- The codebase generally follows good Swift practices
- Proper use of weak self in most closures
- Good separation of concerns with distinct classes
- Could benefit from more comprehensive error handling strategy