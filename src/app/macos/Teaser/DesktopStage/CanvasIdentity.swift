import Foundation

/// A canvas window's stable identity. It outlives its window: closing a canvas
/// keeps the ID so reopening restores the same placement, and every window the
/// canvas ever owns reports the same display to the layout solver.
struct CanvasID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

extension DisplayID {
	/// Each open canvas is one display to the solver, so Workspace placement,
	/// divider scopes and drop targets all key off the canvas rather than a
	/// physical monitor.
	init(canvas: CanvasID) {
		self.init("canvas.\(canvas.rawValue)")
	}
}

/// How much of its screen a canvas covers. Filling the screen keeps the canvas
/// on its ordinary Space, where adopted windows can tile above it; it is never
/// presented as macOS fullscreen.
enum CanvasFillMode: Codable, Equatable, Sendable {
	case free
	case fillScreen
}

/// macOS drives fullscreen asynchronously and can fail a transition, so a
/// canvas is never assumed to have arrived. Every transition ends in exactly
/// one settled phase.
enum CanvasFullScreenPhase: Codable, Equatable, Sendable {
	case windowed
	case entering
	case fullScreen
	case exiting

	var isSettled: Bool {
		self == .windowed || self == .fullScreen
	}

	var isFullScreen: Bool {
		self == .fullScreen
	}
}

/// A canvas's window state as the host reports it. `settledFrame` is the last
/// frame seen outside a transition; intermediate animation frames never reach
/// the solver.
struct CanvasState: Equatable, Sendable {
	let id: CanvasID
	var phase: CanvasFullScreenPhase = .windowed
	var fill: CanvasFillMode = .free
	var settledFrame: LayoutRect?
	var space: SpaceIdentity?
	var closesWhenSettled: Bool = false
	/// How often macOS has refused to leave fullscreen for a close. A refusal
	/// that repeats forever would hold the transition gate and never close the
	/// canvas, so the close gives up and says so instead.
	var refusedCloseExits: Int = 0

	var displayID: DisplayID { .init(canvas: id) }
}

/// What the host tells the lifecycle happened. Requests and AppKit delegate
/// callbacks arrive through the same door so the machine, not the window,
/// decides what follows.
enum CanvasEvent: Equatable, Sendable {
	case opened(CanvasID, frame: LayoutRect, space: SpaceIdentity?)
	case toggleFullScreenRequested(CanvasID)
	case willEnterFullScreen(CanvasID)
	case didEnterFullScreen(CanvasID, frame: LayoutRect)
	case didFailToEnterFullScreen(CanvasID, frame: LayoutRect)
	case willExitFullScreen(CanvasID)
	case didExitFullScreen(CanvasID, frame: LayoutRect)
	case didFailToExitFullScreen(CanvasID, frame: LayoutRect)
	case geometryChanged(CanvasID, frame: LayoutRect)
	/// The canvas was seen on this Space. macOS publishes no way to ask which
	/// Space a given window is on, so the one moment the answer is certain is
	/// while the canvas is visible: whatever is on screen is on the current
	/// Space. Without this a canvas keeps the Space it opened on forever.
	case spaceChanged(CanvasID, SpaceIdentity)
	case fillModeRequested(CanvasID, CanvasFillMode)
	case closeRequested(CanvasID)
	case windowClosed(CanvasID)
}

/// What the host must carry out. The lifecycle performs no AppKit work itself,
/// which is what lets it run in a headless test.
enum CanvasEffect: Equatable, Sendable {
	/// Ask AppKit to start a native transition. Never sent while another canvas
	/// is mid-transition, and never from inside a delegate callback.
	case enterFullScreen(CanvasID)
	case exitFullScreen(CanvasID)
	/// Opaque while fullscreen or filling the screen, transparent otherwise: a
	/// fullscreen Space has no wallpaper behind the canvas.
	case setOpaque(CanvasID, Bool)
	/// The backdrop level sits below ordinary windows so adopted windows stay
	/// above the canvas; fullscreen needs the normal level.
	case setBackdropLevel(CanvasID, Bool)
	/// Release this canvas's adopted windows and stop showing its Workspaces,
	/// without touching any other canvas.
	case releaseCanvas(CanvasID)
	case closeWindow(CanvasID)
	/// macOS kept refusing to leave fullscreen, so the close was given up rather
	/// than retried forever. The canvas is still open and still fullscreen.
	case closeRefused(CanvasID)
	/// A settled frame the solver can use as this canvas's display rectangle.
	case displayFrame(CanvasID, LayoutRect)
}

/// A macOS Space, identified the way `com.apple.spaces` does. Teaser reads it
/// to tell which Space a canvas belongs to; it never writes it.
struct SpaceIdentity: Codable, Equatable, Hashable, Sendable {
	/// Stable within a login session and unique per Space.
	let managedID: Int
	/// Empty for the first desktop, which macOS leaves without one.
	let uuid: String
	let isFullScreen: Bool
}
