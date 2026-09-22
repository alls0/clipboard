import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@MainActor
final class PanelInteraction: ObservableObject {
    @Published var presentationID = UUID()
    @Published var targetAppName: String?
    @Published var shortcutAvailable = true
    @Published var errorMessage: String?
    @Published var directPasteEnabled = UserDefaults.standard.bool(forKey: "Pano.directPasteEnabled") {
        didSet { UserDefaults.standard.set(directPasteEnabled, forKey: "Pano.directPasteEnabled") }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()

    var dismiss: () -> Void = {}
    var copyAndReturn: (ClipboardEntry) -> Void = { _ in }
    var requestAccessibility: () -> Void = {}
}

@MainActor
private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
@MainActor
struct PanoApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let showNotification = Notification.Name("dev.aliulus.pano.show")
    private var statusItem: NSStatusItem!
    private var panel: ClipboardPanel!
    private var store: ClipboardStore!
    private let interaction = PanelInteraction()
    private var previousApplication: NSRunningApplication?
    private var pendingPasteError: String?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.aliulus.pano"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNotification, object: bundleID,
                userInfo: nil, deliverImmediately: true
            )
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        rememberPreviousApplication()
        store = ClipboardStore()
        interaction.dismiss = { [weak self] in
            self?.hidePanel(restorePreviousApplication: true)
        }
        interaction.copyAndReturn = { [weak self] entry in
            guard let self else { return }
            guard self.store.copy(entry) else {
                self.interaction.errorMessage = "Metin panoya kopyalanamadı. Lütfen yeniden deneyin."
                return
            }
            self.interaction.accessibilityGranted = AXIsProcessTrusted()
            let destination = self.previousApplication
            self.hidePanel(restorePreviousApplication: true)
            if self.interaction.directPasteEnabled, self.interaction.accessibilityGranted,
               let destination, !destination.isTerminated {
                self.pasteWhenDestinationIsActive(destination)
            }
        }
        interaction.requestAccessibility = { [weak self] in
            guard let self else { return }
            self.interaction.directPasteEnabled = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            self.interaction.accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        }
        setupMenu()
        setupStatusItem()
        registerShortcut()
        setupWindow()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showRequested(_:)), name: Self.showNotification,
            object: bundleID, suspensionBehavior: .deliverImmediately
        )
        showWindow()
    }

    private func setupWindow() {
        let content = ContentView(store: store, interaction: interaction)
        panel = ClipboardPanel(
            contentRect: panelFrame(),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.title = "Pano"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content)
        panel.setAccessibilityLabel("Pano")
    }

    private func panelFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: visibleFrame.minX + 12,
            y: visibleFrame.minY + 12,
            width: visibleFrame.width - 24,
            height: 420
        )
    }

    private func rememberPreviousApplication() {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = application
        }
        if previousApplication?.isTerminated == true { previousApplication = nil }
        interaction.targetAppName = previousApplication?.localizedName
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Pano’yu aç")
            button.image?.isTemplate = true
            button.toolTip = "Pano · ⌘⇧V"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Pano’yu göster", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "Pano’yu kapat", action: #selector(dismissPanel), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Pano’dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.title = "Düzen"
        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Pano’yu aç", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: store.isPaused ? "Kaydı sürdür" : "Kaydı duraklat", action: #selector(togglePause), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Pano’dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc func showWindow() {
        guard panel != nil else { return }
        rememberPreviousApplication()
        interaction.accessibilityGranted = AXIsProcessTrusted()
        interaction.errorMessage = pendingPasteError
        pendingPasteError = nil
        interaction.presentationID = UUID()
        panel.setFrame(panelFrame(), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func showRequested(_ notification: Notification) {
        showWindow()
    }

    private func pasteWhenDestinationIsActive(_ destination: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard !destination.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
                self.pendingPasteError = "Hedef uygulama değiştiği için otomatik yapıştırılmadı. Metin panoda; ⌘V ile yapıştırabilirsiniz."
                return
            }
            guard self.interaction.directPasteEnabled, AXIsProcessTrusted() else { return }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                self.pendingPasteError = "Otomatik yapıştırma başlatılamadı. Metin panoda; ⌘V ile yapıştırabilirsiniz."
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    @objc private func togglePanel() {
        guard panel != nil else { return }
        if panel.isVisible {
            hidePanel(restorePreviousApplication: true)
        } else {
            showWindow()
        }
    }

    @objc private func dismissPanel() {
        hidePanel(restorePreviousApplication: true)
    }

    private func hidePanel(restorePreviousApplication: Bool) {
        guard let panel, panel.isVisible,
              panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        panel.orderOut(nil)
        if restorePreviousApplication,
           let application = previousApplication, !application.isTerminated {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Sheet presentation briefly changes key status. Wait until AppKit has
        // finished that change before deciding whether the user left the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel,
                  panel.isVisible, !panel.isKeyWindow else { return }
            self.hidePanel(restorePreviousApplication: false)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        hidePanel(restorePreviousApplication: false)
    }

    @objc private func togglePause() { store.isPaused.toggle() }

    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.togglePanel() }
            return noErr
        }, 1, &event, pointer, &hotKeyHandler)
        let identifier = EventHotKeyID(signature: 0x50414E4F, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), identifier,
                                        GetApplicationEventTarget(), 0, &hotKey)
        interaction.shortcutAvailable = handlerStatus == noErr && status == noErr
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        store?.stopMonitoring()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
}
