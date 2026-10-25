import SwiftUI
import AppKit
import Combine

@main
struct RapidManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The UI lives in an NSStatusItem + NSPopover owned by AppDelegate;
    // SwiftUI only needs a scene that never shows a window.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the status item and its popover, so open/close state is ours to control.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = ServerController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: MenuView().environmentObject(controller))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient          // closes on outside click / Esc

        WindowManager.shared.dismissMenu = { [weak self] in self?.popover.performClose(nil) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateIcon(for: controller.status)
        statusSub = controller.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateIcon(for: status) }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            popover.performClose(nil)
            controller.toggleManager()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refreshModels()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon(for status: ServerStatus) {
        let name: String
        switch status {
        case .running, .external: name = "bolt.circle.fill"
        case .starting, .stopping: name = "arrow.triangle.2.circlepath.circle"
        case .failed: name = "exclamationmark.triangle"
        case .stopped: name = "bolt.circle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "RapidManager")
    }
}
