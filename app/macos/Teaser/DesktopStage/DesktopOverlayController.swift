import AppKit

struct DesktopOverlayWorkspace: Equatable, Identifiable, Sendable {
	let id: WorkspaceID
	let title: String
	let frame: LayoutRect
}

struct DesktopOverlayPanel: Equatable, Identifiable, Sendable {
	let id: PanelID
	let workspaceID: WorkspaceID
	let title: String
	let kindID: PanelKindID
	let frame: LayoutRect
}

struct DesktopOverlayDropHighlight: Equatable, Sendable {
	let workspaceID: WorkspaceID
	let panelID: PanelID
	let edge: LayoutEdge?
	let frame: LayoutRect
	let label: String?

	init(
		workspaceID: WorkspaceID,
		panelID: PanelID,
		edge: LayoutEdge? = nil,
		frame: LayoutRect,
		label: String? = nil
	) {
		self.workspaceID = workspaceID
		self.panelID = panelID
		self.edge = edge
		self.frame = frame
		self.label = label
	}
}

struct DesktopOverlaySnapshot: Equatable, Sendable {
	let displayID: DisplayID
	let screenFrame: LayoutRect
	let workspaces: [DesktopOverlayWorkspace]
	let panels: [DesktopOverlayPanel]
	let dividers: [LayoutDivider]
	let virtualFocus: VirtualFocusState
	let arrangeMode: Bool
	let dragActive: Bool
	let dropHighlight: DesktopOverlayDropHighlight?
	let status: String?

	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		workspaces: [DesktopOverlayWorkspace],
		panels: [DesktopOverlayPanel],
		dividers: [LayoutDivider],
		virtualFocus: VirtualFocusState,
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		self.displayID = displayID
		self.screenFrame = screenFrame
		self.workspaces = workspaces
		self.panels = panels
		self.dividers = dividers
		self.virtualFocus = virtualFocus
		self.arrangeMode = arrangeMode
		self.dragActive = dragActive
		self.dropHighlight = dropHighlight
		self.status = status
	}

	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		presentation: WorkspacePresentation,
		layout: PresentationLayout,
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		let displayWorkspaces: [WorkspaceDescriptor] = presentation.workspaces
			.values
			.filter {
				$0.displayAffinity == displayID
					&& layout.workspaceFrames[$0.id] != nil
			}
			.sorted { $0.id.rawValue < $1.id.rawValue }
		let workspaceIDs: Set<WorkspaceID> = .init(
			displayWorkspaces.map(\.id)
		)

		self.init(
			displayID: displayID,
			screenFrame: screenFrame,
			workspaces: displayWorkspaces.compactMap { workspace in
				guard let frame: LayoutRect = layout.workspaceFrames[workspace.id]
				else {
					return nil
				}
				return .init(
					id: workspace.id,
					title: workspace.title,
					frame: frame
				)
			},
			panels: displayWorkspaces.flatMap { workspace in
				workspace.panels.values
					.compactMap { panel in
						guard let frame: LayoutRect = layout.panelFrames[panel.id]
						else {
							return nil
						}
						return .init(
							id: panel.id,
							workspaceID: workspace.id,
							title: panel.providerHint.map { "\($0.displayName) · \(panel.title)" } ?? panel.title,
							kindID: panel.kindID,
							frame: frame
						)
					}
					.sorted { $0.id.rawValue < $1.id.rawValue }
			},
			dividers: layout.dividers.filter { divider in
				switch divider.scope {
				case .display(let dividerDisplayID):
					return dividerDisplayID == displayID
				case .workspace(let workspaceID):
					return workspaceIDs.contains(workspaceID)
				}
			},
			virtualFocus: presentation.virtualFocus,
			arrangeMode: arrangeMode,
			dragActive: dragActive,
			dropHighlight: dropHighlight,
			status: status
		)
	}
}

@MainActor
struct DesktopOverlayCallbacks {
	let onVirtualFocusChange: @MainActor (VirtualFocusState) -> Void
	let onWorkspaceFocusRequest: @MainActor (WorkspaceID) -> Void
	let onPanelInputFocusRequest: @MainActor (PanelID) -> Void
	let onUndoRequest: @MainActor () -> Void
	let onDividerRatioChange:
		@MainActor (LayoutScope, LayoutSplitID, Double) -> Void

	init(
		onVirtualFocusChange:
			@escaping @MainActor (VirtualFocusState) -> Void,
		onWorkspaceFocusRequest:
			@escaping @MainActor (WorkspaceID) -> Void,
		onPanelInputFocusRequest:
			@escaping @MainActor (PanelID) -> Void = { _ in },
		onUndoRequest: @escaping @MainActor () -> Void = {},
		onDividerRatioChange:
			@escaping @MainActor (LayoutScope, LayoutSplitID, Double) -> Void
	) {
		self.onVirtualFocusChange = onVirtualFocusChange
		self.onWorkspaceFocusRequest = onWorkspaceFocusRequest
		self.onPanelInputFocusRequest = onPanelInputFocusRequest
		self.onUndoRequest = onUndoRequest
		self.onDividerRatioChange = onDividerRatioChange
	}
}

/// Owns one transparent desktop overlay for every display snapshot supplied by
/// the application coordinator. The controller contains no presentation model;
/// all durable state changes are reported through its callbacks.
@MainActor
final class DesktopOverlayController {
	private let callbacks: DesktopOverlayCallbacks
	private var windows: [DisplayID: DesktopOverlayWindow] = [:]

	init(callbacks: DesktopOverlayCallbacks) {
		self.callbacks = callbacks
	}

	func update(_ snapshots: [DesktopOverlaySnapshot]) {
		var incomingDisplayIDs: Set<DisplayID> = []
		for snapshot: DesktopOverlaySnapshot in snapshots {
			precondition(
				incomingDisplayIDs.insert(snapshot.displayID).inserted,
				"Desktop overlay snapshots must have unique display IDs"
			)

			if let window: DesktopOverlayWindow = windows[snapshot.displayID] {
				window.update(snapshot)
			} else {
				let window: DesktopOverlayWindow = .init(
					snapshot: snapshot,
					callbacks: callbacks
				)
				windows[snapshot.displayID] = window
				window.update(snapshot)
			}
		}

		let staleDisplayIDs: [DisplayID] = windows.keys.filter {
			!incomingDisplayIDs.contains($0)
		}
		for displayID: DisplayID in staleDisplayIDs {
			guard let window: DesktopOverlayWindow = windows.removeValue(
				forKey: displayID
			) else {
				continue
			}
			window.orderOut(nil)
			window.close()
		}
	}

	func close() {
		for window: DesktopOverlayWindow in windows.values {
			window.orderOut(nil)
			window.close()
		}
		windows.removeAll()
	}
}

@MainActor
final class DesktopOverlayWindow: NSPanel {
	private let overlayView: DesktopOverlayView
	private var hitWindows: [DesktopOverlayHitWindow] = []

	init(
		snapshot: DesktopOverlaySnapshot,
		callbacks: DesktopOverlayCallbacks
	) {
		let frame: NSRect = desktopNSRect(snapshot.screenFrame)
		let overlayView: DesktopOverlayView = .init(
			frame: .init(origin: .zero, size: frame.size),
			snapshot: snapshot,
			callbacks: callbacks
		)
		self.overlayView = overlayView

		super.init(
			contentRect: frame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)

		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		level = .floating
		animationBehavior = .none
		isMovable = false
		isMovableByWindowBackground = false
		isRestorable = false
		isReleasedWhenClosed = false
		hidesOnDeactivate = false
		becomesKeyOnlyIfNeeded = true
		acceptsMouseMovedEvents = true
		collectionBehavior = [
			.ignoresCycle,
			.stationary,
		]
		tabbingMode = .disallowed
		contentView = overlayView
		// A display-sized visual surface must never become an input shield.
		ignoresMouseEvents = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }

	func update(_ snapshot: DesktopOverlaySnapshot) {
		let nextFrame: NSRect = desktopNSRect(snapshot.screenFrame)
		if frame != nextFrame {
			setFrame(nextFrame, display: false)
		}
		overlayView.update(snapshot)
		updateHitWindows()
		if !isVisible {
			orderFrontRegardless()
		}
	}

	override func close() {
		for hitWindow: DesktopOverlayHitWindow in hitWindows { hitWindow.close() }
		hitWindows.removeAll()
		super.close()
	}

	private func updateHitWindows() {
		let rects: [NSRect] = overlayView.interactiveRects
		while hitWindows.count > rects.count { hitWindows.removeLast().close() }
		for (index, rect): (Int, NSRect) in rects.enumerated() {
			let screenRect: NSRect = convertToScreen(rect)
			if index == hitWindows.count {
				hitWindows.append(.init(frame: screenRect, target: overlayView))
			} else {
				hitWindows[index].setFrame(screenRect, display: false)
			}
			hitWindows[index].orderFrontRegardless()
		}
	}
}

/// Only these small labels and divider handles receive mouse input. Empty
/// pixels between them belong to provider windows, including in Arrange mode.
@MainActor
private final class DesktopOverlayHitWindow: NSPanel {
	init(frame: NSRect, target: DesktopOverlayView) {
		super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		level = .floating
		hidesOnDeactivate = false
		isReleasedWhenClosed = false
		isRestorable = false
		collectionBehavior = [.ignoresCycle, .stationary]
		contentView = DesktopOverlayHitView(frame: .init(origin: .zero, size: frame.size), target: target)
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}

@MainActor
private final class DesktopOverlayHitView: NSView {
	private weak var target: DesktopOverlayView?
	init(frame: NSRect, target: DesktopOverlayView) {
		self.target = target
		super.init(frame: frame)
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
	override func mouseDown(with event: NSEvent) { target?.mouseDown(with: event) }
	override func mouseDragged(with event: NSEvent) { target?.mouseDragged(with: event) }
	override func mouseUp(with event: NSEvent) { target?.mouseUp(with: event) }
}

@MainActor
private final class DesktopOverlayView: NSView {
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

		drawWorkspaceOutlines()
		drawDividers()
		if snapshot.arrangeMode || snapshot.dragActive {
			drawPanelOutlinesAndLabels()
		}
		drawWorkspaceLabels()
		drawVirtualFocus()
		drawDropHighlight()
		drawStatus()
	}

	var interactiveRects: [NSRect] {
		guard snapshot.arrangeMode, !snapshot.dragActive else { return [] }
		var rects: [NSRect] = snapshot.dividers.map(dividerHitRect)
		rects += snapshot.workspaces.map(workspaceLabelRect)
		rects += snapshot.panels.map { panel in
			let rect: NSRect = localRect(panel.frame)
			return .init(x: rect.minX + 7, y: rect.minY + 7, width: min(220, rect.width - 14), height: 20)
		}
		if snapshot.status?.contains("Undo available") == true { rects.append(statusRect()) }
		return rects.filter { $0.width > 0 && $0.height > 0 }
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

		if let workspace: DesktopOverlayWorkspace = workspaceLabel(
			at: localPoint
		) {
			select(workspace: workspace, panel: nil, event: event)
			return
		}

		if let panel: DesktopOverlayPanel = panel(at: localPoint),
			let workspace: DesktopOverlayWorkspace = snapshot.workspaces.first(
				where: { $0.id == panel.workspaceID }
			)
		{
			select(workspace: workspace, panel: panel, event: event)
			return
		}

		if let workspace: DesktopOverlayWorkspace = workspace(at: localPoint) {
			select(workspace: workspace, panel: nil, event: event)
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
			divider.scope,
			divider.splitID,
			ratio
		)
	}

	override func mouseUp(with event: NSEvent) {
		dividerDrag = nil
	}

	private func select(
		workspace: DesktopOverlayWorkspace,
		panel: DesktopOverlayPanel?,
		event: NSEvent
	) {
		callbacks.onVirtualFocusChange(
			.init(workspaceID: workspace.id, panelID: panel?.id)
		)
		if event.clickCount >= 2 {
			if let panel {
				callbacks.onPanelInputFocusRequest(panel.id)
			} else {
				callbacks.onWorkspaceFocusRequest(workspace.id)
			}
		}
	}

	private func drawWorkspaceOutlines() {
		let pixel: CGFloat = backingPixel
		NSColor.separatorColor.withAlphaComponent(
			snapshot.arrangeMode ? 0.72 : 0.38
		).setStroke()

		for workspace: DesktopOverlayWorkspace in snapshot.workspaces {
			let rect: NSRect = localRect(workspace.frame).insetBy(
				dx: pixel / 2,
				dy: pixel / 2
			)
			guard rect.width > pixel, rect.height > pixel else { continue }
			let path: NSBezierPath = .init(rect: rect)
			path.lineWidth = pixel
			path.stroke()
		}
	}

	private func drawDividers() {
		let pixel: CGFloat = backingPixel
		for divider: LayoutDivider in snapshot.dividers {
			let rect: NSRect = localRect(divider.frame)
			let isWorkspaceDivider: Bool
			switch divider.scope {
			case .display:
				isWorkspaceDivider = true
			case .workspace:
				isWorkspaceDivider = false
			}
			NSColor.separatorColor.withAlphaComponent(
				isWorkspaceDivider ? 0.75 : 0.48
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

	private func drawWorkspaceLabels() {
		for workspace: DesktopOverlayWorkspace in snapshot.workspaces {
			let labelRect: NSRect = workspaceLabelRect(workspace)
			guard labelRect.width > 0 else { continue }
			drawPlaque(
				workspace.title,
				in: labelRect,
				font: .systemFont(ofSize: 11, weight: .semibold),
				foreground: .labelColor,
				background: NSColor.windowBackgroundColor.withAlphaComponent(0.92)
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
			return
		}

		if let workspaceID: WorkspaceID = snapshot.virtualFocus.workspaceID,
			let workspace: DesktopOverlayWorkspace = snapshot.workspaces.first(
				where: { $0.id == workspaceID }
			)
		{
			drawFocusRing(around: localRect(workspace.frame), color: focusColor)
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

	private func workspaceLabelRect(
		_ workspace: DesktopOverlayWorkspace
	) -> NSRect {
		let workspaceRect: NSRect = localRect(workspace.frame)
		let availableWidth: CGFloat = max(0, min(180, workspaceRect.width - 14))
		guard availableWidth >= 30 else { return .zero }
		let font: NSFont = .systemFont(ofSize: 11, weight: .semibold)
		let title: String = abbreviated(workspace.title, maximumCharacters: 30)
		let size: NSSize = (title as NSString).size(withAttributes: [.font: font])
		return .init(
			x: workspaceRect.minX + 7,
			y: workspaceRect.maxY - ceil(size.height) - 14,
			width: min(availableWidth, ceil(size.width) + 16),
			height: ceil(size.height) + 7
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

	private func workspaceLabel(
		at point: NSPoint
	) -> DesktopOverlayWorkspace? {
		snapshot.workspaces.first {
			workspaceLabelRect($0).contains(point)
		}
	}

	private func panel(at point: NSPoint) -> DesktopOverlayPanel? {
		snapshot.panels
			.sorted(by: { panelArea($0) < panelArea($1) })
			.first { localRect($0.frame).contains(point) }
	}

	private func workspace(at point: NSPoint) -> DesktopOverlayWorkspace? {
		snapshot.workspaces
			.sorted(by: { workspaceArea($0) < workspaceArea($1) })
			.first { localRect($0.frame).contains(point) }
	}

	private func panelArea(_ panel: DesktopOverlayPanel) -> Double {
		panel.frame.size.area
	}

	private func workspaceArea(_ workspace: DesktopOverlayWorkspace) -> Double {
		workspace.frame.size.area
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
