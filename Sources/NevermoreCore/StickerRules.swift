import Foundation

/// The physics and bookkeeping of reactions handled as stickers: when a
/// press becomes a drag, how a carried sticker leans, where a thrown one
/// comes to rest, and what changed in a message's reactions.
public enum StickerRules {
    /// A press that moves less than this is a click.
    public static let dragThreshold: CGFloat = 6
    /// Releasing faster than this throws the sticker.
    public static let flingSpeed: CGFloat = 900
    /// A thrown sticker travels this many seconds of its release velocity
    /// before friction stops it.
    public static let flingGlide: CGFloat = 0.22
    /// The longest throw, so a wild flick stays inside a large window.
    public static let flingReach: CGFloat = 700
    /// A chip dragged farther than this comes off.
    public static let peelDistance: CGFloat = 24
    public static let maximumTilt: CGFloat = 12 * .pi / 180
    /// Horizontal speed at which a carried sticker leans all the way.
    public static let tiltSpeed: CGFloat = 1400

    public static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }

    /// A carried sticker leans against its motion, like paper held by one
    /// corner. Radians, counterclockwise in an unflipped view: moving
    /// right leans the top left.
    public static func tilt(horizontalVelocity: CGFloat) -> CGFloat {
        guard horizontalVelocity.isFinite else { return 0 }
        return max(-1, min(1, horizontalVelocity / tiltSpeed)) * maximumTilt
    }

    /// Where a sticker released at `point` with `velocity` stops, or nil
    /// when the release was too slow to be a throw.
    public static func rest(from point: CGPoint, velocity: CGVector) -> CGPoint? {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed.isFinite, speed > flingSpeed else { return nil }
        let reach = min(flingReach, speed * flingGlide)
        return CGPoint(x: point.x + velocity.dx / speed * reach, y: point.y + velocity.dy / speed * reach)
    }

    /// Position of a thrown sticker at `progress` (0...1) of its glide:
    /// fast at first, then slowed by friction.
    public static func glide(from start: CGPoint, to rest: CGPoint, progress: CGFloat) -> CGPoint {
        let clamped = max(0, min(1, progress))
        let eased = 1 - pow(1 - clamped, 3)
        return CGPoint(x: start.x + (rest.x - start.x) * eased, y: start.y + (rest.y - start.y) * eased)
    }

    public enum ChipChange: Equatable, Sendable {
        /// A reaction nobody had given before.
        case added(label: String, count: Int, mine: Bool)
        /// The count of an existing reaction changed.
        case counted(label: String, from: Int, to: Int)
        /// The last person took the reaction back.
        case removed(label: String)
    }

    /// What changed between two renders of one message's reactions.
    public static func changes(from old: [ReactionChip], to new: [ReactionChip]) -> [ChipChange] {
        var result: [ChipChange] = []
        let before = Dictionary(old.map { ($0.label, $0) }) { first, _ in first }
        let after = Dictionary(new.map { ($0.label, $0) }) { first, _ in first }
        for chip in new {
            guard let previous = before[chip.label] else { result.append(.added(label: chip.label, count: chip.count, mine: chip.includesCurrentUser)); continue }
            if previous.count != chip.count { result.append(.counted(label: chip.label, from: previous.count, to: chip.count)) }
        }
        for chip in old where after[chip.label] == nil { result.append(.removed(label: chip.label)) }
        return result
    }
}
