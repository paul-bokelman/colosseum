![gh-banner](Resources/gh-banner.png)

# Colosseum

A private arena for the things you collect.

Boards. Blocks. Connections.  
Nothing leaves the machine.

[Download for macOS](https://github.com/paul-bokelman/colosseum/releases/latest/download/Colosseum-1.10.0-macos.zip)

## What it is

Colosseum is a **local-first macOS app** for collecting images, video, links, and text into boards — like a private mood board or Are.na-style channel, but fully offline. Media and metadata stay on your Mac under Application Support. There is no account, no cloud sync, and no website.

Built with Swift, SwiftUI, and SwiftData. Requires **macOS 14+**.

## Features

- **Boards** — organize collections; nest boards inside boards
- **Blocks** — images, video, audio, links, text, and Are.na channel previews
- **Connections** — attach blocks (and nested boards) to boards with notes and tags
- **Inline capture** — the first cell of every board is the input: drop, choose, paste, or type, then ⌘↩
- **Menu bar capture** — drop URLs, paste images/files, or resolve links without opening the main window
- **Are.na import** — pull a public Are.na channel into a local board
- **Search & tags** — find blocks and annotate with tagged notes
- **Local media library** — files copied into your Colosseum store; nothing is uploaded

## Who it’s for

People who want an **offline mood board**, **personal media library**, or **Are.na alternative** that never phones home — researchers, designers, writers, and anyone collecting reference material privately on a Mac.

## Install

1. Download the latest [macOS zip from Releases](https://github.com/paul-bokelman/colosseum/releases/latest)
2. Unzip and open `Colosseum.app`
3. If Gatekeeper blocks it: System Settings → Privacy & Security → Open Anyway

Or build from source:

```bash
swift build -c release
# or open Package.swift / build the app target in Xcode
```

## FAQ

**Is there a web app or sync?**  
No. Colosseum is Mac-only and local-only. Data stays on your machine.

**How is this different from Are.na?**  
Similar board/block vocabulary and you can import Are.na channels, but Colosseum does not host or sync content. Your library never leaves the Mac.

**Where is data stored?**  
In your user Application Support directory under `Colosseum` (SwiftData store + a local Media folder).

**What can I add?**  
Images, video, audio, links, plain text, and Are.na channel references — via paste, file import, URL resolve, or the menu bar capture UI.

## License

[MIT](LICENSE)
