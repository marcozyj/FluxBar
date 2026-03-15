import AppKit
import SwiftUI

@MainActor
final class FluxBarStatusBarController: NSObject {
    private let popover = NSPopover()
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configurePopover()
        configureStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 468, height: 928)
        popover.contentViewController = NSHostingController(rootView: FluxBarPopoverContainerView())
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "bolt.horizontal.circle.fill",
            accessibilityDescription: "FluxBar"
        )
        image?.isTemplate = true

        button.image = image
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
