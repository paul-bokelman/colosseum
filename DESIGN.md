# Colosseum Design Language

Colosseum follows Are.na's design language. This document is the source of truth for
every UI/UX decision in the app. When adding or editing UI, conform to it — or change
this document first and say why.

The token values below are lifted from Are.na's production stylesheet (dark theme) and
translated to SwiftUI. Where a value had to be adapted for macOS, the deviation is
called out explicitly under **macOS deviation**.

---

## 1. Principles

1. **The content is the interface.** Chrome is near-invisible: black ground, hairline
   rules, one weight of text. Nothing competes with an image.
2. **Flat, not layered.** No drop shadows on ordinary surfaces, no gradients, no
   translucency effects, no depth simulation. Separation comes from a 1px rule.
3. **Rectangles.** Media is square-cornered and edge-to-edge. Only controls get a 3pt
   radius.
4. **Two weights, one family.** Regular and bold. Hierarchy comes from size and colour,
   never from a third weight.
5. **Restraint with colour.** Greyscale by default. Colour is semantic only — focus,
   alert, tags — never decorative.
6. **Motion is a fade.** Things appear and disappear. They do not slide, spring,
   bounce, or scale noticeably.
7. **Keyboard-first.** Every action reachable by mouse has a key path. Escape always
   dismisses exactly one layer and never falls through.
8. **Density over comfort.** This is a tool for looking at a lot of things at once.
   Prefer the tighter of two spacings.

---

## 2. Colour

Are.na's dark theme, verbatim. Colosseum is dark-only; there is no light theme.

### 2.1 Greyscale ramp

| Token | Hex | Role |
| --- | --- | --- |
| `gray0` | `#000000` | Window / canvas background |
| `gray1` | `#1A1A1A` | Surface: fills, rows, inputs, unselected cells |
| `gray2` | `#333333` | Default border, dividers, elevated surface |
| `gray3` | `#4F4F4F` | Strong border, hover border, disabled foreground |
| `gray4` | `#696969` | Tertiary text: counts, timestamps, placeholders |
| `gray5` | `#B2B2B2` | Secondary text: metadata, captions, descriptions |
| `gray6` | `#E5E5E5` | Interactive text: links, buttons, active affordances |
| `gray7` | `#FFFFFF` | Primary text: titles, body, selected state |

The ramp is not decorative — each step is a legibility tier. Never invent an
intermediate value and never use `Color.white.opacity(_:)` to fake one. Opacity over
black produces a different colour than the ramp and drifts as backgrounds change.

### 2.2 Semantic colour

| Token | Hex | Use |
| --- | --- | --- |
| `focus` | `#5E6DEE` | Focus ring on inputs and focusable controls. Nothing else. |
| `alert` | `#FF7A30` | Remote / Are.na origin, destructive confirmation, error text |
| `notification` | `#AC7556` | Unread and pending indicators |
| `public` | `#98DC89` | Public / open state |
| `private` | `#EB6864` | Private / closed state |

Tag colours are generated (see `TagColor`) and are the single sanctioned exception to
the greyscale rule.

### 2.3 Overlays

| Token | Value | Use |
| --- | --- | --- |
| `scrim` | `#000000` @ 50% | Behind modal overlays |
| `backgroundHeavy` | `#000000` @ 95% | Floating bars over media |
| `backgroundLight` | `#1A1A1A` @ 60% | Hover affordances over media |

### 2.4 Swift

```swift
enum ColosseumTheme {
    static let gray0 = Color(hex: 0x000000)   // canvas
    static let gray1 = Color(hex: 0x1A1A1A)   // surface
    static let gray2 = Color(hex: 0x333333)   // border
    static let gray3 = Color(hex: 0x4F4F4F)   // borderStrong
    static let gray4 = Color(hex: 0x696969)   // tertiaryText
    static let gray5 = Color(hex: 0xB2B2B2)   // secondaryText
    static let gray6 = Color(hex: 0xE5E5E5)   // linkText
    static let gray7 = Color(hex: 0xFFFFFF)   // primaryText
}
```

Semantic aliases (`canvas`, `surface`, `border`, `primaryText`, …) must resolve to a
ramp token. Call sites use the alias, never the raw hex.

---

## 3. Typography

### 3.1 Family

Are.na ships `areal`, a Helvetica/Arial-class neo-grotesque, with `Arial, Helvetica`
as fallback. It uses one family for sans and mono.

**macOS deviation:** use the system font (SF Pro). It is the closest available
grotesque, renders correctly at small sizes on all displays, and keeps the app native.
Do not ship a webfont. Do not use a serif anywhere — Are.na reserves Times for block
body text in a context Colosseum does not have.

Monospace (`.monospaced`) is permitted only for keyboard-shortcut hints and byte/ID
values.

### 3.2 Scale

Are.na's ramp, rounded to whole points.

| Step | Size | Use |
| --- | --- | --- |
| `0` | 11 | Dense metadata only — grid cell captions, shortcut hints, byte counts |
| `1` | 12 | Captions, counts, secondary labels — the default small text |
| `2` | 14 | Body, list rows, buttons — the workhorse |
| `3` | 16 | Emphasised body, overlay titles |
| `4` | 19 | Section headings |
| `5` | 24 | Board titles |
| `6` | 28 | Page titles |
| `7` | 32 | Display |
| `8` | 40 | Display |
| `9` | 48 | Display |

Steps 1 and 2 carry ~90% of the interface. Anything above step 5 is a deliberate
statement and should be rare.

**macOS deviation:** Are.na's smallest step is 12.5px against a 16px web base. Step `0`
(11pt) is added because a native Mac app renders denser than a web page and grid-cell
metadata does not survive at 12pt without taller cells. It is a floor, not a default —
reach for step `1` first, and use `0` only where the layout genuinely cannot give the
text more room.

**Nothing below 11pt.** If text needs to be smaller to fit, the layout is wrong.

Do not use SwiftUI's semantic fonts (`.caption`, `.body`, `.title2`, …). They resolve
to macOS sizes that are not on this scale and drift with system settings. Always spell
out `.system(size:weight:)`.

### 3.3 Weight

Two weights only: `.regular` and `.bold`.

- `.regular` — everything.
- `.bold` — buttons, active tabs, selected rows, section labels, the one word that
  matters.

`.light`, `.medium`, `.semibold`, and `.heavy` are not part of the language. `.light`
in particular (used today for large glyphs) reads as a different typeface at size.

### 3.4 Line height

| Context | Multiplier | SwiftUI |
| --- | --- | --- |
| Body / notes | 1.45 | `.lineSpacing(size * 0.45)` |
| Titles, headings | 1.25 | `.lineSpacing(size * 0.25)` |
| Single-line rows | 1.0 | default |

No letter-spacing adjustments. No all-caps.

---

## 4. Space

Are.na's scale, verbatim. It is a **5pt** grid, not 8pt.

| Step | Value | Typical use |
| --- | --- | --- |
| `nudge` | 2 | Optical correction only |
| `1` | 5 | Icon-to-label, inline gaps |
| `2` | 10 | Inside controls, between list rows |
| `3` | 15 | Grid gutter, inside cards, control padding |
| `4` | 20 | Panel padding, section gaps |
| `5` | 25 | Between groups |
| `6` | 35 | Between sections |
| `7` | 45 | Window insets |
| `8` | 65 | Major separation |
| `9`–`11` | 80 / 100 / 130 | Page-level rhythm |

Every `padding`, `spacing`, gap, and inset must come from this scale. `4`, `8`, `12`,
`16`, `24` are **not** on the scale — the nearest legal values are `5`, `10`, `15`,
`20`, `25`.

The one exception is `nudge` (2pt) for optical alignment, which must be commented.

---

## 5. Shape and stroke

- **Border radius `0`** — media, thumbnails, grid cells, list rows, panels, dividers.
- **Border radius `3`** — buttons, inputs, pills, tags, segmented controls.
- **Border radius `50%`** — avatars only.

Every border is exactly **1pt**. There is no 0.5pt hairline. Weight differences are
expressed with the ramp (`gray2` → `gray3`), not thickness.

Selection on a list row is a `gray7` 1pt border plus a `gray1` fill — not a glow, not a
thicker stroke, not a coloured ring.

### 5.1 Grid cell borders — sanctioned exception

Are.na has no equivalent to Colosseum's tags, so this part of the language is ours.
Grid cells are the one place thickness carries meaning, and the widths are fixed:

| State | Width | Colour |
| --- | --- | --- |
| Untagged | 1 | `gray2` |
| Tagged | 3 | Segmented, one arc per tag (`TagColor`) |
| Keyboard-focused | 2 | `gray7` @ 85%, drawn outside the cell with a 3pt gap |

These three values are the complete exception. They live in `ColosseumTheme`
(`taggedBorderWidth`, `selectionRingWidth`, `selectionRingGap`) and may not be
reproduced with literals elsewhere. No other border in the app is thicker than 1pt.

**Shadows:** one shadow exists, `0 0 20px rgba(255,255,255,0.10)`, and only for
elements floating over media. Modal panels sit on a scrim and take no shadow.

---

## 6. Controls

### 6.1 Buttons

| Size | Height | Horizontal padding | Font |
| --- | --- | --- | --- |
| `sm` | 24 | 10 | 12 bold |
| `md` | 34 | 15 | 14 bold |
| `icon` | 34 × 34 | — | 12 |
| `fill` | 34, full width | 20 | 14 bold |

**macOS deviation:** Are.na's icon button is 24 square. Ours matches the `md` height so
icon and text buttons sit level in a shared action row.

Labels never wrap. A button is `nowrap` and does not shrink; if a row cannot fit its
buttons, the row wraps or reflows — the label does not.

Default: `gray1` background, `gray6` label, 1pt transparent border, radius 3.
Primary: inverted — `gray6` background, `gray0` label.
Hover: border becomes `gray3`. Pressed: 75% opacity. Disabled: `gray3` label, no
background change.

Every button uses `.pointingHandCursor()`.

### 6.2 Inputs

Height 34 (`md`) or 46 (prominent search). `gray1` background, 1pt `gray2` border,
radius 3, 15pt horizontal padding, 14pt regular text, `gray4` placeholder.

Focused: border becomes `focus` (`#5E6DEE`), still 1pt. Never use the system focus
ring; call `.focusEffectDisabled()`.

### 6.3 Rows

Height 52 for content rows, 34 for dense lists. `gray1` background, 15pt horizontal
padding, 10pt vertical gap between rows in a stack — or a 1pt `gray2` bottom rule with
no gap. Pick one per list; never both.

### 6.4 Tabs

Text-only, 14 bold. Active: `gray7` label with a 1pt `gray7` underline. Inactive:
`gray5`, no underline. Underline spans the label, not the container.

---

## 7. Layout

- Grid gutter: 15 (`space-3`).
- Window content inset: 25 (`space-5`).
- Panel padding: 20 (`space-4`).
- Sidebar width: 320.
- Modal panel width: 460. Height fixed, never content-sized — a jumping panel is worse
  than empty space.
- Grid cells are square (`aspectRatio(1, contentMode: .fit)`), regardless of media
  aspect. Media letterboxes inside.

---

## 8. Motion

| Token | Duration | Curve | Use |
| --- | --- | --- | --- |
| `soft` | 100ms | `easeOut` | Hover, toggle, state flips |
| `standard` | 120ms | `easeOut` | Content swaps, media reveal |
| `overlay` | 140ms | `easeOut` | Modal and overlay presentation |

**macOS deviation:** Are.na runs 100/200/250ms. Colosseum is faster because it is a
local app with no network latency to mask — nothing here is ever waiting on a request,
so a 250ms presentation reads as lag rather than as polish. The curve (`easeOut`) and
the properties that may animate are unchanged.

Only `opacity` and `background-color` animate. Transforms are limited to a
scale-from-`0.99` on overlay insert. Nothing translates, springs, or bounces.

Removal animations are always plain opacity and never longer than insertion.

No animation may run on a list as its contents change — wrap data-driven updates in
`.transaction { $0.animation = nil }`.

---

## 9. Interaction

### 9.1 Escape

Escape dismisses exactly one layer and **must not** reach the layer beneath. Overlays
own the key event and consume it (`KeyNavMonitor` returns `nil`); host views guard
their escape handlers on the presented flag as a backstop.

### 9.2 Modal overlays

In-window, not `.sheet`. Scrim at `#000` 50%, click-through-to-dismiss, `esc` to
dismiss, and a `✕` in the top-right of the panel. All three must work.

While an overlay is up, ancestor bare-key shortcuts are disabled
(`OverlayPresentation`).

### 9.3 Keyboard

`↑ ↓` moves selection, `↩` activates, `tab` moves focus, `esc` dismisses. Selection
must be visible before it can be activated, and the selected row scrolls into view.

### 9.4 Cursor

Pointing hand on every clickable element. Default arrow on everything else. No
`crosshair`, no `grab`.

### 9.5 Empty and error states

A 1pt `gray2` bordered box, 52 tall, `info.circle` glyph in `gray5`, 14pt `gray7`
label. Never a bare centred sentence floating in space. Errors use `alert` for the
glyph only; the text stays `gray5`.

---

## 10. Writing

- Sentence case everywhere. Never Title Case, never ALL CAPS.
- Curly quotes in user-facing strings: `Create new board “test”`.
- Ellipsis is the character `…`, never three periods.
- No exclamation marks. No "Oops". No emoji.
- Buttons are verbs: `Connect`, `Create`, `Import`. Not `OK`, not `Submit`.
- Counts are bare numerals next to the noun they modify: `137`, not `137 blocks`, when
  context makes the noun obvious.

---

## 11. Checklist

Before shipping a UI change:

- [ ] Every colour is a ramp or semantic token — no `Color.white.opacity(_:)`
- [ ] Every spacing value is on the 5pt scale
- [ ] Every font size is on the type scale, ≥ 11pt, spelled out — no `.caption`/`.body`
- [ ] Only `.regular` and `.bold`
- [ ] Borders are 1pt; radius is 0 or 3 — grid cells per §5.1 are the only exception
- [ ] Animations come from `ColosseumMotion`, opacity-only, `easeOut`
- [ ] Clickable elements have `.pointingHandCursor()`
- [ ] `esc` dismisses one layer and does not fall through
- [ ] Keyboard path exists and selection is visible
