import Darwin
import Foundation
@testable import TeaserKit

// The canvas lifecycle machine, driven the way the host drives it: one event in,
// the effects the host must run out. Nothing here touches AppKit — no window is
// created, no monitor installed and no Accessibility asked for — which is what
// lets one case run a transition, its failure and a close in order.
//
// `expect`, `TestCase` and the failure-collecting runner come from the adoption
// fixtures this target links, so a failing case is named rather than counted.

private func expectEffects(
	_ actual: [CanvasEffect],
	_ expected: [CanvasEffect],
	_ message: String
) throws {
	try expect(
		actual == expected,
		"\(message): expected \(expected), got \(actual)"
	)
}

private enum Frames {
	static let windowedA: LayoutRect = .init(x: 120, y: 80, width: 1_200, height: 800)
	static let movedA: LayoutRect = .init(x: 240, y: 160, width: 1_200, height: 800)
	static let windowedB: LayoutRect = .init(x: 1_400, y: 80, width: 900, height: 700)
	static let windowedC: LayoutRect = .init(x: 200, y: 900, width: 800, height: 600)
	static let fullScreen: LayoutRect = .init(x: 0, y: 0, width: 1_728, height: 1_117)
	/// The screen rectangle a canvas that fills its screen is pinned to, which
	/// only the host knows.
	static let screen: LayoutRect = .init(x: 0, y: 38, width: 1_728, height: 1_079)
	/// A frame AppKit reports part-way through an animation.
	static let animating: LayoutRect = .init(x: 60, y: 40, width: 1_500, height: 950)
}

private let canvasA: CanvasID = .init("canvas-a")
private let canvasB: CanvasID = .init("canvas-b")
private let canvasC: CanvasID = .init("canvas-c")

@MainActor
private func openedLifecycle(
	_ canvases: [(canvas: CanvasID, frame: LayoutRect)]
) throws -> CanvasLifecycle {
	let lifecycle: CanvasLifecycle = .init()
	for entry: (canvas: CanvasID, frame: LayoutRect) in canvases {
		try expectEffects(
			lifecycle.handle(.opened(entry.canvas, frame: entry.frame, space: nil)),
			[.displayFrame(entry.canvas, entry.frame)],
			"opening a canvas hands the solver its display"
		)
	}
	try expect(
		lifecycle.openCanvases == canvases.map(\.canvas),
		"canvases keep the order they opened in"
	)
	return lifecycle
}

/// Drives a canvas from windowed to fullscreen the way AppKit does, so a case
/// that starts fullscreen does not restate the enter it is not testing.
@MainActor
private func enterFullScreen(
	_ canvas: CanvasID,
	in lifecycle: CanvasLifecycle
) throws {
	_ = lifecycle.handle(.toggleFullScreenRequested(canvas))
	_ = lifecycle.handle(.willEnterFullScreen(canvas))
	_ = lifecycle.handle(.didEnterFullScreen(canvas, frame: Frames.fullScreen))
	try expect(
		lifecycle.state(of: canvas)?.phase == .fullScreen,
		"the canvas must be fullscreen before the case begins"
	)
}

@MainActor
private func testGateSerializesTwoCanvases() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])

	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasA)),
		[.setOpaque(canvasA, true), .setBackdropLevel(canvasA, false),
			.enterFullScreen(canvasA)],
		"going fullscreen means opaque at the ordinary level, then the transition"
	)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasB)),
		[],
		"macOS animates one transition at a time, so the second request waits"
	)
	try expect(
		lifecycle.pendingTransitions == [canvasB],
		"a request made while the gate is closed becomes a pending intent"
	)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasB)),
		[],
		"asking again while waiting emits nothing"
	)
	try expect(
		lifecycle.pendingTransitions == [canvasB],
		"asking again keeps the canvas's place rather than queueing it twice"
	)
	try expectEffects(
		lifecycle.handle(.willEnterFullScreen(canvasA)),
		[],
		"the request already applied the fullscreen appearance"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .entering,
		"willEnter moves the canvas to entering"
	)

	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen), .setOpaque(canvasB, true),
			.setBackdropLevel(canvasB, false), .enterFullScreen(canvasB)],
		"settling releases the gate and starts the canvas that waited"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .fullScreen
			&& lifecycle.state(of: canvasB)?.phase == .windowed,
		"the second canvas only starts its transition; AppKit still announces it"
	)
	try expect(
		lifecycle.pendingTransitions.isEmpty,
		"the started canvas leaves the queue"
	)
	try expectEffects(
		lifecycle.handle(.didFailToEnterFullScreen(canvasA, frame: Frames.windowedA)),
		[],
		"a callback for a settled canvas changes nothing"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .fullScreen,
		"a transition settles exactly once"
	)
}

@MainActor
private func testOnlyOneQueuedCanvasStartsPerSettle() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
		(canvasC, Frames.windowedC),
	])

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.toggleFullScreenRequested(canvasB))
	_ = lifecycle.handle(.toggleFullScreenRequested(canvasC))
	try expect(
		lifecycle.pendingTransitions == [canvasB, canvasC],
		"pending intents keep request order"
	)
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))

	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen), .setOpaque(canvasB, true),
			.setBackdropLevel(canvasB, false), .enterFullScreen(canvasB)],
		"at most one queued canvas starts when a transition settles"
	)
	try expect(
		lifecycle.pendingTransitions == [canvasC],
		"the rest of the queue keeps waiting"
	)
	_ = lifecycle.handle(.willEnterFullScreen(canvasB))
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasB, frame: Frames.fullScreen)),
		[.displayFrame(canvasB, Frames.fullScreen), .setOpaque(canvasC, true),
			.setBackdropLevel(canvasC, false), .enterFullScreen(canvasC)],
		"the last queued canvas starts when the gate frees again"
	)
	try expect(
		lifecycle.pendingTransitions.isEmpty,
		"the queue drains one canvas per settle"
	)
}

@MainActor
private func testFailedAndContraryCallbacksSettleOnce() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([(canvasA, Frames.windowedA)])

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.didFailToEnterFullScreen(canvasA, frame: Frames.windowedA)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.displayFrame(canvasA, Frames.windowedA)],
		"a failed enter settles back to windowed and undoes what it applied"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .windowed && !lifecycle.isTransitioning,
		"a failure releases the gate"
	)

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.didExitFullScreen(canvasA, frame: Frames.windowedA)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.displayFrame(canvasA, Frames.windowedA)],
		"a contrary callback ends the enter as its failure"
	)
	try expectEffects(
		lifecycle.handle(.didFailToEnterFullScreen(canvasA, frame: Frames.windowedA)),
		[],
		"the failure macOS delivers afterwards settles nothing a second time"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .windowed,
		"the canvas ends where the contrary callback left it"
	)

	try enterFullScreen(canvasA, in: lifecycle)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasA)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.exitFullScreen(canvasA)],
		"leaving fullscreen restores the fill mode's opacity and the backdrop level"
	)
	try expectEffects(
		lifecycle.handle(.willExitFullScreen(canvasA)),
		[],
		"the request already applied the windowed appearance"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .exiting,
		"willExit moves the canvas to exiting"
	)
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.setOpaque(canvasA, true), .setBackdropLevel(canvasA, false),
			.displayFrame(canvasA, Frames.fullScreen)],
		"a contrary callback ends the exit as its failure"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .fullScreen,
		"the canvas stays fullscreen when its exit fails"
	)

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willExitFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.didFailToExitFullScreen(canvasA, frame: Frames.fullScreen)),
		[.setOpaque(canvasA, true), .setBackdropLevel(canvasA, false),
			.displayFrame(canvasA, Frames.fullScreen)],
		"a failed exit settles back to fullscreen"
	)
	try expect(!lifecycle.isTransitioning, "every settle releases the gate")
}

@MainActor
private func testGeometryIsIgnoredWhileTransitioning() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([(canvasA, Frames.windowedA)])

	try expectEffects(
		lifecycle.handle(.geometryChanged(canvasA, frame: Frames.movedA)),
		[.displayFrame(canvasA, Frames.movedA)],
		"moving a settled canvas moves its display"
	)
	try expect(
		lifecycle.displayFrames[DisplayID(canvas: canvasA)] == Frames.movedA,
		"the solver sees the canvas's own rectangle"
	)

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.geometryChanged(canvasA, frame: Frames.animating)),
		[],
		"frames from inside a transition are animation steps"
	)
	try expect(
		lifecycle.state(of: canvasA)?.settledFrame == Frames.movedA,
		"the last frame seen outside the transition stands"
	)
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen)],
		"the settled frame reaches the solver once"
	)
	try expect(
		lifecycle.displayFrames[DisplayID(canvas: canvasA)] == Frames.fullScreen,
		"a fullscreen canvas solves inside its own frame"
	)
}

@MainActor
private func testCloseLeavesFullScreenFirst() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])
	try enterFullScreen(canvasA, in: lifecycle)

	try expectEffects(
		lifecycle.handle(.closeRequested(canvasA)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.exitFullScreen(canvasA)],
		"hiding a fullscreen window would strand an empty Space, so it exits first"
	)
	try expect(
		lifecycle.state(of: canvasA)?.closesWhenSettled == true,
		"the close waits for the exit to settle"
	)
	try expectEffects(
		lifecycle.handle(.willExitFullScreen(canvasA)),
		[],
		"the exit already applied the windowed appearance"
	)
	try expectEffects(
		lifecycle.handle(.didExitFullScreen(canvasA, frame: Frames.windowedA)),
		[.displayFrame(canvasA, Frames.windowedA), .releaseCanvas(canvasA),
			.closeWindow(canvasA)],
		"the close completes when the exit settles"
	)
	try expectEffects(
		lifecycle.handle(.windowClosed(canvasA)),
		[],
		"a closed canvas starts nothing on its way out"
	)

	try expect(
		lifecycle.openCanvases == [canvasB]
			&& lifecycle.state(of: canvasB)?.phase == .windowed,
		"closing one canvas leaves every other canvas as it was"
	)
	try expect(
		lifecycle.displayFrames == [DisplayID(canvas: canvasB): Frames.windowedB],
		"only the closed canvas loses its display"
	)
}

@MainActor
private func testCloseDuringATransitionOnlyRecordsTheIntent() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([(canvasA, Frames.windowedA)])

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.closeRequested(canvasA)),
		[],
		"a canvas mid-transition owns its window until the transition settles"
	)
	try expect(
		lifecycle.state(of: canvasA)?.closesWhenSettled == true,
		"the close is recorded as an intent"
	)

	// No display rectangle is published here: the canvas is already leaving the
	// frame it just arrived at, and the solver would lay Panels out into a
	// fullscreen rectangle that exists for one animation.
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.exitFullScreen(canvasA)],
		"a canvas that arrives fullscreen with a close recorded exits again"
	)
	_ = lifecycle.handle(.willExitFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.didExitFullScreen(canvasA, frame: Frames.windowedA)),
		[.displayFrame(canvasA, Frames.windowedA), .releaseCanvas(canvasA),
			.closeWindow(canvasA)],
		"the recorded close completes after the exit"
	)
}

@MainActor
private func testClosingAWindowedCanvasNeedsNoGate() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	_ = lifecycle.handle(.toggleFullScreenRequested(canvasB))
	try expectEffects(
		lifecycle.handle(.closeRequested(canvasB)),
		[.releaseCanvas(canvasB), .closeWindow(canvasB)],
		"a windowed canvas needs no native transition, so no gate delays its close"
	)
	try expect(
		lifecycle.pendingTransitions.isEmpty,
		"a closing canvas drops the transition it was waiting for"
	)
	try expectEffects(
		lifecycle.handle(.closeRequested(canvasB)),
		[],
		"asking twice releases the canvas once"
	)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasB)),
		[],
		"a canvas on its way out never queues another transition"
	)
	try expect(
		lifecycle.pendingTransitions.isEmpty,
		"nothing waiting behind a window that is closing"
	)
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen)],
		"a closing canvas is never started when the gate frees"
	)
}

@MainActor
private func testWindowClosedReleasesTheGate() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])

	_ = lifecycle.handle(.toggleFullScreenRequested(canvasA))
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	_ = lifecycle.handle(.toggleFullScreenRequested(canvasB))
	try expectEffects(
		lifecycle.handle(.windowClosed(canvasA)),
		[.setOpaque(canvasB, true), .setBackdropLevel(canvasB, false),
			.enterFullScreen(canvasB)],
		"a window that disappears mid-transition releases the gate"
	)
	try expect(
		lifecycle.openCanvases == [canvasB] && lifecycle.state(of: canvasA) == nil,
		"a closed canvas leaves the registry"
	)
	try expect(
		lifecycle.displayFrames[DisplayID(canvas: canvasA)] == nil,
		"a canvas with no settled frame is no display"
	)
}

@MainActor
private func testDisplayFramesCoverOpenCanvasesOnly() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])

	try expect(
		lifecycle.displayFrames == [
			DisplayID(canvas: canvasA): Frames.windowedA,
			DisplayID(canvas: canvasB): Frames.windowedB,
		],
		"each open canvas is one display whose frame is its own rectangle"
	)
	_ = lifecycle.handle(.windowClosed(canvasB))
	try expect(
		lifecycle.displayFrames == [DisplayID(canvas: canvasA): Frames.windowedA],
		"a canvas without a settled frame is left out of the solver's displays"
	)
	// Callbacks for a window the machine has forgotten arrive late; they must
	// not resurrect a display.
	try expectEffects(
		lifecycle.handle(.geometryChanged(canvasB, frame: Frames.movedA)),
		[],
		"a late callback for a closed canvas changes nothing"
	)
	try expectEffects(
		lifecycle.handle(.didExitFullScreen(canvasB, frame: Frames.windowedB)),
		[],
		"a late transition callback for a closed canvas changes nothing"
	)
	try expect(
		lifecycle.displayFrames.count == 1,
		"only open canvases are displays"
	)
}

@MainActor
private func testFillScreenChangesOpacityOnly() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([(canvasA, Frames.windowedA)])

	try expectEffects(
		lifecycle.handle(.fillModeRequested(canvasA, .fillScreen)),
		[.setOpaque(canvasA, true)],
		"Fill Screen is opaque, stays a backdrop and carries no frame of its own"
	)
	try expectEffects(
		lifecycle.handle(.fillModeRequested(canvasA, .fillScreen)),
		[],
		"an unchanged fill mode asks the host for nothing"
	)
	try expect(
		lifecycle.state(of: canvasA)?.phase == .windowed,
		"filling the screen is never macOS fullscreen"
	)
	// The rectangle that fills a screen belongs to the host: what arrives here
	// is the layout rect, clipped once a canvas covers its screen, and echoing
	// that back as a window frame would shrink the canvas it just filled.
	try expectEffects(
		lifecycle.handle(.geometryChanged(canvasA, frame: Frames.screen)),
		[.displayFrame(canvasA, Frames.screen)],
		"a filled canvas reports its display rectangle and asks for no resize"
	)

	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasA)),
		[.setBackdropLevel(canvasA, false), .enterFullScreen(canvasA)],
		"an already opaque canvas only changes level to go fullscreen"
	)
	_ = lifecycle.handle(.willEnterFullScreen(canvasA))
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen)],
		"arriving where it was asked to go restates nothing"
	)
	try expectEffects(
		lifecycle.handle(.fillModeRequested(canvasA, .free)),
		[],
		"a fullscreen canvas records the mode without changing how it looks"
	)
	try expect(
		lifecycle.state(of: canvasA)?.fill == .free,
		"the mode is recorded for when the canvas comes back"
	)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasA)),
		[.setOpaque(canvasA, false), .setBackdropLevel(canvasA, true),
			.exitFullScreen(canvasA)],
		"leaving fullscreen restores the opacity the fill mode asks for"
	)
}

@MainActor
private func testUnrequestedTransitionClosesTheGate() throws {
	let lifecycle: CanvasLifecycle = try openedLifecycle([
		(canvasA, Frames.windowedA), (canvasB, Frames.windowedB),
	])

	// The green button starts a transition this machine never asked for.
	try expectEffects(
		lifecycle.handle(.willEnterFullScreen(canvasA)),
		[.setOpaque(canvasA, true), .setBackdropLevel(canvasA, false)],
		"a transition the person starts still gets the fullscreen appearance"
	)
	try expectEffects(
		lifecycle.handle(.toggleFullScreenRequested(canvasB)),
		[],
		"it closes the same app-wide gate"
	)
	try expectEffects(
		lifecycle.handle(.didEnterFullScreen(canvasA, frame: Frames.fullScreen)),
		[.displayFrame(canvasA, Frames.fullScreen), .setOpaque(canvasB, true),
			.setBackdropLevel(canvasB, false), .enterFullScreen(canvasB)],
		"and releases it exactly once"
	)
}

private func canvasLifecycleCases() -> [TestCase] {
	[
		.init(
			"one gate serializes two canvases",
			testGateSerializesTwoCanvases
		),
		.init(
			"at most one queued canvas starts per settle",
			testOnlyOneQueuedCanvasStartsPerSettle
		),
		.init(
			"failed and contrary callbacks settle exactly once",
			testFailedAndContraryCallbacksSettleOnce
		),
		.init(
			"geometry is ignored mid-transition and applied once on settle",
			testGeometryIsIgnoredWhileTransitioning
		),
		.init(
			"closing a fullscreen canvas leaves fullscreen first",
			testCloseLeavesFullScreenFirst
		),
		.init(
			"a close during a transition only records the intent",
			testCloseDuringATransitionOnlyRecordsTheIntent
		),
		.init(
			"closing a windowed canvas waits for no gate",
			testClosingAWindowedCanvasNeedsNoGate
		),
		.init(
			"a closed window releases the gate",
			testWindowClosedReleasesTheGate
		),
		.init(
			"display frames cover open canvases only",
			testDisplayFramesCoverOpenCanvasesOnly
		),
		.init(
			"Fill Screen changes opacity and nothing else",
			testFillScreenChangesOpacityOnly
		),
		.init(
			"a transition Teaser never asked for closes the gate",
			testUnrequestedTransitionClosesTheGate
		),
	]
}

// Every case runs even after one fails, so a mutation of the machine reports
// the whole set of regressions that caught it rather than only the first.
let cases: [TestCase] = canvasLifecycleCases() + spaceDirectoryCases() + canvasIsolationCases()
var failures: [String] = []
for testCase: TestCase in cases {
	do {
		try testCase.run()
	} catch {
		failures.append("\(testCase.name): \(error)")
	}
}
guard failures.isEmpty else {
	for failure: String in failures {
		fputs("Teaser canvas-lifecycle regression failed: \(failure)\n", stderr)
	}
	fputs(
		"Teaser canvas-lifecycle regression: \(failures.count) of \(cases.count) "
			+ "cases failed\n",
		stderr
	)
	exit(1)
}
print(
	"Teaser canvas-lifecycle regression passed: \(cases.count) cases "
		+ "(no window, no monitors, no prompts)"
)
