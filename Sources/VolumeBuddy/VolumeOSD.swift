import AppKit
import Foundation
import os

final class VolumeOSD {
    // OSD image IDs (from private OSD.framework)
    private static let kOSDImageVolume: UInt32 = 3       // speaker with waves
    private static let kOSDImageMute: UInt32 = 4         // speaker with X

    private let osdManager: AnyObject?
    private let showImageSel: Selector

    static let shared = VolumeOSD()

    private init() {
        // Load OSD.framework at runtime
        let bundlePath = "/System/Library/PrivateFrameworks/OSD.framework"
        guard let bundle = Bundle(path: bundlePath), bundle.load() else {
            Logger(subsystem: "com.local.VolumeBuddy", category: "VolumeOSD")
                .error("Failed to load OSD.framework")
            osdManager = nil
            showImageSel = Selector(("_"))
            return
        }

        guard let managerClass = NSClassFromString("OSDManager") as? NSObject.Type else {
            Logger(subsystem: "com.local.VolumeBuddy", category: "VolumeOSD")
                .error("Failed to find OSDManager class")
            osdManager = nil
            showImageSel = Selector(("_"))
            return
        }

        let sharedSel = Selector(("sharedManager"))
        guard managerClass.responds(to: sharedSel) else {
            Logger(subsystem: "com.local.VolumeBuddy", category: "VolumeOSD")
                .error("OSDManager doesn't respond to sharedManager")
            osdManager = nil
            showImageSel = Selector(("_"))
            return
        }

        osdManager = managerClass.perform(sharedSel)?.takeUnretainedValue()
        showImageSel = Selector(("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"))
    }

    var available: Bool { osdManager != nil }

    /// Show the volume OSD overlay.
    /// - Parameters:
    ///   - volume: 0.0–1.0
    ///   - muted: whether to show the mute icon
    func show(volume: Float, muted: Bool) {
        guard let manager = osdManager else { return }

        let totalChiclets: UInt32 = 16
        let filledChiclets = muted ? UInt32(0) : UInt32(round(volume * Float(totalChiclets)))
        let imageID = muted ? Self.kOSDImageMute : Self.kOSDImageVolume
        let displayID = CGMainDisplayID()

        let obj = manager as! NSObject
        guard obj.responds(to: showImageSel) else { return }

        // Use NSInvocation equivalent: performSelector won't work with 7 args,
        // so use objc_msgSend via unsafeBitCast
        typealias ShowImageFunc = @convention(c) (
            AnyObject, Selector, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Bool
        ) -> Void

        let impl = unsafeBitCast(
            obj.method(for: showImageSel),
            to: ShowImageFunc.self
        )
        impl(obj, showImageSel, imageID, displayID, 0x1F4, 1500, filledChiclets, totalChiclets, false)
    }
}
