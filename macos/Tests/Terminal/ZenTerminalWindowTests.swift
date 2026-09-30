import Testing
@testable import Ghostty

@Suite
struct ZenTerminalWindowTests {
    @Test func cornerClearanceWithDefaultPadding() {
        // 16pt corners with the default 2pt horizontal padding:
        // 16 - sqrt(16² - 14²) ≈ 8.25, plus 1pt margin, rounded up.
        #expect(ZenTerminalWindow.cornerClearance(radius: 16, horizontalPadding: 2) == 10)
    }

    @Test func cornerClearanceWithoutPadding() {
        // Content at the very edge needs the full radius plus the margin.
        #expect(ZenTerminalWindow.cornerClearance(radius: 16, horizontalPadding: 0) == 17)
    }

    @Test func cornerClearanceWithPaddingPastCorner() {
        // Content that starts beyond the corner curve is never clipped.
        #expect(ZenTerminalWindow.cornerClearance(radius: 16, horizontalPadding: 16) == 0)
        #expect(ZenTerminalWindow.cornerClearance(radius: 16, horizontalPadding: 20) == 0)
    }

    @Test func cornerClearanceWithoutRoundedCorners() {
        #expect(ZenTerminalWindow.cornerClearance(radius: 0, horizontalPadding: 2) == 0)
    }
}
