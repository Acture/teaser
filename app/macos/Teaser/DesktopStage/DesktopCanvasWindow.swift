import AppKit

/// Teaser's canvas: an ordinary window a person opens, moves, and resizes.
///
/// The layout lives inside this window rather than on the desktop, so Teaser
/// never covers the screen, never becomes an input shield, and never competes
/// with Stage Manager, Mission Control, or Spaces. Dragging another
/// application's window onto the canvas adopts it into the Panel under the
/// pointer; the provider window is then placed inside the canvas's own frame.
///
/// The canvas's content rectangle is the single "display" the layout solver
/// sees, which is what keeps every Panel inside this window.
@MainActor
final class DesktopCanvasWindow: NSObject, NSWindowDelegate {
	let window: NSWindow
	private let canvasView: DesktopOverlayView
	/// Status and errors, as a label rather than drawn text, so a failure can be
	/// selected and copied.
	private let statusLabel: NSTextField = .init(wrappingLabelWithString: "")
	private let onGeometryChange: @MainActor (LayoutRect) -> Void
	private let onClose: @MainActor () -> Void

	init(
		snapshot: DesktopOverlaySnapshot,
		callbacks: DesktopOverlayCallbacks,
		onGeometryChange: @escaping @MainActor (LayoutRect) -> Void,
		onClose: @escaping @MainActor () -> Void = {}
	) {
		self.onGeometryChange = onGeometryChange
		self.onClose = onClose
		let contentRect: NSRect = .init(x: 0, y: 0, width: 1_200, height: 800)
		canvasView = .init(
			frame: .init(origin: .zero, size: contentRect.size),
			snapshot: snapshot,
			callbacks: callbacks
		)
		canvasView.autoresizingMask = [.width, .height]
		window = .init(
			contentRect: contentRect,
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		super.init()
		window.title = "Teaser — Canvas"
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.tabbingMode = .disallowed
		window.minSize = .init(width: 480, height: 360)
		// The big dark canvas: an ordinary window's background, not a desktop-wide
		// surface, so what it covers is exactly what the person sized it to cover.
		window.backgroundColor = .black
		// The label is a sibling above the canvas view, so clicks on it reach the
		// label however the canvas view hit-tests its own drawing.
		let container: NSView = .init(frame: .init(origin: .zero, size: contentRect.size))
		container.addSubview(canvasView)
		statusLabel.isSelectable = true
		statusLabel.font = .systemFont(ofSize: 12)
		statusLabel.textColor = .init(white: 0.8, alpha: 1)
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
		window.delegate = self
		window.center()
	}

	var statusIsSelectable: Bool { statusLabel.isSelectable }

	func setStatus(_ message: String?) {
		statusLabel.stringValue = message ?? ""
		statusLabel.isHidden = message == nil
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		onClose()
		return true
	}

	/// The content rectangle in AppKit screen coordinates, which is what the
	/// orchestrator receives as its one display.
	var canvasFrame: LayoutRect {
		let rect: NSRect = window.contentRect(forFrameRect: window.frame)
		return .init(
			x: Double(rect.minX),
			y: Double(rect.minY),
			width: Double(rect.width),
			height: Double(rect.height)
		)
	}

	var isVisible: Bool { window.isVisible }

	func update(_ snapshot: DesktopOverlaySnapshot) {
		canvasView.update(snapshot)
	}

	func show() {
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
		onGeometryChange(canvasFrame)
	}

	func close() { window.orderOut(nil) }

	// Moving or resizing the canvas moves the layout with it, because the canvas
	// rectangle is the display the solver works in.
	func windowDidMove(_ notification: Notification) {
		onGeometryChange(canvasFrame)
	}

	func windowDidResize(_ notification: Notification) {
		onGeometryChange(canvasFrame)
	}
}
