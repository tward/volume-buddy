import AppKit

final class StatusBarController {
    private var statusItem: NSStatusItem?

    var onQuit: (() -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateIcon(volume: 1.0, muted: false)

        let menu = NSMenu()

        let quitItem = NSMenuItem(title: "Quit VolumeBuddy", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    func updateIcon(volume: Float, muted: Bool) {
        let symbolName: String
        if muted || volume == 0 {
            symbolName = "speaker.slash.fill"
        } else if volume < 0.33 {
            symbolName = "speaker.wave.1.fill"
        } else if volume < 0.66 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Volume")
        }
    }

    // MARK: - Actions

    @objc private func quitClicked() {
        onQuit?()
    }
}
