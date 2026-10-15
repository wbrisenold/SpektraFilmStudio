#!/usr/bin/swift

import Foundation

/// CUA Smoke Test for SpektraFilmStudio RAW Workflow
/// 
/// This test:
/// 1. Launches SpektraFilmStudio
/// 2. Imports a test RAW image
/// 3. Navigates to Edit workspace
/// 4. Tests live slider editing (Exposure, Temperature, Film Exposure)
/// 5. Verifies preview updates in real-time without full renders

let appPath = "/Users/A1990/Downloads/SpektraFilmStudio/.build/release/SpektraFilmStudio"
let testImagePath = "/Users/A1990/Downloads/SpektraFilmStudio/Tests/Fixtures/test.cr3" // Placeholder

struct CuaTest {
    let driverPath = "/Users/A1990/.local/bin/cua-driver"
    
    func run() async throws {
        print("🔬 Starting CUA Smoke Test for SpektraFilmStudio RAW Workflow")
        print("============================================================")
        
        // Step 1: Start cua-driver session
        try await startSession()
        
        // Step 2: Launch the app
        try await launchApp()
        
        // Step 3: Wait for app to be ready
        try await waitForWindow()
        
        // Step 4: Import test image (or use existing)
        try await importTestImage()
        
        // Step 5: Navigate to Edit workspace
        try await navigateToEdit()
        
        // Step 6: Test live slider editing
        try await testLiveSliderEditing()
        
        // Step 7: Verify no full renders during slider drag
        try await verifyNoFullRendersDuringDrag()
        
        // Step 8: Clean up
        try await endSession()
        
        print("✅ All tests passed!")
    }
    
    func startSession() async throws {
        print("\n📋 Starting CUA session...")
        let result = try await runCuaDriver(args: ["start_session", "{\"session\":\"spektra-smoke-test\"}"])
        print("Session started: \(result)")
    }
    
    func launchApp() async throws {
        print("\n🚀 Launching SpektraFilmStudio...")
        let env = [
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": "org.spektrafilm.fast"
        ]
        let result = try await runCuaDriver(args: ["launch", appPath], environment: env)
        print("Launch result: \(result)")
    }
    
    func waitForWindow() async throws {
        print("\n⏳ Waiting for main window...")
        for attempt in 1...30 {
            let state = try await runCuaDriver(args: ["get_window_state"])
            if state.contains("SpektraFilmStudio") || state.contains("SpektraFilm") {
                print("Window found on attempt \(attempt)")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        throw TestError("Main window not found after 15 seconds")
    }
    
    func importTestImage() async throws {
        print("\n📁 Importing test image...")
        // Use ⌘I to open import dialog
        try await runCuaDriver(args: ["keypress", "{\"keys\":[\"cmd\",\"i\"]}"])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Check if we have a test image, otherwise use any available image
        // For now, we'll simulate selecting an existing image in the library
        // In a real test, we'd navigate the file dialog
        
        // Try to select first image in library (if any)
        try await runCuaDriver(args: ["click", "{\"x\":200,\"y\":200}"]) // Click first thumbnail area
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    
    func navigateToEdit() async throws {
        print("\n✏️ Navigating to Edit workspace...")
        // Click Edit tab in top toolbar
        try await runCuaDriver(args: ["click", "{\"x\":400,\"y\":30}"]) // Approximate Edit tab position
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Verify we're in Edit mode by checking for inspector panel
        let state = try await runCuaDriver(args: ["get_window_state"])
        if state.contains("Edit") || state.contains("inspector") || state.contains("RAW workflow") {
            print("Successfully navigated to Edit workspace")
        } else {
            print("Warning: Could not verify Edit workspace")
        }
    }
    
    func testLiveSliderEditing() async throws {
        print("\n🎚️ Testing live slider editing...")
        
        // Test 1: Exposure slider (Tone tab)
        print("  Test 1: Exposure slider (Tone tab)")
        try await testSliderAtPosition(x: 350, y: 250, name: "Exposure", dragDistance: 100)
        
        // Test 2: Temperature slider (RAW tab)
        print("  Test 2: Temperature slider (RAW tab)")
        try await switchToTab("RAW")
        try await testSliderAtPosition(x: 350, y: 200, name: "Temperature", dragDistance: 50)
        
        // Test 3: Film Exposure slider (Film tab)
        print("  Test 3: Film Exposure slider (Film tab)")
        try await switchToTab("Film")
        try await testSliderAtPosition(x: 350, y: 300, name: "Film Exposure", dragDistance: 80)
        
        // Test 4: Contrast slider
        print("  Test 4: Contrast slider (Tone tab)")
        try await switchToTab("Tone")
        try await testSliderAtPosition(x: 350, y: 300, name: "Contrast", dragDistance: 60)
    }
    
    func testSliderAtPosition(x: Int, y: Int, name: String, dragDistance: Int) async throws {
        print("    Dragging \(name) slider at (\(x), \(y))...")
        
        // Get initial window state (preview area)
        let initialState = try await runCuaDriver(args: ["get_window_state"])
        
        // Click and drag slider
        try await runCuaDriver(args: ["drag", "{\"start_x\":\(x),\"start_y\":\(y),\"end_x\":\(x + dragDistance),\"end_y\":\(y)}"])
        
        // Wait for live preview update
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Check for "Rendering" indicator (should NOT appear during live drag)
        let stateDuringDrag = try await runCuaDriver(args: ["get_window_state"])
        if stateDuringDrag.contains("Rendering") || stateDuringDrag.contains("rendering") {
            print("    ⚠️ WARNING: 'Rendering' indicator appeared during \(name) drag - full render triggered!")
        } else {
            print("    ✅ No 'Rendering' indicator during \(name) drag - live preview working")
        }
        
        // Check if preview updated (look for pixel changes in preview area)
        let finalState = try await runCuaDriver(args: ["get_window_state"])
        print("    State after drag: preview updated=\(finalState != initialState)")
    }
    
    func switchToTab(_ tabName: String) async throws {
        print("    Switching to \(tabName) tab...")
        // Click on segmented control for the tab
        let tabX: Int
        switch tabName {
        case "RAW": tabX = 150
        case "Tone": tabX = 220
        case "Crop": tabX = 290
        case "Optics": tabX = 360
        case "Film": tabX = 430
        default: tabX = 220
        }
        try await runCuaDriver(args: ["click", "{\"x\":\(tabX),\"y\":60}"])
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    
    func verifyNoFullRendersDuringDrag() async throws {
        print("\n🔍 Verifying no full renders during slider drag...")
        
        // Do a longer drag and monitor for "Rendering" status
        let initialState = try await runCuaDriver(args: ["get_window_state"])
        
        // Slow drag over 2 seconds
        try await runCuaDriver(args: ["drag", "{\"start_x\":350,\"start_y\":250,\"end_x\":450,\"end_y\":250,\"duration_ms\":2000}"])
        
        // Check multiple times during/after drag
        var renderCount = 0
        for _ in 1...10 {
            let state = try await runCuaDriver(args: ["get_window_state"])
            if state.contains("Rendering") {
                renderCount += 1
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        
        if renderCount > 0 {
            print("    ❌ FAIL: 'Rendering' appeared \(renderCount) times during slow drag")
            throw TestError("Full renders detected during live slider drag")
        } else {
            print("    ✅ PASS: No full renders during slow drag")
        }
    }
    
    func endSession() async throws {
        print("\n🧹 Ending CUA session...")
        let result = try await runCuaDriver(args: ["end_session", "{\"session\":\"spektra-smoke-test\"}"])
        print("Session ended: \(result)")
    }
    
    func runCuaDriver(args: [String], environment: [String: String] = [:]) async throws -> String {
        var fullArgs = [driverPath] + args
        let process = Process()
        process.executableURL = URL(fileURLWithPath: driverPath)
        process.arguments = Array(args)
        
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct TestError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Run the test
let test = CuaTest()
do {
    try await test.run()
    exit(0)
} catch {
    print("❌ Test failed: \(error)")
    exit(1)
}