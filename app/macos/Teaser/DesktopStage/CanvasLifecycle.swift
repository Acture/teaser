import Foundation

/// The rules every canvas window obeys, with no AppKit in them: the host turns
/// `NSWindowDelegate` callbacks and menu commands into `CanvasEvent`s and
/// carries out the `CanvasEffect`s that come back. Keeping the rules here is
/// what lets a headless test drive a fullscreen transition, its failure and a
/// close in one run, which no test can do against a real window.
///
/// Two macOS facts shape everything below. macOS animates one native fullscreen
/// transition at a time, so one app-wide gate admits a single canvas and every
/// other request waits its turn. And macOS ignores a toggle issued from inside
/// a `window...FullScreen` callback, so this machine only returns the effect;
/// the host dispatches it on a later run-loop turn.
///
/// Nothing here redistributes Workspaces. A canvas is one display to the layout
/// solver, and closing one canvas releases only that canvas.
@MainActor
final class CanvasLifecycle {
	/// What the host has already been told to apply. Every appearance effect is
	/// a delta against this, so a transition that arrives where it was asked to
	/// go re-states nothing, and one that fails still restores what the request
	/// changed.
	private struct CanvasAppearance: Equatable {
		/// A fresh canvas is transparent, one level below ordinary windows: it
		/// outlines Panels, and adopted windows tile above it.
		var isOpaque: Bool = false
		var isBackdropLevel: Bool = true
	}

	private var states: [CanvasID: CanvasState] = [:]
	private var appearances: [CanvasID: CanvasAppearance] = [:]
	private var order: [CanvasID] = []
	/// The app-wide gate. A canvas joins when this machine asks for a native
	/// transition and when AppKit announces one it never asked for, such as the
	/// green button, and leaves when exactly one callback settles it. It closes
	/// before `phase` becomes `.entering`, because a second toggle would
	/// otherwise slip through the gap between the request and `willEnter`.
	private var inFlight: Set<CanvasID> = []
	/// Toggle requests that arrived while the gate was busy, in request order.
	/// A canvas appears at most once: asking again keeps its place, and the
	/// queue also carries the exit a deferred close depends on.
	private var pending: [CanvasID] = []
	/// Canvases that asked to fill the screen and still need the rectangle to
	/// fill. This machine holds no screen of its own, so the frame arrives as
	/// the host's next `geometryChanged` and pins the canvas exactly once.
	private var pendingFillFrames: Set<CanvasID> = []

	// MARK: - Reading

	func state(of canvas: CanvasID) -> CanvasState? {
		states[canvas]
	}

	/// Open canvases in the order they opened, which is the order the host shows
	/// them in and the order a queued transition follows.
	var openCanvases: [CanvasID] {
		order
	}

	/// The display rectangles the layout solver works in: one per open canvas
	/// that has a settled frame. A canvas mid-transition keeps the last frame
	/// seen outside that transition, so no animation frame reaches the solver.
	var displayFrames: [DisplayID: LayoutRect] {
		var frames: [DisplayID: LayoutRect] = [:]
		for canvas: CanvasID in order {
			guard let state: CanvasState = states[canvas],
				let frame: LayoutRect = state.settledFrame
			else {
				continue
			}
			frames[state.displayID] = frame
		}
		return frames
	}

	/// True while the gate is closed, which is what makes a toggle request wait.
	var isTransitioning: Bool {
		!inFlight.isEmpty
	}

	var pendingTransitions: [CanvasID] {
		pending
	}

	// MARK: - Events

	func handle(_ event: CanvasEvent) -> [CanvasEffect] {
		switch event {
		case .opened(let canvas, let frame, let space):
			return open(canvas, frame: frame, space: space)
		case .toggleFullScreenRequested(let canvas):
			return toggleFullScreen(canvas)
		case .willEnterFullScreen(let canvas):
			return beginTransition(canvas, phase: .entering)
		case .didEnterFullScreen(let canvas, let frame):
			return settle(canvas, phase: .fullScreen, frame: frame)
		case .didFailToEnterFullScreen(let canvas, let frame):
			return settle(canvas, phase: .windowed, frame: frame)
		case .willExitFullScreen(let canvas):
			return beginTransition(canvas, phase: .exiting)
		case .didExitFullScreen(let canvas, let frame):
			return settle(canvas, phase: .windowed, frame: frame)
		case .didFailToExitFullScreen(let canvas, let frame):
			return settle(canvas, phase: .fullScreen, frame: frame)
		case .geometryChanged(let canvas, let frame):
			return geometryChanged(canvas, frame: frame)
		case .fillModeRequested(let canvas, let fill):
			return setFillMode(canvas, fill)
		case .closeRequested(let canvas):
			return closeRequested(canvas)
		case .windowClosed(let canvas):
			return windowClosed(canvas)
		}
	}

	private func open(
		_ canvas: CanvasID,
		frame: LayoutRect,
		space: SpaceIdentity?
	) -> [CanvasEffect] {
		// Every open creates a fresh window and a closed canvas leaves the
		// registry, so opening a live canvas again is a host mistake rather than
		// a state to merge.
		precondition(
			states[canvas] == nil,
			"canvas \(canvas.rawValue) is already open"
		)
		states[canvas] = .init(id: canvas, settledFrame: frame, space: space)
		appearances[canvas] = .init()
		order.append(canvas)
		return [.displayFrame(canvas, frame)]
	}

	private func toggleFullScreen(_ canvas: CanvasID) -> [CanvasEffect] {
		// A canvas on its way out never starts a transition: its window is being
		// torn down, and a queued intent would wake it again.
		guard let state: CanvasState = states[canvas], !state.closesWhenSettled else {
			return []
		}
		guard !isTransitioning else {
			enqueue(canvas)
			return []
		}
		return start(canvas)
	}

	/// Starts the one native transition the gate admits, in the direction the
	/// canvas is not in. The appearance goes first so the window is dressed for
	/// where it is going before AppKit begins to animate it.
	private func start(_ canvas: CanvasID) -> [CanvasEffect] {
		guard let state: CanvasState = states[canvas] else {
			return []
		}
		let entering: Bool = !state.phase.isFullScreen
		inFlight.insert(canvas)
		pending.removeAll { $0 == canvas }
		let transition: CanvasEffect = entering
			? .enterFullScreen(canvas)
			: .exitFullScreen(canvas)
		return appearanceEffects(canvas, fullScreenTarget: entering) + [transition]
	}

	private func beginTransition(
		_ canvas: CanvasID,
		phase: CanvasFullScreenPhase
	) -> [CanvasEffect] {
		guard var state: CanvasState = states[canvas] else {
			return []
		}
		state.phase = phase
		states[canvas] = state
		// A transition the person starts from the green button never passed
		// through `start`, so the gate closes here too and the appearance is
		// applied here. After a toggle both are already done and nothing is
		// emitted twice.
		inFlight.insert(canvas)
		return appearanceEffects(canvas, fullScreenTarget: phase == .entering)
	}

	private func settle(
		_ canvas: CanvasID,
		phase: CanvasFullScreenPhase,
		frame: LayoutRect
	) -> [CanvasEffect] {
		guard var state: CanvasState = states[canvas] else {
			return []
		}
		// A contrary callback ends the transition in flight as its failure, and
		// macOS may still deliver the matching failure afterwards. Only the
		// callback that finds a transition in flight settles the canvas, so a
		// transition settles exactly once.
		guard inFlight.remove(canvas) != nil else {
			return []
		}
		state.phase = phase
		state.settledFrame = frame
		states[canvas] = state
		let closing: [CanvasEffect] = completeCloseIfRequested(canvas)
		let next: [CanvasEffect] = startNextIfIdle()
		// A canvas that went straight back into a transition is already dressed
		// for where it is going now, so restating how it settled would undo it.
		let settledLook: [CanvasEffect] = inFlight.contains(canvas)
			? []
			: appearanceEffects(canvas, fullScreenTarget: phase.isFullScreen)
		return settledLook + [.displayFrame(canvas, frame)] + closing + next
	}

	private func geometryChanged(
		_ canvas: CanvasID,
		frame: LayoutRect
	) -> [CanvasEffect] {
		// Frames arriving mid-transition are animation steps; the settled frame
		// is applied once, by the callback that ends the transition.
		guard var state: CanvasState = states[canvas], state.phase.isSettled else {
			return []
		}
		state.settledFrame = frame
		states[canvas] = state
		// A canvas that asked to fill the screen is pinned to the rectangle the
		// host reports, once. Later moves are the person's own.
		guard pendingFillFrames.remove(canvas) != nil else {
			return [.displayFrame(canvas, frame)]
		}
		return [.setFrame(canvas, frame), .displayFrame(canvas, frame)]
	}

	private func setFillMode(
		_ canvas: CanvasID,
		_ fill: CanvasFillMode
	) -> [CanvasEffect] {
		guard var state: CanvasState = states[canvas], state.fill != fill else {
			return []
		}
		state.fill = fill
		states[canvas] = state
		// This machine holds no screen rectangle, so Fill Screen only records the
		// mode and asks for opacity; the frame it fills arrives as the host's
		// next `geometryChanged`. A fullscreen canvas is opaque and owns its
		// frame already, so there the mode only decides how it comes back.
		switch fill {
		case .fillScreen where !state.phase.isFullScreen:
			pendingFillFrames.insert(canvas)
		case .fillScreen:
			break
		case .free:
			pendingFillFrames.remove(canvas)
		}
		return appearanceEffects(canvas, fullScreenTarget: targetIsFullScreen(state))
	}

	private func closeRequested(_ canvas: CanvasID) -> [CanvasEffect] {
		// Asking twice closes the canvas once: the window stays until the host
		// reports `windowClosed`, so a second ⌘W must not release it again.
		guard var state: CanvasState = states[canvas], !state.closesWhenSettled else {
			return []
		}
		state.closesWhenSettled = true
		states[canvas] = state
		// A canvas of its own mid-transition owns its window until it settles;
		// the close resumes from `settle`.
		guard !inFlight.contains(canvas) else {
			return []
		}
		guard state.phase.isFullScreen else {
			// A windowed canvas needs no native transition, so the gate another
			// canvas holds never delays its close.
			return closeNow(canvas)
		}
		guard !isTransitioning else {
			enqueue(canvas)
			return []
		}
		return start(canvas)
	}

	private func windowClosed(_ canvas: CanvasID) -> [CanvasEffect] {
		guard states.removeValue(forKey: canvas) != nil else {
			return []
		}
		appearances.removeValue(forKey: canvas)
		order.removeAll { $0 == canvas }
		pending.removeAll { $0 == canvas }
		pendingFillFrames.remove(canvas)
		// A window that disappears mid-transition never delivers its callback,
		// so closing it releases the gate.
		inFlight.remove(canvas)
		return startNextIfIdle()
	}

	// MARK: - Transitions

	private func enqueue(_ canvas: CanvasID) {
		guard !pending.contains(canvas) else {
			return
		}
		pending.append(canvas)
	}

	/// Starts at most one waiting canvas, in request order. Canvases that closed
	/// while they waited are dropped rather than woken.
	private func startNextIfIdle() -> [CanvasEffect] {
		guard !isTransitioning else {
			return []
		}
		while !pending.isEmpty {
			let next: CanvasID = pending.removeFirst()
			guard states[next] != nil else {
				continue
			}
			return start(next)
		}
		return []
	}

	/// Hiding a fullscreen window leaves its Space behind, empty, so a canvas
	/// asked to close while fullscreen leaves fullscreen first and closes when
	/// that exit settles.
	private func completeCloseIfRequested(_ canvas: CanvasID) -> [CanvasEffect] {
		guard let state: CanvasState = states[canvas], state.closesWhenSettled else {
			return []
		}
		guard !state.phase.isFullScreen else {
			enqueue(canvas)
			return []
		}
		return closeNow(canvas)
	}

	/// The canvas stays registered until the host reports `windowClosed`: the
	/// window is still on screen, and its display keeps a frame until it is not.
	private func closeNow(_ canvas: CanvasID) -> [CanvasEffect] {
		pending.removeAll { $0 == canvas }
		return [.releaseCanvas(canvas), .closeWindow(canvas)]
	}

	// MARK: - Appearance

	/// Where a canvas is headed, which is what its appearance must match while
	/// macOS animates.
	private func targetIsFullScreen(_ state: CanvasState) -> Bool {
		switch state.phase {
		case .windowed, .exiting:
			false
		case .entering, .fullScreen:
			true
		}
	}

	/// Fullscreen needs an opaque canvas at the ordinary window level: its Space
	/// shows nothing behind the canvas and admits no other application's window
	/// to stay above. Everywhere else the canvas sits one level below ordinary
	/// windows so adopted windows tile above it, opaque only when it fills the
	/// screen.
	private func appearanceEffects(
		_ canvas: CanvasID,
		fullScreenTarget: Bool
	) -> [CanvasEffect] {
		guard let state: CanvasState = states[canvas],
			var appearance: CanvasAppearance = appearances[canvas]
		else {
			return []
		}
		let isOpaque: Bool = fullScreenTarget || state.fill == .fillScreen
		let isBackdropLevel: Bool = !fullScreenTarget
		var effects: [CanvasEffect] = []
		if appearance.isOpaque != isOpaque {
			appearance.isOpaque = isOpaque
			effects.append(.setOpaque(canvas, isOpaque))
		}
		if appearance.isBackdropLevel != isBackdropLevel {
			appearance.isBackdropLevel = isBackdropLevel
			effects.append(.setBackdropLevel(canvas, isBackdropLevel))
		}
		appearances[canvas] = appearance
		return effects
	}
}
