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
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Volume")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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
