import CoreGraphics

/// Display arithmetic for couch mode (spec C2b): games go full screen on the main display, the one at origin
/// (0, 0) in global coordinates, so making the TV main means shifting every display by the same amount.
public enum DisplayLayout {
    /// New origins, in `all`'s order, that make `target` the main display.
    public static func originsMakingMain(_ target: CGRect, all: [CGRect]) -> [CGPoint] {
        all.map { CGPoint(x: $0.origin.x - target.origin.x, y: $0.origin.y - target.origin.y) }
    }
}
