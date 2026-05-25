import AppKit
import CoreGraphics
import Foundation

/// Horizontal anchor along the bottom edge of the screen the user has
/// parked the pill at. Persisted per-display so a multi-monitor user can
/// have different positions on each screen.
enum PillAnchor: String, CaseIterable, Codable, Equatable {
    case left
    case center
    case right

    /// Human-facing label used in Settings ("Left" / "Center" / "Right").
    var label: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        }
    }
}

/// Persistence wrapper for the per-screen pill anchor. Keyed by the
/// system display UUID (`CGDisplayCreateUUIDFromDisplayID`), which is
/// stable across reboots for the same physical display.
///
/// The store has no main-actor requirement — reads and writes are pure
/// `UserDefaults` access — but the live store used by the app is
/// instantiated on the main actor by `PanelWindowController`.
struct PillPositionStore {
    static let defaultAnchor: PillAnchor = .center

    private static let keyPrefix = "co.milbo.hark.pillAnchor."
    private static let knownKeysKey = "co.milbo.hark.pillAnchor.knownScreens"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read / write

    func anchor(for screen: NSScreen) -> PillAnchor {
        guard let uuid = Self.uuid(for: screen) else { return Self.defaultAnchor }
        return anchor(forScreenUUID: uuid)
    }

    func setAnchor(_ anchor: PillAnchor, for screen: NSScreen) {
        guard let uuid = Self.uuid(for: screen) else { return }
        setAnchor(anchor, forScreenUUID: uuid)
    }

    /// Wipe every persisted anchor. Used by the "Reset all displays"
    /// settings button. Subsequent reads fall back to `defaultAnchor`.
    func resetAll() {
        for uuid in knownScreenUUIDs() {
            defaults.removeObject(forKey: Self.key(for: uuid))
        }
        defaults.removeObject(forKey: Self.knownKeysKey)
    }

    func reset(_ screen: NSScreen) {
        guard let uuid = Self.uuid(for: screen) else { return }
        defaults.removeObject(forKey: Self.key(for: uuid))
        var known = Set(knownScreenUUIDs())
        known.remove(uuid)
        defaults.set(Array(known), forKey: Self.knownKeysKey)
    }

    /// True iff at least one display has a stored anchor. Drives the
    /// "Reset all displays" disclosure visibility in Settings.
    var hasAnyStoredAnchor: Bool {
        !knownScreenUUIDs().isEmpty
    }

    // MARK: - UUID-keyed variants (testable without a real NSScreen)

    /// Internal seam used by tests so they don't have to fabricate an
    /// NSScreen — the live code path always derives a UUID from the
    /// screen first and then funnels through here.
    func anchor(forScreenUUID uuid: String) -> PillAnchor {
        guard
            let raw = defaults.string(forKey: Self.key(for: uuid)),
            let parsed = PillAnchor(rawValue: raw) else
        {
            return Self.defaultAnchor
        }
        return parsed
    }

    func setAnchor(_ anchor: PillAnchor, forScreenUUID uuid: String) {
        defaults.set(anchor.rawValue, forKey: Self.key(for: uuid))
        rememberScreen(uuid)
    }

    // MARK: - Helpers

    private static func key(for uuid: String) -> String {
        keyPrefix + uuid
    }

    private func knownScreenUUIDs() -> [String] {
        defaults.stringArray(forKey: Self.knownKeysKey) ?? []
    }

    private func rememberScreen(_ uuid: String) {
        var known = Set(knownScreenUUIDs())
        guard !known.contains(uuid) else { return }
        known.insert(uuid)
        defaults.set(Array(known), forKey: Self.knownKeysKey)
    }

    /// Resolve a stable UUID for the given screen. Returns nil if the
    /// display ID is missing or the system can't produce a UUID — both
    /// path-edge cases that should fall back to the default anchor.
    static func uuid(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard
            let raw = screen.deviceDescription[key] as? NSNumber else
        {
            return nil
        }
        let displayID = CGDirectDisplayID(raw.uint32Value)
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        let cfString = CFUUIDCreateString(nil, uuidRef)
        return cfString as String?
    }
}

/// Pure geometry: given a screen's visible frame and a panel width,
/// return the panel's bottom-left origin for the requested anchor.
///
/// Extracted out of `PanelWindowController` so it's testable in
/// isolation — no NSScreen / NSPanel needed.
enum PillPositionGeometry {
    /// Horizontal gap between the panel and the left / right edges of
    /// the visible frame for the `.left` / `.right` anchors. Center
    /// ignores this (the panel is mathematically centered).
    static let edgeInset: CGFloat = 24

    /// Vertical gap above the bottom of the visible frame (Dock area).
    /// Mirrors `PanelWindowController.bottomInset`.
    static let bottomInset: CGFloat = 22

    static func origin(
        for anchor: PillAnchor,
        visibleFrame: CGRect,
        panelWidth: CGFloat
    )
        -> CGPoint
    {
        let y = visibleFrame.minY + bottomInset
        let x: CGFloat = switch anchor {
        case .left:
            visibleFrame.minX + edgeInset
        case .center:
            visibleFrame.midX - panelWidth / 2
        case .right:
            visibleFrame.maxX - panelWidth - edgeInset
        }
        return CGPoint(x: x, y: y)
    }

    /// Clamp an arbitrary X origin so the panel never strays outside
    /// the visible frame horizontally. Used during drag so flinging
    /// past either edge feels like hitting a soft wall instead of
    /// vanishing the pill off-screen.
    static func clampX(
        _ x: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat
    )
        -> CGFloat
    {
        let minX = visibleFrame.minX + edgeInset
        let maxX = visibleFrame.maxX - panelWidth - edgeInset
        guard minX <= maxX else { return minX }
        return min(max(x, minX), maxX)
    }

    /// Pick the closest anchor to the given panel-origin X. Used on
    /// drag release to decide where to settle.
    static func nearestAnchor(
        toX x: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat
    )
        -> PillAnchor
    {
        var best: (anchor: PillAnchor, distance: CGFloat) = (.center, .infinity)
        for anchor in PillAnchor.allCases {
            let candidate = origin(for: anchor, visibleFrame: visibleFrame, panelWidth: panelWidth).x
            let distance = abs(candidate - x)
            if distance < best.distance {
                best = (anchor, distance)
            }
        }
        return best.anchor
    }

    /// Distance (in points) within which a live drag should snap to the
    /// nearest anchor. Tuned so the magnetic pull is felt without
    /// preventing fine placement near a non-anchor X.
    static let snapDistance: CGFloat = 50

    /// Apply snap-to-nearest-anchor if the clamped X is within
    /// `snapDistance` of any anchor; otherwise return the clamped X
    /// unchanged. Used by the drag handler for the live magnetic pull.
    static func snapped(
        x: CGFloat,
        visibleFrame: CGRect,
        panelWidth: CGFloat
    )
        -> CGFloat
    {
        let clamped = clampX(x, visibleFrame: visibleFrame, panelWidth: panelWidth)
        for anchor in PillAnchor.allCases {
            let candidate = origin(for: anchor, visibleFrame: visibleFrame, panelWidth: panelWidth).x
            if abs(candidate - clamped) <= snapDistance {
                return candidate
            }
        }
        return clamped
    }
}
