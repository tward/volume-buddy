import AppKit

final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var slider: NSSlider?

    var onVolumeChanged: ((Float) -> Void)?
    var onMuteToggled: (() -> Void)?
    var onQuit: (() -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateIcon(volume: 1.0, muted: false)

        let menu = NSMenu()

        // Volume slider item
        let sliderItem = NSMenuItem()
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let slider = NSSlider(frame: NSRect(x: 16, y: 4, width: 168, height: 22))
        slider.minValue = 0
        slider.maxValue = 1
        slider.floatValue = 1.0
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        self.slider = slider
        sliderView.addSubview(slider)
        sliderItem.view = sliderView
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let muteItem = NSMenuItem(title: "Mute", action: #selector(muteClicked), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(.separator())

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

    func updateSlider(volume: Float) {
        slider?.floatValue = volume
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        onVolumeChanged?(sender.floatValue)
    }

    @objc private func muteClicked() {
        onMuteToggled?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
