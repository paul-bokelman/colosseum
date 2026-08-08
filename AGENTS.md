# AGENTS.md

Colosseum — a local-first macOS app for collecting images, video, links, and text into
boards. Swift 5.9, SwiftUI, SwiftData, macOS 14+. No network except Are.na import.

## Design

**[DESIGN.md](DESIGN.md) is mandatory reading before any UI or UX change.** It defines
the colour ramp, type scale, 5pt spacing scale, control specs, motion, and interaction
rules. The app follows Are.na's design language; do not introduce new tokens, weights,
radii, or animation curves without amending that document first.

## Build and run

```bash
swift build                      # debug
swift build -c release           # release
./Scripts/package-app.sh         # universal build, bundle, install to /Applications
./Scripts/package-app.sh --no-install
```

To test a change locally: run the packaging script, then `pkill -x Colosseum && open -a Colosseum`.

## Layout

```
Sources/Colosseum/
  ColosseumApp.swift     App entry, menu commands
  AppDelegate.swift      Menu bar capture, window lifecycle
  Models/                Board, Block, Connection, BlockKind (SwiftData)
  Services/              Import, Are.na, media library, thumbnails, tags
  Theme/                 ColosseumTheme (tokens), ColosseumMotion (animation)
  Views/                 All SwiftUI
```

## Conventions

- **Tokens, not literals.** Colours come from `ColosseumTheme`, animations from
  `ColosseumMotion`. A raw hex or a bare `Animation` in a view is a bug.
- **Keyboard handling.** `KeyNavMonitor` is an `NSEvent` local monitor with a
  per-window stack; the topmost installed monitor wins. Install in `onAppear`, remove
  in `onDisappear`. Consume events by returning `nil` so they never reach SwiftUI.
- **Overlays.** Use `modalOverlay(isPresented:)`, not `.sheet`. Push/pop
  `OverlayPresentation` so ancestor bare-key shortcuts get disabled.
- **SwiftData.** Mutations go through `Services/ImportService.swift`; bump
  `board.updatedAt` on any change that affects a board's contents.
- **Comments** explain why, not what, and only where the reason is non-obvious.

## Testing

There is no test target. Verify by building, packaging, and exercising the affected
flow by both mouse and keyboard.
