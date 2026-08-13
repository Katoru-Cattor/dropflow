import CoreGraphics
import Foundation
import Testing
@testable import DropFlowCore

/// The panel height arithmetic. Two audit findings lived in these six lines, and the first drop a
/// new user makes is what exposes them: a clipped last row, and a resize animation that ran on every
/// store change without changing anything.
@Suite
struct PanelMetricsTests {
    @Test("An empty shelf gets the fixed empty-state height", arguments: [ShelfDragMode.simplify, .advance])
    func emptyShelf(_ mode: ShelfDragMode) {
        #expect(PanelMetrics.contentHeight(itemCount: 0, mode: mode) == 200)
    }

    @Test("Simplify grid heights", arguments: [
        (1, CGFloat(188)),   // one row, floored at the 188 minimum
        (4, CGFloat(188)),   // still one row of four columns
        (5, CGFloat(236)),   // second row starts
        (8, CGFloat(236)),
        (9, CGFloat(304)),   // third row
        (12, CGFloat(304))
    ])
    func simplifyHeights(_ itemCount: Int, _ expected: CGFloat) {
        #expect(PanelMetrics.contentHeight(itemCount: itemCount, mode: .simplify) == expected)
    }

    @Test("Advance list heights", arguments: [
        (1, CGFloat(200)),   // floored at the 200 minimum
        (2, CGFloat(256)),
        (3, CGFloat(338)),
        (8, CGFloat(440))    // capped
    ])
    func advanceHeights(_ itemCount: Int, _ expected: CGFloat) {
        #expect(PanelMetrics.contentHeight(itemCount: itemCount, mode: .advance) == expected)
    }

    /// The clipping bug: the arithmetic used 64 pt per row while `ShelfRootView` gave each row a
    /// 74 pt minimum, so the panel came up 10 pt per row too short and the last row was cut off.
    /// Measuring the *stride* catches that without duplicating the whole formula.
    @Test("Advance rows are 74 pt tall plus 8 pt of spacing, matching the row view's minimum")
    func advanceRowStrideMatchesRowHeight() {
        let two = PanelMetrics.contentHeight(itemCount: 2, mode: .advance)
        let three = PanelMetrics.contentHeight(itemCount: 3, mode: .advance)
        #expect(three - two == 82, "74 pt row + 8 pt spacing; a stride of 72 is the 64 pt clipping bug")
    }

    @Test("Simplify rows are 58 pt tall plus 10 pt of spacing")
    func simplifyRowStride() {
        let one = PanelMetrics.contentHeight(itemCount: 5, mode: .simplify)
        let two = PanelMetrics.contentHeight(itemCount: 9, mode: .simplify)
        #expect(two - one == 68)
    }

    @Test("Height never shrinks as items are added", arguments: [ShelfDragMode.simplify, .advance])
    func monotonic(_ mode: ShelfDragMode) {
        let heights = (1...40).map { PanelMetrics.contentHeight(itemCount: $0, mode: mode) }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "the panel must not jump smaller mid-fill")
    }

    /// Both modes plateau, so no shelf size can produce a panel taller than the screen — the rest of
    /// the items are reached by scrolling.
    ///
    /// Note which limit actually binds in Simplify: the row count is computed from
    /// `min(itemCount, 12)`, which tops out at 3 rows / 304 pt, so the `min(…, 330)` clamp that
    /// follows it can never fire. Harmless, but it is dead arithmetic — asserting 304 here rather
    /// than 330 records that on purpose.
    @Test("Height plateaus once the shelf is full", arguments: [13, 50, 500, 10_000])
    func clampedAtTheTop(_ itemCount: Int) {
        #expect(PanelMetrics.contentHeight(itemCount: itemCount, mode: .simplify) == 304)
        #expect(PanelMetrics.contentHeight(itemCount: itemCount, mode: .advance) == 440)
    }

    @Test("The Simplify clamp of 330 pt is unreachable, because the 12-item cap binds first")
    func simplifyClampIsDeadArithmetic() {
        let tallest = (0...200).map { PanelMetrics.contentHeight(itemCount: $0, mode: .simplify) }.max()
        #expect(tallest == 304, "if this ever reaches 330 the item cap changed and the clamp became live")
    }

    // Deleted: a test that called contentHeight twice and asserted the two results matched. No
    // change to the app could make it fail — gutting contentHeight to `return 1` left it green while
    // 8 other tests went red. The resize early-out it claimed to cover lives in the executable
    // target and is never invoked from here; simplifyHeights/advanceHeights pin the exact values,
    // which is what actually protects that behaviour.

    @Test("A negative count cannot produce a negative height")
    func negativeCountIsSafe() {
        // Not reachable through the app, but the arithmetic must not return something a window
        // frame cannot take.
        #expect(PanelMetrics.contentHeight(itemCount: -1, mode: .simplify) >= 188)
        #expect(PanelMetrics.contentHeight(itemCount: -1, mode: .advance) >= 200)
    }
}
