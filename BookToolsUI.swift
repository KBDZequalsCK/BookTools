import AppKit

extension NSAppearance {
    var isBookToolsDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum BTTheme {
    static let cardRadius: CGFloat = 14

    static let cardFill = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 0.145, alpha: 1)
            : NSColor(calibratedWhite: 1.0, alpha: 0.94)
    }

    static let cardBorder = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.09)
            : NSColor(calibratedWhite: 0.0, alpha: 0.08)
    }

    static let dropFill = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.035)
            : NSColor(calibratedWhite: 0.0, alpha: 0.025)
    }

    static let dropBorder = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.16)
            : NSColor(calibratedWhite: 0.0, alpha: 0.16)
    }

    static let secondaryFill = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.075)
            : NSColor(calibratedWhite: 0.0, alpha: 0.045)
    }

    static let secondaryBorder = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.13)
            : NSColor(calibratedWhite: 0.0, alpha: 0.11)
    }

    static let ghostHover = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.07)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)
    }

    static let separator = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.08)
            : NSColor(calibratedWhite: 0.0, alpha: 0.08)
    }

    static let progressTrack = NSColor(name: nil) { appearance in
        appearance.isBookToolsDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.12)
            : NSColor(calibratedWhite: 0.0, alpha: 0.09)
    }
}

final class BTCardView: NSView {
    let stack = NSStackView()

    init(insets: NSEdgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: BTTheme.cardRadius, yRadius: BTTheme.cardRadius)
        BTTheme.cardFill.setFill()
        path.fill()
        BTTheme.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BTWellView: NSView {
    var fillColor: NSColor = BTTheme.dropFill {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat = 8 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BTSeparator: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        BTTheme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BTProgressBar: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let barHeight = min(6, bounds.height)
        let track = NSRect(
            x: 0,
            y: (bounds.height - barHeight) / 2,
            width: bounds.width,
            height: barHeight
        )
        BTTheme.progressTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let clamped = min(1, max(0, progress))
        guard clamped > 0.001 else { return }
        let fillWidth = max(barHeight, track.width * clamped)
        let fillRect = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: barHeight)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BTNumberBadge: NSView {
    init(number: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "\(number)")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .controlAccentColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class BTButton: NSButton {
    enum Style {
        case primary
        case secondary
        case accent
        case destructive
        case ghost
    }

    private let style: Style
    private let buttonHeight: CGFloat
    private let buttonFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let symbolImage: NSImage?
    private var displayTitle: String
    private var isHovering = false
    private var isPressing = false
    private var trackingAreaReference: NSTrackingArea?
    private let iconSize: CGFloat = 14
    private let iconGap: CGFloat = 6

    init(title: String, symbol: String? = nil, style: Style = .secondary, height: CGFloat = 32) {
        self.style = style
        self.buttonHeight = height
        self.displayTitle = title
        if let symbol,
           let baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.symbolImage = baseImage.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            )
        } else {
            self.symbolImage = nil
        }
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        font = buttonFont
        self.title = ""
        heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
        updateStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    func setTitleText(_ value: String) {
        displayTitle = value
        updateStyle()
        invalidateIntrinsicContentSize()
    }

    private var titleColor: NSColor {
        switch style {
        case .primary:
            return .white
        case .accent:
            return .controlAccentColor
        case .destructive:
            return .systemRed
        default:
            return .labelColor
        }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: buttonFont, .foregroundColor: titleColor]
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = (displayTitle as NSString).size(withAttributes: titleAttributes).width
        let iconWidth = symbolImage == nil ? 0 : iconSize + iconGap
        return NSSize(width: ceil(titleWidth + iconWidth) + 30, height: buttonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        guard !displayTitle.isEmpty else { return }

        let titleSize = (displayTitle as NSString).size(withAttributes: titleAttributes)
        let iconWidth = symbolImage == nil ? 0 : iconSize + iconGap
        let totalWidth = iconWidth + ceil(titleSize.width)
        var cursorX = (bounds.width - totalWidth) / 2

        if let symbolImage {
            let iconRect = NSRect(
                x: cursorX,
                y: bounds.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            symbolImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            cursorX += iconSize + iconGap
        }

        let titlePoint = NSPoint(
            x: cursorX,
            y: bounds.midY - titleSize.height / 2
        )
        (displayTitle as NSString).draw(at: titlePoint, withAttributes: titleAttributes)
    }

    private func drawBackground() {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        switch style {
        case .primary:
            let accent = NSColor.controlAccentColor
            let fill: NSColor
            if isPressing {
                fill = accent.blended(withFraction: 0.18, of: .black) ?? accent
            } else if isHovering {
                fill = accent.blended(withFraction: 0.10, of: .white) ?? accent
            } else {
                fill = accent
            }
            fill.setFill()
            path.fill()

        case .secondary:
            BTTheme.secondaryFill.setFill()
            path.fill()
            BTTheme.secondaryBorder.setStroke()
            path.lineWidth = 1
            path.stroke()

        case .accent:
            let accent = NSColor.controlAccentColor
            accent.withAlphaComponent(isHovering ? 0.22 : 0.14).setFill()
            path.fill()
            accent.withAlphaComponent(0.30).setStroke()
            path.lineWidth = 1
            path.stroke()

        case .destructive:
            if isHovering {
                NSColor.systemRed.withAlphaComponent(0.12).setFill()
                path.fill()
            }

        case .ghost:
            if isHovering {
                BTTheme.ghostHover.setFill()
                path.fill()
            }
        }
    }

    private func updateStyle() {
        alphaValue = isEnabled ? 1 : 0.42
        needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet {
            updateStyle()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressing = false
        needsDisplay = true
    }
}

protocol FileDropZoneDelegate: AnyObject {
    func dropZone(_ view: FileDropZoneView, received url: URL)
    func dropZoneWasDoubleClicked(_ view: FileDropZoneView)
}

final class FileDropZoneView: NSView {
    weak var delegate: FileDropZoneDelegate?

    let acceptedExtensions: Set<String>
    var isInteractionEnabled = true {
        didSet { updateAppearance() }
    }

    var titleText: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var subtitleText: String {
        get { subtitleLabel.stringValue }
        set { subtitleLabel.stringValue = newValue }
    }

    var iconName: String = "arrow.down.doc" {
        didSet { updateIcon() }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private var isHighlighted = false {
        didSet {
            needsDisplay = true
            updateAppearance()
        }
    }

    init(acceptedExtensions: Set<String>, title: String, subtitle: String) {
        self.acceptedExtensions = acceptedExtensions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("This app does not use storyboards")
    }

    private func setupView() {
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleLabel.stringValue)

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        updateIcon()

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])

        updateAppearance()
    }

    private func updateIcon() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private func updateAppearance() {
        iconView.contentTintColor = isHighlighted ? .controlAccentColor : .secondaryLabelColor
        alphaValue = isInteractionEnabled ? 1 : 0.5
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.11).setFill()
        } else {
            BTTheme.dropFill.setFill()
        }
        path.fill()

        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
        } else {
            BTTheme.dropBorder.setStroke()
        }
        path.lineWidth = isHighlighted ? 1.5 : 1
        let dash: [CGFloat] = isHighlighted ? [] : [5, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isInteractionEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isInteractionEnabled, firstSupportedURL(from: sender.draggingPasteboard) != nil else {
            return []
        }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard isInteractionEnabled, let url = firstSupportedURL(from: sender.draggingPasteboard) else {
            return false
        }
        delegate?.dropZone(self, received: url)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, isInteractionEnabled {
            delegate?.dropZoneWasDoubleClicked(self)
        }
        super.mouseDown(with: event)
    }

    private func firstSupportedURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { acceptedExtensions.contains($0.pathExtension.lowercased()) })
    }
}

enum BTUI {
    static func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = alignment
        return label
    }

    static func formLabel(_ text: String) -> NSTextField {
        let label = label(text, size: 12, weight: .medium, color: .secondaryLabelColor, alignment: .right)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    static func sectionHeader(title: String, symbol: String) -> NSView {
        let imageView = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = BTUI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13)
        ])
        return stack
    }

    static func spacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    static func separator() -> BTSeparator {
        let separator = BTSeparator()
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }
}
