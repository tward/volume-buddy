import AppKit
import CoreAudio
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let devices = DeviceManager.shared
    private let engine = AudioEngine()
    private let keyInterceptor = MediaKeyInterceptor()
    private let statusBar = StatusBarController()
    private let osd = VolumeOSD.shared

    private let volumeStep: Float = 1.0 / 16.0
    private let breadcrumbPath = NSTemporaryDirectory() + "VolumeBuddy.breadcrumb"

    private var volume: Float = 1.0 {
        didSet {
            volume = max(0, min(1, volume))
            engine.volume = muted ? 0 : volume
            statusBar.updateIcon(volume: volume, muted: muted)
            statusBar.updateSlider(volume: volume)
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }

    private var muted: Bool = false {
        didSet {
            engine.volume = muted ? 0 : volume
            statusBar.updateIcon(volume: volume, muted: muted)
            UserDefaults.standard.set(muted, forKey: "muted")
        }
    }

    // Cached device UIDs
    private var blackHoleUID: String?
    private var dellUID: String?
    private var originalDefaultDeviceID: AudioDeviceID?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore crash breadcrumb if needed
        restoreBreadcrumbIfNeeded()

        // Restore saved state
        if UserDefaults.standard.object(forKey: "volume") != nil {
            volume = UserDefaults.standard.float(forKey: "volume")
        }
        muted = UserDefaults.standard.bool(forKey: "muted")

        // Set up the status bar
        statusBar.setup()
        statusBar.updateIcon(volume: volume, muted: muted)
        statusBar.updateSlider(volume: volume)
        statusBar.onVolumeChanged = { [weak self] v in
            self?.muted = false
            self?.volume = v
            self?.osd.show(volume: v, muted: false)
        }
        statusBar.onMuteToggled = { [weak self] in
            self?.toggleMute()
        }
        statusBar.onQuit = { [weak self] in
            self?.shutdown()
            NSApp.terminate(nil)
        }

        // Find devices and start
        guard let blackHole = devices.findDevice(named: "BlackHole 16ch") else {
            showAlert("BlackHole 16ch not found. Please install BlackHole first.")
            NSApp.terminate(nil)
            return
        }
        guard let dell = devices.findDevice(named: "DELL U2725QE") else {
            showAlert("DELL U2725QE not found. Is the monitor connected?")
            NSApp.terminate(nil)
            return
        }

        blackHoleUID = blackHole.uid
        dellUID = dell.uid

        // Save original default & write breadcrumb
        originalDefaultDeviceID = devices.defaultOutputDeviceID()
        writeBreadcrumb()

        // Set BlackHole as default output so all system audio goes there
        if !devices.setDefaultOutput(blackHole.id) {
            showAlert("Failed to set BlackHole as default output device.")
            NSApp.terminate(nil)
            return
        }

        // Start the audio engine
        do {
            try engine.start(blackHoleUID: blackHole.uid, dellUID: dell.uid)
            engine.volume = muted ? 0 : volume
        } catch {
            showAlert("Failed to start audio engine: \(error.localizedDescription)")
            // Restore original device
            if let orig = originalDefaultDeviceID { _ = devices.setDefaultOutput(orig) }
            NSApp.terminate(nil)
            return
        }

        // Start media key interception
        keyInterceptor.onVolumeUp = { [weak self] in self?.stepVolume(up: true) }
        keyInterceptor.onVolumeDown = { [weak self] in self?.stepVolume(up: false) }
        keyInterceptor.onMute = { [weak self] in self?.toggleMute() }
        keyInterceptor.start()

        // Listen for device changes
        devices.onDevicesChanged = { [weak self] in
            self?.handleDeviceChange()
        }

        // Listen for wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        print("[VolumeBuddy] Running — volume: \(volume), muted: \(muted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: - Volume Control

    private func stepVolume(up: Bool) {
        if muted && up {
            muted = false
        } else {
            volume += up ? volumeStep : -volumeStep
        }
        osd.show(volume: volume, muted: muted)
    }

    private func toggleMute() {
        muted.toggle()
        osd.show(volume: volume, muted: muted)
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange() {
        // Verify our devices are still present
        guard devices.findDevice(named: "BlackHole 16ch") != nil,
              devices.findDevice(named: "DELL U2725QE") != nil else {
            print("[VolumeBuddy] Device disconnected, stopping engine")
            engine.stop()
            return
        }

        // If engine isn't running, try to restart
        if !engine.isRunning, let bhUID = blackHoleUID, let dUID = dellUID {
            print("[VolumeBuddy] Restarting engine after device change")
            try? engine.restart(blackHoleUID: bhUID, dellUID: dUID)
            engine.volume = muted ? 0 : volume
        }
    }

    @objc private func handleWake() {
        // Delay to let audio subsystem stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            print("[VolumeBuddy] Woke from sleep, checking audio engine")

            // Re-find devices (IDs may have changed)
            guard let bh = self.devices.findDevice(named: "BlackHole 16ch"),
                  let dell = self.devices.findDevice(named: "DELL U2725QE") else {
                print("[VolumeBuddy] Devices not found after wake")
                return
            }

            self.blackHoleUID = bh.uid
            self.dellUID = dell.uid

            // Ensure BlackHole is still default
            _ = self.devices.setDefaultOutput(bh.id)

            // Restart engine
            do {
                try self.engine.restart(blackHoleUID: bh.uid, dellUID: dell.uid)
                self.engine.volume = self.muted ? 0 : self.volume
                print("[VolumeBuddy] Engine restarted after wake")
            } catch {
                print("[VolumeBuddy] Failed to restart after wake: \(error)")
            }
        }
    }

    // MARK: - Shutdown

    private func shutdown() {
        keyInterceptor.stop()
        engine.stop()

        // Restore original default output so audio isn't lost
        if let origID = originalDefaultDeviceID {
            _ = devices.setDefaultOutput(origID)
            print("[VolumeBuddy] Restored default output to device \(origID)")
        }

        removeBreadcrumb()
    }

    // MARK: - Crash Recovery Breadcrumb

    private func writeBreadcrumb() {
        guard let origID = originalDefaultDeviceID else { return }
        try? "\(origID)".write(toFile: breadcrumbPath, atomically: true, encoding: .utf8)
    }

    private func removeBreadcrumb() {
        try? FileManager.default.removeItem(atPath: breadcrumbPath)
    }

    private func restoreBreadcrumbIfNeeded() {
        guard let content = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8),
              let deviceID = AudioDeviceID(content) else { return }
        print("[VolumeBuddy] Found stale breadcrumb, restoring device \(deviceID)")
        _ = devices.setDefaultOutput(deviceID)
        removeBreadcrumb()
    }

    // MARK: - Helpers

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VolumeBuddy"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
