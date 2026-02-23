import AppKit
import CoreAudio

final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var devices: [AudioDevice] = []
    private var currentDevice: AudioDevice?

    var onQuit: (() -> Void)?
    var onOutputSelected: ((AudioDevice) -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateIcon(volume: 1.0, muted: false)

        let menu = NSMenu()
        menu.delegate = self
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

    func updateMenu(devices: [AudioDevice], current: AudioDevice?) {
        self.devices = devices
        self.currentDevice = current
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(deviceClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            if device.id == currentDevice?.id {
                item.state = .on
            }
            menu.addItem(item)
        }

        if !devices.isEmpty {
            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(title: "Quit VolumeBuddy", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func deviceClicked(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? AudioDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else { return }
        onOutputSelected?(device)
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
