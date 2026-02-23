import AppKit
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.local.VolumeBuddy", category: "App")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let devices = DeviceManager.shared
    private let engine = AudioEngine()
    private let statusBar = StatusBarController()

    private let breadcrumbPath = NSTemporaryDirectory() + "VolumeBuddy.breadcrumb"

    // Cached device info
    private var blackHoleID: AudioDeviceID?
    private var blackHoleUID: String?
    private var outputDevice: AudioDevice?
    private var originalDefaultDeviceID: AudioDeviceID?
    private var originalSystemOutputDeviceID: AudioDeviceID?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore crash breadcrumb if needed
        restoreBreadcrumbIfNeeded()

        // Set up the status bar
        statusBar.setup()
        statusBar.onQuit = { [weak self] in
            self?.shutdown()
            NSApp.terminate(nil)
        }
        statusBar.onOutputSelected = { [weak self] device in
            self?.switchOutput(to: device)
        }

        // Find BlackHole
        guard let blackHole = devices.findDevice(named: "BlackHole 16ch") else {
            showAlert("BlackHole 16ch not found. Please install BlackHole first.")
            NSApp.terminate(nil)
            return
        }

        blackHoleID = blackHole.id
        blackHoleUID = blackHole.uid

        // Pick output device: last-used from UserDefaults, or first fixed-volume device
        let fixedDevices = devices.fixedVolumeOutputDevices()
        let savedUID = UserDefaults.standard.string(forKey: "outputDeviceUID")
        let output = fixedDevices.first(where: { $0.uid == savedUID }) ?? fixedDevices.first

        guard let output else {
            showAlert("No fixed-volume output device found. Is a monitor or DAC connected?")
            NSApp.terminate(nil)
            return
        }

        outputDevice = output
        refreshMenu()

        // Clean up any stale aggregate from a previous crash
        engine.destroyStaleAggregate()

        // Save original defaults & write breadcrumb
        originalDefaultDeviceID = devices.defaultOutputDeviceID()
        originalSystemOutputDeviceID = devices.defaultSystemOutputDeviceID()
        writeBreadcrumb()

        // Set BlackHole as default output so all system audio goes there
        if !devices.setDefaultOutput(blackHole.id) {
            showAlert("Failed to set BlackHole as default output device.")
            NSApp.terminate(nil)
            return
        }
        _ = devices.setDefaultSystemOutput(blackHole.id)

        // Start the audio engine
        do {
            try engine.start(blackHoleID: blackHole.id, blackHoleUID: blackHole.uid,
                              outputID: output.id, outputUID: output.uid)
        } catch {
            showAlert("Failed to start audio engine: \(error.localizedDescription)")
            if let orig = originalDefaultDeviceID { _ = devices.setDefaultOutput(orig) }
            if let orig = originalSystemOutputDeviceID { _ = devices.setDefaultSystemOutput(orig) }
            NSApp.terminate(nil)
            return
        }

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

        log.info("Running — output: \(output.name)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: - Output Switching

    private func switchOutput(to device: AudioDevice) {
        guard device.id != outputDevice?.id else { return }

        log.info("Switching output to \(device.name)")
        outputDevice = device
        UserDefaults.standard.set(device.uid, forKey: "outputDeviceUID")
        refreshMenu()

        guard let bhID = blackHoleID, let bhUID = blackHoleUID else { return }
        do {
            try engine.restart(blackHoleID: bhID, blackHoleUID: bhUID,
                               outputID: device.id, outputUID: device.uid)
        } catch {
            log.error("Failed to switch output: \(error)")
        }
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange() {
        refreshMenu()

        // Verify our devices are still present
        guard devices.findDevice(named: "BlackHole 16ch") != nil,
              let output = outputDevice,
              devices.allOutputDevices().contains(where: { $0.id == output.id }) else {
            log.warning("Device disconnected, stopping engine")
            engine.stop()
            return
        }

        // If engine isn't running, try to restart
        if !engine.isRunning,
           let bhID = blackHoleID, let bhUID = blackHoleUID {
            log.info("Restarting engine after device change")
            try? engine.restart(blackHoleID: bhID, blackHoleUID: bhUID,
                                outputID: output.id, outputUID: output.uid)
        }
    }

    @objc private func handleWake() {
        // Delay to let audio subsystem stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            log.info("Woke from sleep, checking audio engine")

            // Re-find devices (IDs may have changed)
            guard let bh = self.devices.findDevice(named: "BlackHole 16ch") else {
                log.error("BlackHole not found after wake")
                return
            }

            self.blackHoleID = bh.id
            self.blackHoleUID = bh.uid

            // Re-find current output device by UID
            if let currentUID = self.outputDevice?.uid,
               let refreshed = self.devices.allOutputDevices().first(where: { $0.uid == currentUID }) {
                self.outputDevice = refreshed
            } else {
                log.error("Output device not found after wake")
                return
            }

            self.refreshMenu()

            // Ensure BlackHole is still default for both output and alerts
            _ = self.devices.setDefaultOutput(bh.id)
            _ = self.devices.setDefaultSystemOutput(bh.id)

            // Restart engine
            guard let output = self.outputDevice else { return }
            do {
                try self.engine.restart(blackHoleID: bh.id, blackHoleUID: bh.uid,
                                        outputID: output.id, outputUID: output.uid)
                log.info("Engine restarted after wake")
            } catch {
                log.error("Failed to restart after wake: \(error)")
            }
        }
    }

    // MARK: - Menu

    private func refreshMenu() {
        let fixedDevices = devices.fixedVolumeOutputDevices()
        statusBar.updateMenu(devices: fixedDevices, current: outputDevice)
    }

    // MARK: - Shutdown

    private func shutdown() {
        engine.stop()

        // Restore original default outputs so audio isn't lost
        if let origID = originalDefaultDeviceID {
            _ = devices.setDefaultOutput(origID)
            log.info("Restored default output to device \(origID)")
        }
        if let origID = originalSystemOutputDeviceID {
            _ = devices.setDefaultSystemOutput(origID)
        }

        removeBreadcrumb()
    }

    // MARK: - Crash Recovery Breadcrumb

    private func writeBreadcrumb() {
        guard let origID = originalDefaultDeviceID else { return }
        let sysID = originalSystemOutputDeviceID ?? origID
        try? "\(origID),\(sysID)".write(toFile: breadcrumbPath, atomically: true, encoding: .utf8)
    }

    private func removeBreadcrumb() {
        try? FileManager.default.removeItem(atPath: breadcrumbPath)
    }

    private func restoreBreadcrumbIfNeeded() {
        guard let content = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8) else { return }
        let parts = content.split(separator: ",")
        guard let defaultID = AudioDeviceID(parts.first ?? "") else { return }
        log.warning("Found stale breadcrumb, restoring devices")
        _ = devices.setDefaultOutput(defaultID)
        if parts.count > 1, let sysID = AudioDeviceID(parts[1]) {
            _ = devices.setDefaultSystemOutput(sysID)
        }
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
