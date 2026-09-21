import AppKit

/// Teaser's canvas: an ordinary window a person opens, moves, and resizes, and
/// one of several the app owns. Its content rectangle is the single "display"
/// the layout solver sees for this canvas, which is what keeps its Panels
/// inside it while other canvases keep their own.
///
/// The window reports what happened and never decides what follows: every
/// AppKit callback becomes a `CanvasEvent` for `CanvasLifecycle`, and every
/// change to level, opacity, frame or fullscreen arrives back as an effect. A
/// fullscreen transition is asynchronous and can fail, so nothing here assumes
/// it arrived.
@MainActor
final class DesktopCanvasWindow: NSObject, NSWindowDelegate {
	let id: CanvasID
	let window: CanvasNSWindow
	private let canvasView: DesktopOverlayView
	/// The view whose coordinate space is the solver's display rectangle. The
	/// window's content rectangle is larger whenever the canvas covers the
	/// menu-bar or Dock strip, and drawing into that difference would place
	/// every outline and Panel a strip away from the window it describes.
	private let layoutView: NSView
	/// Status and errors, as a label rather than drawn text, so a failure can be
	/// selected and copied.
	private let statusLabel: NSTextField = .init(wrappingLabelWithString: "")
	private let container: NSView
	private let onEvent: @MainActor (CanvasEvent) -> Void
	/// Which canvas the person is working in. It is not a lifecycle event: the
	/// machine has no opinion about focus, while the host places new Workspaces
	/// and aims canvas commands at the canvas that is actually key.
	private let onBecameKey: @MainActor (CanvasID) -> Void
	/// Teaser-owned Panel content lives inside the canvas rather than in
	/// separate windows, so it is still there when the canvas is fullscreen: no
	/// other application's window may join that Space, but ours is the Space.
	private var contentViews: [PanelID: NSView] = [:]

	init(
		id: CanvasID,
		snapshot: DesktopOverlaySnapshot,
		callbacks: DesktopOverlayCallbacks,
		onEvent: @escaping @MainActor (CanvasEvent) -> Void,
		onBecameKey: @escaping @MainActor (CanvasID) -> Void,
		onContentClick: @escaping @MainActor (PanelID) -> Void
	) {
		self.id = id
		self.onEvent = onEvent
		self.onBecameKey = onBecameKey
		let contentRect: NSRect = .init(x: 0, y: 0, width: 1_200, height: 800)
		canvasView = .init(
			frame: .init(origin: .zero, size: contentRect.size),
			snapshot: snapshot,
			callbacks: callbacks
		)
		canvasView.outlinesPanelsAlways = true
		window = .init(
			contentRect: contentRect,
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		container = .init(frame: .init(origin: .zero, size: contentRect.size))
		layoutView = .init(frame: .init(origin: .zero, size: contentRect.size))
		super.init()
		window.title = "Teaser — Canvas"
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.tabbingMode = .disallowed
		window.minSize = .init(width: 480, height: 360)
		// A backdrop, one level below ordinary windows: adopted windows always sit
		// on top of it, even right after a person clicks the canvas or drags one
		// of its dividers. Fullscreen needs the normal level, so this is a state,
		// not a constant.
		window.level = Self.backdropLevel
		// macOS fullscreen admits no other application's window to its Space, so a
		// fullscreen canvas carries Teaser's own content. `.managed` keeps the
		// canvas on its own Space rather than floating across Spaces, which a
		// below-normal level would otherwise imply.
		window.collectionBehavior = [.managed, .fullScreenPrimary, .fullScreenDisallowsTiling]
		// The canvas only outlines the Workspace's Panels while it is a window on
		// the desktop. Filling the screen or going fullscreen makes it the
		// backdrop, and an opaque one: a fullscreen Space has no wallpaper.
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = false
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		layoutView.addSubview(canvasView)
		container.addSubview(layoutView)
		statusLabel.isSelectable = true
		statusLabel.font = .systemFont(ofSize: 12)
		// Readable over whatever sits behind a transparent canvas.
		statusLabel.textColor = .white
		statusLabel.drawsBackground = true
		statusLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
		statusLabel.maximumNumberOfLines = 4
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(statusLabel)
		NSLayoutConstraint.activate([
			statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
			statusLabel.trailingAnchor.constraint(
				lessThanOrEqualTo: container.trailingAnchor, constant: -16
			),
			statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
		])
		window.contentView = container
		// The big dark canvas: open filling the screen's usable area. Placing it
		// before the delegate is attached keeps the opening frame out of the
		// lifecycle, which has not been told this canvas exists yet.
		if let visible: NSRect = NSScreen.main?.visibleFrame {
			window.setFrame(visible, display: false)
		} else {
			window.center()
		}
		window.delegate = self
		// The green button and the View menu both route here, so one gate can
		// serialize transitions instead of AppKit starting a second one.
		window.onToggleFullScreen = { [weak self] in
			guard let self else { return }
			self.onEvent(.toggleFullScreenRequested(self.id))
		}
		window.onContentClick = { [weak self] point in
			guard let self else { return }
			guard let panelID: PanelID = self.contentPanel(at: point) else { return }
			onContentClick(panelID)
		}
	}

	private static let backdropLevel: NSWindow.Level = .init(
		rawValue: NSWindow.Level.normal.rawValue - 1
	)

	var statusIsSelectable: Bool { statusLabel.isSelectable }

	var isVisible: Bool { window.isVisible }

	var isOnActiveSpace: Bool { window.isOnActiveSpace }

	func setStatus(_ message: String?) {
		statusLabel.stringValue = message ?? ""
		statusLabel.isHidden = message == nil
	}

	func update(_ snapshot: DesktopOverlaySnapshot) {
		syncLayoutFrame()
		canvasView.update(snapshot)
	}

	/// Places the layout view at the rectangle the solver was given, expressed
	/// in the window's own coordinates.
	private func syncLayoutFrame() {
		let content: NSRect = window.contentRect(forFrameRect: window.frame)
		let layout: LayoutRect = canvasFrame
		layoutView.frame = .init(
			x: layout.minX - Double(content.minX),
			y: layout.minY - Double(content.minY),
			width: layout.size.width,
			height: layout.size.height
		)
		canvasView.frame = layoutView.bounds
	}

	/// The content rectangle in AppKit screen coordinates. While the canvas
	/// covers its screen, the layout rectangle is clipped to the screen's
	/// visible frame: adopted windows live on the desktop Space, where macOS
	/// keeps a window below the menu bar, so an unclipped rectangle would draw
	/// Panels where no provider window can actually go.
	var canvasFrame: LayoutRect {
		let rect: NSRect = window.contentRect(forFrameRect: window.frame)
		guard coversScreen, let visible: NSRect = (window.screen ?? NSScreen.main)?.visibleFrame
		else {
			return layoutRect(rect)
		}
		return layoutRect(rect.intersection(visible))
	}

	private var coversScreen: Bool {
		if window.styleMask.contains(.fullScreen) { return true }
		guard let screen: NSScreen = window.screen else { return false }
		return window.frame.contains(screen.visibleFrame)
	}

	private func layoutRect(_ rect: NSRect) -> LayoutRect {
		.init(
			x: Double(rect.minX),
			y: Double(rect.minY),
			width: Double(rect.width),
			height: Double(rect.height)
		)
	}

	// MARK: - Effects

	func show(space: SpaceIdentity?) {
		window.makeKeyAndOrderFront(nil)
		onEvent(.opened(id, frame: canvasFrame, space: space))
	}

	/// Ordering the window front is how a canvas on another Space is reached:
	/// macOS switches to the Space that holds it. No Space is moved or created.
	func bringForward() {
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate()
	}

	func setOpaque(_ opaque: Bool) {
		window.isOpaque = opaque
		window.hasShadow = opaque
		window.backgroundColor = opaque ? Self.backdropColor : .clear
		canvasView.needsDisplay = true
	}

	private static let backdropColor: NSColor = .init(white: 0.06, alpha: 1)

	func setBackdropLevel(_ backdrop: Bool) {
		window.level = backdrop ? Self.backdropLevel : .normal
	}

	func setFrame(_ rect: LayoutRect) {
		window.setFrame(
			.init(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height),
			display: true
		)
	}

	/// The whole screen, menu-bar strip included. AppKit would otherwise keep a
	/// titled window's title bar below the menu bar, which leaves a gap the
	/// canvas is supposed to cover.
	var screenFillFrame: LayoutRect? {
		guard let screen: NSScreen = window.screen ?? NSScreen.main else { return nil }
		return layoutRect(screen.frame)
	}

	func toggleFullScreen() {
		window.performToggleFullScreen()
	}

	func closeWindow() {
		window.close()
	}

	// MARK: - Teaser-owned Panel content

	func setContent(_ view: NSView, for panelID: PanelID, frame: LayoutRect) {
		if contentViews[panelID] !== view {
			contentViews[panelID]?.removeFromSuperview()
			contentViews[panelID] = view
			layoutView.addSubview(view, positioned: .above, relativeTo: canvasView)
		}
		syncLayoutFrame()
		view.frame = localRect(frame)
		view.isHidden = false
	}

	func removeContent(for panelID: PanelID) {
		contentViews.removeValue(forKey: panelID)?.removeFromSuperview()
	}

	func removeAllContent() {
		for view: NSView in contentViews.values { view.removeFromSuperview() }
		contentViews.removeAll()
	}

	var contentPanelIDs: Set<PanelID> { .init(contentViews.keys) }

	/// Screen coordinates to the layout view's, which is the same space the
	/// solver and the drawn outlines use.
	private func localRect(_ rect: LayoutRect) -> NSRect {
		let origin: LayoutRect = canvasFrame
		return .init(
			x: rect.minX - origin.minX,
			y: rect.minY - origin.minY,
			width: rect.size.width,
			height: rect.size.height
		)
	}

	private func contentPanel(at pointInWindow: NSPoint) -> PanelID? {
		let point: NSPoint = layoutView.convert(pointInWindow, from: nil)
		return contentViews.first { _, view in view.frame.contains(point) }?.key
	}

	// MARK: - NSWindowDelegate

	func windowDidBecomeKey(_ notification: Notification) {
		onBecameKey(id)
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		// Closing is a lifecycle decision: a fullscreen canvas has to leave its
		// Space first, or macOS keeps an empty black Space behind.
		onEvent(.closeRequested(id))
		return false
	}

	func windowWillClose(_ notification: Notification) {
		onEvent(.windowClosed(id))
	}

	// Moving or resizing the canvas moves the layout with it, because the canvas
	// rectangle is the display the solver works in. Frames seen during a
	// fullscreen animation are intermediate, and the lifecycle drops them.
	func windowDidMove(_ notification: Notification) {
		onEvent(.geometryChanged(id, frame: canvasFrame))
	}

	func windowDidResize(_ notification: Notification) {
		onEvent(.geometryChanged(id, frame: canvasFrame))
	}

	func windowWillEnterFullScreen(_ notification: Notification) {
		onEvent(.willEnterFullScreen(id))
	}

	func windowDidEnterFullScreen(_ notification: Notification) {
		onEvent(.didEnterFullScreen(id, frame: canvasFrame))
	}

	func windowDidFailToEnterFullScreen(_ window: NSWindow) {
		onEvent(.didFailToEnterFullScreen(id, frame: canvasFrame))
	}

	func windowWillExitFullScreen(_ notification: Notification) {
		onEvent(.willExitFullScreen(id))
	}

	func windowDidExitFullScreen(_ notification: Notification) {
		onEvent(.didExitFullScreen(id, frame: canvasFrame))
	}

	func windowDidFailToExitFullScreen(_ window: NSWindow) {
		onEvent(.didFailToExitFullScreen(id, frame: canvasFrame))
	}
}

/// The canvas's window. It exists to route the green button and the standard
/// Enter Full Screen command through Teaser's own transition gate, and to see
/// clicks that land on Teaser-owned Panel content before the content does.
@MainActor
final class CanvasNSWindow: NSWindow {
	var onToggleFullScreen: (@MainActor () -> Void)?
	var onContentClick: (@MainActor (NSPoint) -> Void)?

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }

	/// A canvas that fills its screen covers the menu-bar strip too; AppKit's
	/// default constraint would push a titled window back down.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}

	override func toggleFullScreen(_ sender: Any?) {
		guard let onToggleFullScreen else {
			super.toggleFullScreen(sender)
			return
		}
		onToggleFullScreen()
	}

	/// Called by the lifecycle, after its gate says this canvas may transition.
	func performToggleFullScreen() {
		super.toggleFullScreen(nil)
	}

	override func sendEvent(_ event: NSEvent) {
		if event.type == .leftMouseDown {
			onContentClick?(event.locationInWindow)
		}
		super.sendEvent(event)
	}
}
