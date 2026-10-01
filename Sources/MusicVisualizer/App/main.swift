import AppKit
import SwiftUI

/// Handles bare keystrokes before they reach the view hierarchy.
///
/// Subclassing beats `NSEvent.addLocalMonitorForEvents` here: the monitor API hands
/// an `NSEvent` into a `@Sendable` closure, which Swift 6 rightly objects to, and
/// this override runs on the main thread where AppKit events already live.
final class VisualizerApplication: NSApplication {
    /// Set once the delegate has built its window and engine.
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           !event.modifierFlags.contains(.command),
           !(keyWindow?.firstResponder is NSTextView),
           let keyHandler,
           keyHandler(event) {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = VisualizerEngine()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        (NSApp as? VisualizerApplication)?.keyHandler = { [weak self] event in
            self?.handle(event) ?? false
        }
        engine.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Window

    private func buildWindow() {
        let content = ContentView(engine: engine)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Music Visualizer"
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 720, height: 460)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: engine.cycleMode(by: -1); return true    // left arrow
        case 124: engine.cycleMode(by: 1); return true     // right arrow
        case 49: engine.cycleMode(by: 1); return true      // space
        default: break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // 1–9 then 0 and - reach all eleven visualizations.
        if let index = "1234567890-".firstIndex(of: Character(characters))?.utf16Offset(in: "1234567890-"),
           characters.count == 1,
           let mode = VisualMode(rawValue: index) {
            engine.mode = mode
            return true
        }

        switch characters {
        case "f": window.toggleFullScreen(nil); return true
        case "c": engine.cyclePalette(); return true
        case "r": engine.randomize(); return true
        case "a": engine.toggleAutoCycle(); return true
        default: return false
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Music Visualizer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Music Visualizer",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Music Visualizer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let shortcuts = Array("1234567890-")
        for (index, mode) in VisualMode.allCases.enumerated() {
            let key = index < shortcuts.count ? String(shortcuts[index]) : ""
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            item.tag = mode.rawValue
            item.target = self
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        for (title, selector, key) in [
            ("Next Color Palette", #selector(nextPalette), "c"),
            ("Shuffle", #selector(shuffle), "r"),
            ("Auto-Cycle Visualizations", #selector(toggleAutoCycle), "a")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "\u{0D}")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let mode = VisualMode(rawValue: sender.tag) { engine.mode = mode }
    }

    @objc private func nextPalette() { engine.cyclePalette() }
    @objc private func shuffle() { engine.randomize() }
    @objc private func toggleAutoCycle() { engine.toggleAutoCycle() }
}

// Offscreen render of the controls, used to review UI changes.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > flag + 1 {
    let directory = CommandLine.arguments[flag + 1]
    MainActor.assumeIsolated { Snapshot.run(directory: directory) }
}

// Headless capture check, used to verify permissions and the audio path.
if let flag = CommandLine.arguments.firstIndex(of: "--diagnose") {
    let path = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil
    MainActor.assumeIsolated { Diagnostics.run(outputPath: path) }
}

let application = VisualizerApplication.shared
// Top-level code already runs on the main thread; this just tells the compiler so.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
