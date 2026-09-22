import AppKit

@MainActor
struct DesktopOverlayCallbacks {
	let onVirtualFocusChange: @MainActor (VirtualFocusState) -> Void
	let onPanelInputFocusRequest: @MainActor (PanelID) -> Void
	let onUndoRequest: @MainActor () -> Void
	let onDividerRatioChange:
		@MainActor (DisplayID, LayoutSplitID, Double) -> Void

	init(
		onVirtualFocusChange:
			@escaping @MainActor (VirtualFocusState) -> Void,
		onPanelInputFocusRequest:
			@escaping @MainActor (PanelID) -> Void = { _ in },
		onUndoRequest: @escaping @MainActor () -> Void = {},
		onDividerRatioChange:
			@escaping @MainActor (DisplayID, LayoutSplitID, Double) -> Void
	) {
		self.onVirtualFocusChange = onVirtualFocusChange
		self.onPanelInputFocusRequest = onPanelInputFocusRequest
		self.onUndoRequest = onUndoRequest
		self.onDividerRatioChange = onDividerRatioChange
	}
}

@MainActor
/// Draws Workspace and Panel geometry for whatever surface hosts it: the desktop
/// overlay, or Teaser's own canvas window. Every rectangle it draws is placed
/// relative to `snapshot.screenFrame`, so the host decides what that frame means.
final class DesktopOverlayView: NSView {
	private struct DividerDrag {
		let divider: LayoutDivider
		let pointerOffset: Double
	}

	private let callbacks: DesktopOverlayCallbacks
	private var snapshot: DesktopOverlaySnapshot
	private var dividerDrag: DividerDrag?

	init(
		frame frameRect: NSRect,
		snapshot: DesktopOverlaySnapshot,
		callbacks: DesktopOverlayCallbacks
	) {
		self.snapshot = snapshot
		self.callbacks = callbacks
		super.init(frame: frameRect)
		autoresizingMask = [.width, .height]
		wantsLayer = true
		layer?.backgroundColor = NSColor.clear.cgColor
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	func update(_ snapshot: DesktopOverlaySnapshot) {
		self.snapshot = snapshot
		needsDisplay = true
		window?.invalidateCursorRects(for: self)
	}

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		// Contours first: they sit in the gutters, under everything that marks a
		// single Panel, so a focus ring or a drop highlight always reads on top.
		drawGroupContours()
		drawDividers()
		if snapshot.arrangeMode || snapshot.dragActive {
			drawPanelOutlinesAndLabels()
		}
		drawVirtualFocus()
		drawDropHighlight()
		drawStatus()
	}

	private func localPoint(for event: NSEvent) -> NSPoint {
		guard let source: NSWindow = event.window, let window else { return .zero }
		return convert(window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow)), from: nil)
	}

	override func resetCursorRects() {
		super.resetCursorRects()
		guard snapshot.arrangeMode else { return }

		for divider: LayoutDivider in snapshot.dividers {
			let cursor: NSCursor = divider.axis == .horizontal
				? .resizeLeftRight
				: .resizeUpDown
			addCursorRect(dividerHitRect(divider), cursor: cursor)
		}
	}

	override func mouseDown(with event: NSEvent) {
		guard snapshot.arrangeMode else { return }
		let localPoint: NSPoint = localPoint(for: event)
		if snapshot.status?.contains("Undo available") == true,
			statusRect().contains(localPoint)
		{
			callbacks.onUndoRequest()
			return
		}

		if let divider: LayoutDivider = divider(at: localPoint) {
			let dividerFrame: NSRect = localRect(divider.frame)
			let pointerPosition: Double = divider.axis == .horizontal
				? Double(localPoint.x)
				: Double(localPoint.y)
			let dividerCenter: Double = divider.axis == .horizontal
				? Double(dividerFrame.midX)
				: Double(dividerFrame.midY)
			dividerDrag = .init(
				divider: divider,
				pointerOffset: pointerPosition - dividerCenter
			)
			return
		}

		if let panel: DesktopOverlayPanel = panel(at: localPoint) {
			select(panel: panel, event: event)
		}
	}

	override func mouseDragged(with event: NSEvent) {
		guard snapshot.arrangeMode, let dividerDrag else { return }
		let localPoint: NSPoint = localPoint(for: event)
		let divider: LayoutDivider = dividerDrag.divider
		let container: NSRect = localRect(divider.containerFrame)
		let dividerFrame: NSRect = localRect(divider.frame)
		let pointer: Double = divider.axis == .horizontal
			? Double(localPoint.x)
			: Double(localPoint.y)
		let adjustedPointer: Double = pointer - dividerDrag.pointerOffset
		let containerMinimum: Double = divider.axis == .horizontal
			? Double(container.minX)
			: Double(container.minY)
		let dividerLength: Double = divider.axis == .horizontal
			? Double(dividerFrame.width)
			: Double(dividerFrame.height)
		let containerLength: Double = divider.axis == .horizontal
			? Double(container.width)
			: Double(container.height)
		let availableLength: Double = containerLength - dividerLength
		guard availableLength > 0 else { return }

		let ratio: Double = (
			(adjustedPointer - containerMinimum - dividerLength / 2)
				/ availableLength
		).clamped(to: 0.001 ... 0.999)
		callbacks.onDividerRatioChange(
			divider.displayID,
			divider.splitID,
			ratio
		)
	}

	override func mouseUp(with event: NSEvent) {
		dividerDrag = nil
	}

	private func select(panel: DesktopOverlayPanel, event: NSEvent) {
		callbacks.onVirtualFocusChange(.init(panelID: panel.id))
		if event.clickCount >= 2 {
			callbacks.onPanelInputFocusRequest(panel.id)
		}
	}


	/// The fluorescent outer boundary of each group fragment. Adjacent members
	/// share one continuous loop; a group split by another group's Panel, or
	/// spread across canvases, gets one loop per fragment in the same colour.
	/// A hole is stroked too: the inner edge of a ring is as much the group's
	/// boundary as its outer edge, and leaving it bare would read as if the
	/// enclosed Panel were a member.
	///
	/// Drawing is all this does. No hit region and no cursor rect is registered
	/// for a contour, so it can never intercept input meant for a window.
	private func drawGroupContours() {
		let width: CGFloat = 2.5
		for contour: DesktopOverlayContour in snapshot.contours {
			let color: NSColor = .init(
				srgbRed: CGFloat(contour.color.red),
				green: CGFloat(contour.color.green),
				blue: CGFloat(contour.color.blue),
				alpha: 1
			)
			for loop: ContourLoop in [contour.fragment.outer] + contour.fragment.holes {
				guard let path: NSBezierPath = contourPath(loop) else { continue }
				// A dark keyline under the hue, so a bright colour stays legible
				// over a pale wallpaper as well as a dark one.
				path.lineWidth = width + 2
				NSColor.black.withAlphaComponent(0.55).setStroke()
				path.stroke()
				path.lineWidth = width
				color.withAlphaComponent(0.95).setStroke()
				path.stroke()
			}
		}
	}

	private func contourPath(_ loop: ContourLoop) -> NSBezierPath? {
		guard loop.vertices.count >= 4 else { return nil }
		let path: NSBezierPath = .init()
		path.move(to: localPoint(loop.vertices[0]))
		for vertex: LayoutPoint in loop.vertices.dropFirst() {
			path.line(to: localPoint(vertex))
		}
		path.close()
		path.lineJoinStyle = .miter
		return path
	}

	private func localPoint(_ point: LayoutPoint) -> NSPoint {
		.init(
			x: CGFloat(point.x - snapshot.screenFrame.minX),
			y: CGFloat(point.y - snapshot.screenFrame.minY)
		)
	}

	private func drawDividers() {
		let pixel: CGFloat = backingPixel
		for divider: LayoutDivider in snapshot.dividers {
			let rect: NSRect = localRect(divider.frame)
			// A group boundary reads heavier than a divider inside one group.
			NSColor.separatorColor.withAlphaComponent(
				divider.crossesGroups ? 0.75 : 0.48
			).setFill()

			let line: NSRect
			switch divider.axis {
			case .horizontal:
				line = .init(
					x: rect.midX - pixel / 2,
					y: rect.minY,
					width: pixel,
					height: rect.height
				)
			case .vertical:
				line = .init(
					x: rect.minX,
					y: rect.midY - pixel / 2,
					width: rect.width,
					height: pixel
				)
			}
			line.fill()
		}
	}


	private func drawPanelOutlinesAndLabels() {
		let pixel: CGFloat = backingPixel
		NSColor.separatorColor.withAlphaComponent(0.52).setStroke()

		for panel: DesktopOverlayPanel in snapshot.panels {
			let rect: NSRect = localRect(panel.frame).insetBy(
				dx: pixel / 2,
				dy: pixel / 2
			)
			guard rect.width > pixel, rect.height > pixel else { continue }
			let path: NSBezierPath = .init(rect: rect)
			path.lineWidth = pixel
			path.stroke()

			let label: String = "\(panel.title)  \(kindName(panel.kindID))"
			drawPlaque(
				label,
				anchor: .init(x: rect.minX + 7, y: rect.minY + 7),
				maximumWidth: max(0, min(220, rect.width - 14)),
				font: .systemFont(ofSize: 10, weight: .regular),
				foreground: .secondaryLabelColor,
				background: NSColor.windowBackgroundColor.withAlphaComponent(0.88)
			)
		}
	}


	private func drawVirtualFocus() {
		let focusColor: NSColor = .systemBlue
		if let panelID: PanelID = snapshot.virtualFocus.panelID,
			let panel: DesktopOverlayPanel = snapshot.panels.first(
				where: { $0.id == panelID }
			)
		{
			drawFocusRing(around: localRect(panel.frame), color: focusColor)
		}

	}

	private func drawFocusRing(around rect: NSRect, color: NSColor) {
		let inset: CGFloat = 1.5
		let focusedRect: NSRect = rect.insetBy(dx: inset, dy: inset)
		guard focusedRect.width > 3, focusedRect.height > 3 else { return }
		color.withAlphaComponent(0.92).setStroke()
		let path: NSBezierPath = .init(
			roundedRect: focusedRect,
			xRadius: 3,
			yRadius: 3
		)
		path.lineWidth = 2
		path.stroke()
	}

	private func drawDropHighlight() {
		guard let highlight: DesktopOverlayDropHighlight = snapshot.dropHighlight
		else {
			return
		}
		let rect: NSRect = localRect(highlight.frame).insetBy(dx: 2, dy: 2)
		guard rect.width > 4, rect.height > 4 else { return }

		let path: NSBezierPath = .init(
			roundedRect: rect,
			xRadius: 6,
			yRadius: 6
		)
		NSColor.systemBlue.withAlphaComponent(0.14).setFill()
		path.fill()
		NSColor.systemBlue.withAlphaComponent(0.98).setStroke()
		path.lineWidth = 3
		path.stroke()

		if let label: String = highlight.label {
			drawCenteredPlaque(label, in: rect)
		}
	}

	private func drawStatus() {
		guard let status: String = snapshot.status
			?? (snapshot.arrangeMode ? "Arrange mode" : nil)
		else {
			return
		}
		let text: String = abbreviated(status, maximumCharacters: 80)
		let font: NSFont = .systemFont(ofSize: 11, weight: .medium)
		let rect: NSRect = statusRect(text: text, font: font)
		guard rect.width > 0 else { return }
		drawPlaque(
			text,
			in: rect,
			font: font,
			foreground: .labelColor,
			background: NSColor.windowBackgroundColor.withAlphaComponent(0.95)
		)
	}

	private func statusRect(
		text: String? = nil,
		font: NSFont = .systemFont(ofSize: 11, weight: .medium)
	) -> NSRect {
		guard let status: String = text ?? snapshot.status
			?? (snapshot.arrangeMode ? "Arrange mode" : nil)
		else { return .zero }
		let textSize: NSSize = (status as NSString).size(withAttributes: [
			.font: font,
		])
		let width: CGFloat = min(bounds.width - 24, ceil(textSize.width) + 20)
		guard width > 0 else { return .zero }
		return .init(
			x: bounds.midX - width / 2,
			y: bounds.maxY - 31,
			width: width,
			height: 23
		)
	}

	private func drawCenteredPlaque(_ text: String, in container: NSRect) {
		let font: NSFont = .systemFont(ofSize: 12, weight: .semibold)
		let abbreviatedText: String = abbreviated(text, maximumCharacters: 48)
		let textSize: NSSize = (abbreviatedText as NSString).size(
			withAttributes: [.font: font]
		)
		let width: CGFloat = min(container.width - 20, ceil(textSize.width) + 22)
		guard width > 0 else { return }
		let rect: NSRect = .init(
			x: container.midX - width / 2,
			y: container.midY - 13,
			width: width,
			height: 26
		)
		drawPlaque(
			abbreviatedText,
			in: rect,
			font: font,
			foreground: .controlAccentColor,
			background: NSColor.windowBackgroundColor.withAlphaComponent(0.96)
		)
	}

	private func drawPlaque(
		_ text: String,
		anchor: NSPoint,
		maximumWidth: CGFloat,
		font: NSFont,
		foreground: NSColor,
		background: NSColor
	) {
		guard maximumWidth >= 30 else { return }
		let abbreviatedText: String = abbreviated(text, maximumCharacters: 42)
		let size: NSSize = (abbreviatedText as NSString).size(
			withAttributes: [.font: font]
		)
		let rect: NSRect = .init(
			x: anchor.x,
			y: anchor.y,
			width: min(maximumWidth, ceil(size.width) + 14),
			height: ceil(size.height) + 7
		)
		drawPlaque(
			abbreviatedText,
			in: rect,
			font: font,
			foreground: foreground,
			background: background
		)
	}

	private func drawPlaque(
		_ text: String,
		in rect: NSRect,
		font: NSFont,
		foreground: NSColor,
		background: NSColor
	) {
		guard rect.width > 0, rect.height > 0 else { return }
		background.setFill()
		NSBezierPath(
			roundedRect: rect,
			xRadius: 4,
			yRadius: 4
		).fill()

		let textRect: NSRect = rect.insetBy(dx: 7, dy: 3)
		(text as NSString).draw(
			in: textRect,
			withAttributes: [
				.font: font,
				.foregroundColor: foreground,
			]
		)
	}


	private func divider(at point: NSPoint) -> LayoutDivider? {
		snapshot.dividers.first {
			dividerHitRect($0).contains(point)
		}
	}

	private func dividerHitRect(_ divider: LayoutDivider) -> NSRect {
		let rect: NSRect = localRect(divider.frame)
		switch divider.axis {
		case .horizontal:
			return rect.insetBy(dx: -5, dy: 0)
		case .vertical:
			return rect.insetBy(dx: 0, dy: -5)
		}
	}


	private func panel(at point: NSPoint) -> DesktopOverlayPanel? {
		snapshot.panels
			.sorted(by: { panelArea($0) < panelArea($1) })
			.first { localRect($0.frame).contains(point) }
	}


	private func panelArea(_ panel: DesktopOverlayPanel) -> Double {
		panel.frame.size.area
	}


	private func localRect(_ rect: LayoutRect) -> NSRect {
		.init(
			x: CGFloat(rect.minX - snapshot.screenFrame.minX),
			y: CGFloat(rect.minY - snapshot.screenFrame.minY),
			width: CGFloat(rect.size.width),
			height: CGFloat(rect.size.height)
		)
	}

	private func kindName(_ kindID: PanelKindID) -> String {
		kindID.rawValue
			.split(separator: "-")
			.map { $0.capitalized }
			.joined(separator: " ")
	}

	private func abbreviated(
		_ text: String,
		maximumCharacters: Int
	) -> String {
		guard text.count > maximumCharacters else { return text }
		return String(text.prefix(maximumCharacters - 1)) + "…"
	}

	private var backingPixel: CGFloat {
		1 / max(1, window?.backingScaleFactor ?? 2)
	}
}

private func desktopNSRect(_ rect: LayoutRect) -> NSRect {
	.init(
		x: CGFloat(rect.origin.x),
		y: CGFloat(rect.origin.y),
		width: CGFloat(rect.size.width),
		height: CGFloat(rect.size.height)
	)
}
