import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// See DESIGN.md. Values are Are.na's dark theme, verbatim.
enum ColosseumTheme {

    // MARK: - Greyscale ramp

    /// Each step is a legibility tier, not a shade. Never interpolate between them and
    /// never fake one with `Color.white.opacity(_:)` — opacity over a non-black
    /// background lands somewhere else entirely.
    static let gray0 = Color(hex: 0x000000)
    static let gray1 = Color(hex: 0x1A1A1A)
    static let gray2 = Color(hex: 0x333333)
    static let gray3 = Color(hex: 0x4F4F4F)
    static let gray4 = Color(hex: 0x696969)
    static let gray5 = Color(hex: 0xB2B2B2)
    static let gray6 = Color(hex: 0xE5E5E5)
    static let gray7 = Color(hex: 0xFFFFFF)

    // MARK: - Surfaces

    static let canvas = gray0
    static let surface = gray1
    static let elevated = gray2
    static let border = gray2
    static let borderStrong = gray3

    // MARK: - Text

    static let primaryText = gray7
    /// Links, buttons, active affordances.
    static let linkText = gray6
    static let secondaryText = gray5
    static let tertiaryText = gray4
    static let disabledText = gray3

    // MARK: - Semantic

    /// Focus ring on inputs and focusable controls. Nothing else.
    static let focus = Color(hex: 0x5E6DEE)
    /// Remote / Are.na origin, destructive confirmation, error glyphs.
    static let alert = Color(hex: 0xFF7A30)
    static let notification = Color(hex: 0xAC7556)
    static let publicState = Color(hex: 0x98DC89)
    static let privateState = Color(hex: 0xEB6864)

    /// Titles for remote / Are.na boards.
    static let remoteBoardTitle = alert

    // MARK: - Overlays

    static let scrim = Color.black.opacity(0.5)
    /// Floating bars over media.
    static let backgroundHeavy = Color.black.opacity(0.95)
    /// Hover affordances over media.
    static let backgroundLight = gray1.opacity(0.6)
    /// Glyphs drawn directly on media, where the ramp has no ground to sit on.
    static let onMedia = Color.white.opacity(0.9)
    static let shimmerHighlight = Color.white.opacity(0.12)
    /// The only shadow in the app, and only for panels floating over media.
    static let floatShadow = Color.white.opacity(0.10)

    // MARK: - AppKit

    static let nsCanvas = NSColor.black
    static let nsPrimaryText = NSColor.white
    static let nsSurface = NSColor(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)

    // MARK: - Layout

    static let gridGap: CGFloat = Space.s3
    static let cellMin: CGFloat = 180
    static let sidebarWidth: CGFloat = 320
    static let panelWidth: CGFloat = 460

    // MARK: - Grid cell borders (DESIGN.md §5.1)

    /// Empty space between a cell's inner border and the focus selection ring.
    static let selectionRingGap: CGFloat = 3
    static let selectionRingWidth: CGFloat = 2
    /// Tag-colored cell borders (plain / untagged stay at 1).
    static let taggedBorderWidth: CGFloat = 3
    static let selectionRingColor = Color.white.opacity(0.85)
}

/// Are.na's 5pt space scale. Every padding, spacing, gap, and inset comes from here.
enum Space {
    /// Optical correction only — must be justified at the call site.
    static let nudge: CGFloat = 2
    static let s1: CGFloat = 5
    static let s2: CGFloat = 10
    static let s3: CGFloat = 15
    static let s4: CGFloat = 20
    static let s5: CGFloat = 25
    static let s6: CGFloat = 35
    static let s7: CGFloat = 45
    static let s8: CGFloat = 65
    static let s9: CGFloat = 80
    static let s10: CGFloat = 100
    static let s11: CGFloat = 130
}

/// Are.na's type ramp, rounded to whole points. Step 0 is a macOS addition; see DESIGN.md §3.2.
enum TypeScale {
    /// Dense metadata only.
    static let t0: CGFloat = 11
    static let t1: CGFloat = 12
    static let t2: CGFloat = 14
    static let t3: CGFloat = 16
    static let t4: CGFloat = 19
    static let t5: CGFloat = 24
    static let t6: CGFloat = 28
    static let t7: CGFloat = 32
    static let t8: CGFloat = 40
    static let t9: CGFloat = 48

    static let all: [CGFloat] = [t0, t1, t2, t3, t4, t5, t6, t7, t8, t9]

    /// Snaps a fluid, layout-derived size onto the nearest legal step.
    /// Fluid type is still type — it does not get to leave the scale.
    static func snap(_ size: CGFloat) -> CGFloat {
        all.min(by: { abs($0 - size) < abs($1 - size) }) ?? t2
    }

    /// Body / notes line height (1.45).
    static func bodyLineSpacing(_ size: CGFloat) -> CGFloat { size * 0.45 }
    /// Title line height (1.25).
    static func titleLineSpacing(_ size: CGFloat) -> CGFloat { size * 0.25 }
}

/// A segment in a board / remote breadcrumb path.
struct BoardPathSegment: Identifiable, Hashable {
    let id: String
    let title: String
}

extension View {
    func colosseumCanvas() -> some View {
        self.background(ColosseumTheme.canvas.ignoresSafeArea())
    }

    /// The single sanctioned shadow: panels that float over media and would
    /// otherwise dissolve into whatever image is behind them. Never on a scrimmed modal.
    func floatingPanelShadow() -> some View {
        self.shadow(color: ColosseumTheme.floatShadow, radius: 20)
    }
}
