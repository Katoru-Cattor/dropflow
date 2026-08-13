import CoreGraphics
import Foundation

/// The shelf panel's height arithmetic, lifted verbatim out of
/// `ShelfWindowController.resizeForCurrentMode` so it can be asserted without a window server.
/// Two separate audit findings lived in these six lines — a per-row clipping error and an
/// early-out that compared the wrong dimension — and neither was visible to any test before.
public enum PanelMetrics {
    /// Height of the panel's *content* view for a shelf of `itemCount` items in `mode`.
    /// Width is deliberately not computed: the panel's real width is layout-determined, and the
    /// hard-coded width targets that used to live here never matched it, so the caller's
    /// "did anything change?" early-out never fired and every store change ran a no-op animation.
    public static func contentHeight(itemCount: Int, mode: ShelfDragMode) -> CGFloat {
        if itemCount == 0 {
            return 200
        }
        switch mode {
        case .simplify:
            let rows = max(1, Int(ceil(Double(min(itemCount, 12)) / 4.0)))
            let contentHeight = 76 + CGFloat(rows) * 58 + CGFloat(max(rows - 1, 0)) * 10 + 34
            return min(max(contentHeight, 188), 330)
        case .advance:
            let rows = max(1, min(itemCount, 8))
            // 74 must match the row's minimum height in ShelfRootView; 64 clipped the last row by
            // 10 pt per row.
            let contentHeight = 76 + CGFloat(rows) * 74 + CGFloat(max(rows - 1, 0)) * 8 + 24
            return min(max(contentHeight, 200), 440)
        }
    }
}
