import AppKit
import SwiftUI

/// Compact caret-anchored tag autocomplete panel (AppKit, matches TagAssignPopover chrome).
final class TagSuggestOverlay {
    enum Item: Equatable {
        /// Existing board tag, with how many items currently use it.
        case tag(String, count: Int)
        /// Typed token not yet confirmed — shown with a small `new` pill until Enter/Space.
        case newTag(String)

        var tagName: String {
            switch self {
            case .tag(let tag, _), .newTag(let tag):
                return tag
            }
        }
    }

    private var panel: NSPanel?
    private var table: SuggestTable?
    private(set) var items: [Item] = []
    private(set) var selectedIndex = 0
    private var escapeMonitor: Any?
    private var isAnimatingOut = false
    private var anchorPoint: NSPoint = .zero
    var onSelect: ((Item) -> Void)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool {
        guard let panel, !isAnimatingOut else { return false }
        return panel.isVisible && panel.alphaValue > 0.01
    }

    func show(items: [Item], selectedIndex: Int, screenPoint: NSPoint) {
        if isAnimatingOut {
            panel?.alphaValue = 0
            panel?.orderOut(nil)
            isAnimatingOut = false
        }
        self.items = items
        self.selectedIndex = clampedSelection(selectedIndex)
        self.anchorPoint = screenPoint
        ensurePanel()
        table?.reload(items: items, selectedIndex: self.selectedIndex, animated: false)
        let frame = frame(for: items.count, at: screenPoint)
        guard let panel else { return }

        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFront(nil)
        installEscapeMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func update(items: [Item], selectedIndex: Int, screenPoint: NSPoint) {
        guard isVisible else {
            show(items: items, selectedIndex: selectedIndex, screenPoint: screenPoint)
            return
        }
        let countChanged = items.count != self.items.count
        self.items = items
        self.selectedIndex = clampedSelection(selectedIndex)
        self.anchorPoint = screenPoint
        table?.reload(items: items, selectedIndex: self.selectedIndex, animated: countChanged)
        let frame = frame(for: items.count, at: screenPoint)
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = (selectedIndex + delta + items.count) % items.count
        selectedIndex = next
        table?.setSelectedIndex(next)
    }

    func acceptSelection() {
        guard items.indices.contains(selectedIndex) else {
            hide()
            return
        }
        let item = items[selectedIndex]
        hide()
        onSelect?(item)
    }

    func hide() {
        removeEscapeMonitor()
        guard let panel, panel.isVisible, !isAnimatingOut else {
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            items = []
            selectedIndex = 0
            return
        }
        isAnimatingOut = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
            self.isAnimatingOut = false
            self.items = []
            self.selectedIndex = 0
        })
    }

    private func clampedSelection(_ index: Int) -> Int {
        min(max(0, index), max(items.count - 1, 0))
    }

    private func ensurePanel() {
        if panel != nil { return }

        let table = SuggestTable()
        table.onActivate = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.selectedIndex = index
            self.acceptSelection()
        }
        table.onHover = { [weak self] index in
            guard let self else { return }
            self.selectedIndex = index
            self.table?.setSelectedIndex(index)
        }
        self.table = table

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = table
        self.panel = panel
    }

    private func frame(for itemCount: Int, at screenPoint: NSPoint) -> NSRect {
        let size = SuggestTable.fittingSize(forCount: max(itemCount, 1))
        var origin = NSPoint(
            x: screenPoint.x,
            y: screenPoint.y - size.height - 6
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX {
                origin.x = visible.maxX - size.width - 4
            }
            if origin.x < visible.minX {
                origin.x = visible.minX + 4
            }
            if origin.y < visible.minY {
                origin.y = screenPoint.y + 4
            }
        }
        return NSRect(origin: origin, size: size)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            self.hide()
            self.onDismiss?()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}

// MARK: - Table

private final class SuggestTable: NSView {
    var onActivate: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    private var items: [TagSuggestOverlay.Item] = []
    private var selectedIndex = 0
    private var rowButtons: [SuggestRowButton] = []

    private static let rowHeight: CGFloat = 28
    private static let hPad: CGFloat = 10
    private static let vPad: CGFloat = 6
    private static let width: CGFloat = 232

    static func fittingSize(forCount count: Int) -> CGSize {
        let rows = max(count, 1)
        return CGSize(
            width: width,
            height: vPad * 2 + CGFloat(rows) * rowHeight
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(ColosseumTheme.surface).cgColor
        layer?.borderColor = NSColor(ColosseumTheme.border).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 0
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(items: [TagSuggestOverlay.Item], selectedIndex: Int, animated: Bool) {
        self.items = items
        self.selectedIndex = selectedIndex

        let apply = { [weak self] in
            guard let self else { return }
            self.rowButtons.forEach { $0.removeFromSuperview() }
            self.rowButtons = []

            for (index, item) in items.enumerated() {
                let button = SuggestRowButton(item: item)
                button.target = self
                button.action = #selector(self.rowClicked(_:))
                button.tag = index
                button.isSelectedRow = index == selectedIndex
                button.alphaValue = animated ? 0 : 1
                self.addSubview(button)
                self.rowButtons.append(button)
            }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.10
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for button in self.rowButtons {
                        button.animator().alphaValue = 1
                    }
                }
            }
        }

        if animated, !rowButtons.isEmpty {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.06
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                for button in rowButtons {
                    button.animator().alphaValue = 0
                }
            }, completionHandler: apply)
        } else {
            apply()
        }
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndex = index
        for (i, button) in rowButtons.enumerated() {
            button.isSelectedRow = i == index
        }
    }

    override func layout() {
        super.layout()
        var y = bounds.maxY - Self.vPad - Self.rowHeight
        for button in rowButtons {
            button.frame = NSRect(
                x: Self.hPad,
                y: y,
                width: bounds.width - Self.hPad * 2,
                height: Self.rowHeight
            )
            y -= Self.rowHeight
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = rowButtons.firstIndex(where: { $0.frame.contains(point) }) {
            onHover?(index)
        }
    }

    @objc private func rowClicked(_ sender: NSButton) {
        onActivate?(sender.tag)
    }
}

private final class SuggestRowButton: NSButton {
    var isSelectedRow = false {
        didSet { needsDisplay = true }
    }

    private let item: TagSuggestOverlay.Item

    init(item: TagSuggestOverlay.Item) {
        self.item = item
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        title = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedRow {
            ColosseumTheme.nsSurface.setFill()
            bounds.insetBy(dx: -4, dy: 1).fill()
        }

        let pillLabel: String?
        switch item {
        case .tag(_, let count):
            pillLabel = "\(count)"
        case .newTag:
            pillLabel = "new"
        }
        let pillReserve: CGFloat = pillLabel == nil ? 0 : 40

        let tagTitle = TagParser.displayLabel(item.tagName) as NSString
        let tagColor: NSColor = isSelectedRow
            ? TagColor.nsColor(for: item.tagName)
            : NSColor(ColosseumTheme.secondaryText)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelectedRow ? .medium : .regular),
            .foregroundColor: tagColor
        ]
        let titleSize = tagTitle.size(withAttributes: titleAttrs)
        let maxTitleWidth = max(0, bounds.width - 12 - pillReserve)
        let titleOrigin = CGPoint(
            x: 6,
            y: (bounds.height - titleSize.height) / 2
        )
        let titleRect = NSRect(
            origin: titleOrigin,
            size: CGSize(width: min(titleSize.width, maxTitleWidth), height: titleSize.height)
        )
        tagTitle.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)

        if let pillLabel {
            drawTrailingPill(pillLabel)
        }
    }

    /// Count / "new" pill pinned to the trailing edge of the row.
    private func drawTrailingPill(_ label: String) {
        let text = label as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(ColosseumTheme.tertiaryText)
        ]
        let textSize = text.size(withAttributes: attrs)
        let padX: CGFloat = 5
        let padY: CGFloat = 2
        let pillSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        let pillOrigin = CGPoint(
            x: bounds.width - pillSize.width - 4,
            y: (bounds.height - pillSize.height) / 2
        )
        let pillRect = NSRect(origin: pillOrigin, size: pillSize)

        NSColor(ColosseumTheme.elevated).setFill()
        pillRect.fill()
        NSColor(ColosseumTheme.border).setStroke()
        let border = NSBezierPath(rect: pillRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let textOrigin = CGPoint(
            x: pillRect.minX + padX,
            y: pillRect.minY + padY - 0.5
        )
        text.draw(at: textOrigin, withAttributes: attrs)
    }
}
