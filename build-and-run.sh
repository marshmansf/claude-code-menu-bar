#!/bin/bash

# Build and run the Claude Code Monitor app

echo "Building Claude Code Monitor..."

# Build the project
xcodebuild -project ClaudeCodeMonitor.xcodeproj \
           -scheme ClaudeCodeMonitor \
           -configuration Debug \
           -derivedDataPath build \
           clean build

if [ $? -eq 0 ]; then
    echo "Build successful!"
    
    # Copy sound resources
    echo "Copying sound resources..."
    cp -r ClaudeCodeMonitor/sounds build/Build/Products/Debug/ClaudeCodeMonitor.app/Contents/Resources/
    
    echo "Running the app..."
    
    # Kill any existing instances
    killall ClaudeCodeMonitor 2>/dev/null || true
    
    # Find and run the built app
    APP_PATH="build/Build/Products/Debug/ClaudeCodeMonitor.app"
    
    if [ -d "$APP_PATH" ]; then
        open "$APP_PATH"
        echo "App launched. Check your menu bar for the Claude icon."
    else
        echo "Error: Could not find built app at $APP_PATH"
    fi
else
    echo "Build failed!"
    exit 1
fi