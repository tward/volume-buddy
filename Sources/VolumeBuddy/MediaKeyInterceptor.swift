import AppKit
import CoreGraphics
import Foundation

enum MediaKey: Int {
    case soundUp = 0
    case soundDown = 1
    case mute = 7
}

final class MediaKeyInterceptor {
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMute: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?

    // NX_SYSDEFINED = 14
    private static let systemDefinedType = CGEventType(rawValue: 14)!

    func start() {
        let mask: CGEventMask = 1 << Self.systemDefinedType.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
                return interceptor.handleEvent(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[MediaKeyInterceptor] Failed to create event tap — Input Monitoring permission needed")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Health check: re-enable tap if macOS disabled it
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let tap = self?.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.type == Self.systemDefinedType else {
            return Unmanaged.passUnretained(event)
        }

        // Convert to NSEvent to extract media key data
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let flags = data1 & 0x0000FFFF
        let isKeyDown = (flags & 0x0A00) == 0x0A00

        guard let key = MediaKey(rawValue: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // Consume both key-down and key-up for our keys
        guard isKeyDown else { return nil }

        switch key {
        case .soundUp: onVolumeUp?()
        case .soundDown: onVolumeDown?()
        case .mute: onMute?()
        }

        return nil
    }
}
