import AppKit
import CoreGraphics
import Foundation

// Regressions for the event sequencing `WindowDragObserver` has to survive: the
// global monitor and the button-state sampler arriving interleaved, the same
// notification arriving twice, and drag or release deliveries never arriving at
// all. These cases assert the exact drag events the observer announced, because
// a duplicated `began` or a missing `ended` is not visible in the orchestration
// state alone.

enum ObservedDragEvent: Equatable {
	case began(ExternalWindowIdentity)
	case changed(ExternalWindowIdentity)
	case ended(ExternalWindowIdentity, CGPoint)
	case cancelled(ExternalWindowIdentity, ExternalWindowDragCancellationReason)
}

@MainActor
final class ObserverHarness {
	let log: FakeOperationLog = .init()
	let service: FakeExternalWindowService
	let clock: ManualClock = .init()
	let pointer: RecordingPointerSource
	let observer: WindowDragObserver
	private(set) var events: [ObservedDragEvent] = []
	private(set) var diagnostics: [String] = []
	private(set) var pointerLocation: CGPoint = .zero

	init() {
		let log: FakeOperationLog = self.log
		service = .init(log: log)
		pointer = .init(log: log)
		observer = .init(service: service, clock: clock, pointerSource: pointer)
		observer.onEvent = { [weak self] event in self?.record(event) }
		observer.onDiagnostic = { [weak self] message in
			self?.diagnostics.append(message)
		}
	}

	var begunCount: Int {
		events.filter { if case .began = $0 { return true } else { return false } }.count
	}

	var endedCount: Int {
		events.filter { if case .ended = $0 { return true } else { return false } }.count
	}

	@discardableResult
	func addWindow(
		pid: pid_t = providerPID,
		windowID: CGWindowID = 10,
		frame: CGRect = .init(x: 200, y: 200, width: 400, height: 300)
	) -> FakeWindow {
		let window: FakeWindow = .init(
			processIdentifier: pid,
			windowID: windowID,
			applicationName: "Provider",
			title: "Provider Window",
			appKitScreenFrame: frame
		)
		service.windows.insert(window, at: 0)
		return window
	}

	func press(_ window: FakeWindow) {
		press(at: .init(
			x: window.appKitScreenFrame.midX,
			y: window.appKitScreenFrame.maxY - 8
		))
	}

	func press(at point: CGPoint) {
		pointerLocation = point
		pointer.send(.monitored(phase: .down, appKitScreenLocation: point))
	}

	func dragWindow(_ window: FakeWindow, to point: CGPoint) {
		moveWithoutDelivery(window, to: point)
		clock.advance(1)
		pointer.send(.monitored(phase: .dragged, appKitScreenLocation: point))
	}

	func dragPointerOnly(to point: CGPoint) {
		pointerLocation = point
		clock.advance(1)
		pointer.send(.monitored(phase: .dragged, appKitScreenLocation: point))
	}

	/// Moves the pointer and the window together without delivering any event,
	/// which is what a native title-bar drag that withholds deliveries looks like.
	func moveWithoutDelivery(_ window: FakeWindow, to point: CGPoint) {
		window.offset(dx: point.x - pointerLocation.x, dy: point.y - pointerLocation.y)
		pointerLocation = point
	}

	func sample(isButtonDown: Bool, at point: CGPoint? = nil) {
		let location: CGPoint = point ?? pointerLocation
		pointerLocation = location
		clock.advance(1)
		pointer.send(.sampled(isButtonDown: isButtonDown, appKitScreenLocation: location))
	}

	func releasePointer(at point: CGPoint? = nil) {
		let location: CGPoint = point ?? pointerLocation
		pointerLocation = location
		clock.advance(1)
		pointer.send(.monitored(phase: .up, appKitScreenLocation: location))
	}

	private func record(_ event: ExternalWindowDragEvent) {
		switch event {
		case .began(let snapshot):
			events.append(.began(snapshot.selection.identity))
		case .changed(let snapshot):
			events.append(.changed(snapshot.selection.identity))
		case .ended(let snapshot):
			events.append(
				.ended(
					snapshot.selection.identity,
					snapshot.currentSample.mouseAppKitScreenLocation
				)
			)
		case .cancelled(let identity, let reason):
			events.append(.cancelled(identity, reason))
		}
	}
}

@MainActor
private func makeStartedObserver() throws -> ObserverHarness {
	let harness: ObserverHarness = .init()
	try harness.observer.start()
	return harness
}

// MARK: - Duplicate, interleaved, and missing deliveries

@MainActor
private func testDuplicatePressDoesNotRestartTheDrag() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	let destination: CGPoint = .init(x: 900, y: 700)

	harness.press(window)
	harness.dragWindow(window, to: .init(x: 600, y: 500))
	try expect(harness.begunCount == 1, "the drag must begin once it qualifies")
	// The same press is delivered again mid-drag.
	harness.pointer.send(
		.monitored(phase: .down, appKitScreenLocation: harness.pointerLocation)
	)
	harness.dragWindow(window, to: destination)
	harness.releasePointer()

	try expect(
		harness.begunCount == 1,
		"a duplicate press must not begin a second drag: \(harness.events)"
	)
	try expect(
		harness.events.last == .ended(window.identity, destination),
		"the drag must still end exactly once at the release point: \(harness.events)"
	)
	try expect(harness.endedCount == 1, "one drag must produce one drop")
}

@MainActor
private func testDuplicateReleaseEndsTheDragOnce() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	let destination: CGPoint = .init(x: 900, y: 700)

	harness.press(window)
	harness.dragWindow(window, to: destination)
	harness.releasePointer()
	harness.releasePointer()
	harness.sample(isButtonDown: false)

	try expect(
		harness.endedCount == 1,
		"repeated release deliveries must produce one drop: \(harness.events)"
	)
	try expect(
		harness.events.filter({ if case .cancelled = $0 { return true } else { return false } })
			.isEmpty,
		"a completed drop must never also cancel: \(harness.events)"
	)
}

@MainActor
private func testMonitoredAndSampledDeliveriesInterleaveIntoOneDrag() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	let destination: CGPoint = .init(x: 900, y: 700)

	harness.press(window)
	// The sampler reports the same held button the monitor already reported.
	harness.sample(isButtonDown: true)
	harness.dragWindow(window, to: .init(x: 600, y: 500))
	harness.moveWithoutDelivery(window, to: .init(x: 750, y: 620))
	harness.sample(isButtonDown: true)
	harness.dragWindow(window, to: destination)
	harness.releasePointer()

	try expect(
		harness.begunCount == 1 && harness.endedCount == 1,
		"interleaved monitor and sampler deliveries are one drag: \(harness.events)"
	)
	try expect(
		harness.events.first == .began(window.identity)
			&& harness.events.last == .ended(window.identity, destination),
		"the drag must begin and end on the same window: \(harness.events)"
	)
}

@MainActor
private func testMissingDragDeliveriesStillCompleteTheDrop() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	let destination: CGPoint = .init(x: 900, y: 700)

	// Native title-bar tracking can withhold every drag delivery between the
	// press and the release.
	harness.press(window)
	harness.moveWithoutDelivery(window, to: destination)
	harness.releasePointer()

	try expect(
		harness.events == [.began(window.identity), .ended(window.identity, destination)],
		"a drag with no delivered movement must still qualify and drop: \(harness.events)"
	)
}

@MainActor
private func testMissingReleaseIsClosedByButtonSampling() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	let destination: CGPoint = .init(x: 900, y: 700)

	harness.press(window)
	harness.dragWindow(window, to: destination)
	// No `up` is ever delivered; only the sampler notices the button came up.
	harness.sample(isButtonDown: false)

	try expect(
		harness.endedCount == 1 && harness.events.last == .ended(window.identity, destination),
		"a missing release must be closed by button-state sampling: \(harness.events)"
	)
}

@MainActor
private func testUnqualifiedDragIsNeverAnnounced() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()

	harness.press(window)
	harness.dragPointerOnly(to: .init(x: 900, y: 700))
	harness.releasePointer()

	try expect(
		harness.events.isEmpty,
		"a press that never became a window drag must announce nothing: \(harness.events)"
	)
}

@MainActor
private func testCancelledDragIgnoresItsLateRelease() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()

	harness.press(window)
	harness.dragWindow(window, to: .init(x: 700, y: 600))
	window.exists = false
	harness.dragWindow(window, to: .init(x: 900, y: 700))
	harness.releasePointer()

	try expect(
		harness.events == [
			.began(window.identity),
			.cancelled(window.identity, .windowUnavailable),
		],
		"a cancelled drag must not also end: \(harness.events)"
	)
	try expect(
		harness.diagnostics.count == 1
			&& harness.diagnostics[0].contains("unavailable"),
		"the cancellation must be diagnosed once: \(harness.diagnostics)"
	)
}

@MainActor
private func testStoppingTheObserverCancelsAnInFlightDrag() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()

	harness.press(window)
	harness.dragWindow(window, to: .init(x: 900, y: 700))
	harness.observer.stop()

	try expect(
		harness.events.last == .cancelled(window.identity, .observerStopped),
		"stopping mid-drag must cancel with its own reason: \(harness.events)"
	)
	try expect(
		!harness.pointer.isRunning && harness.pointer.stopCount == 1,
		"stopping the observer must stop pointer observation"
	)
	harness.pointer.send(.monitored(phase: .up, appKitScreenLocation: .init(x: 900, y: 700)))
	try expect(
		harness.endedCount == 0,
		"a release delivered after the stop must reach nothing: \(harness.events)"
	)
}

@MainActor
private func testRejectedCandidateIsDiagnosedOnceTheDragIsReal() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	harness.addWindow()

	// The press lands on empty desktop, so there is no candidate at all.
	harness.press(at: .init(x: 1_800, y: 900))
	harness.dragPointerOnly(to: .init(x: 1_803, y: 900))
	try expect(
		harness.diagnostics.isEmpty,
		"a press that never moved must not report a rejection: \(harness.diagnostics)"
	)
	harness.dragPointerOnly(to: .init(x: 1_830, y: 900))
	harness.dragPointerOnly(to: .init(x: 1_870, y: 900))
	harness.releasePointer()

	try expect(
		harness.diagnostics == [
			ManagedExternalWindowError.windowAtPointUnavailable.localizedDescription,
		],
		"a rejected candidate must be reported exactly once: \(harness.diagnostics)"
	)
	try expect(harness.events.isEmpty, "a rejected candidate must announce no drag")
}

@MainActor
private func testTimeAdvancementGatesResampling() throws {
	let harness: ObserverHarness = try makeStartedObserver()
	let window: FakeWindow = harness.addWindow()
	harness.press(window)
	let before: Int = harness.service.snapshotReads

	// The first sample after the press is always taken; later samples wait for
	// the clock, so a burst of pointer deliveries cannot flood window queries.
	harness.dragWindow(window, to: .init(x: 900, y: 700))
	let afterFirst: Int = harness.service.snapshotReads
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: .init(x: 901, y: 700)))
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: .init(x: 902, y: 700)))
	try expect(afterFirst == before + 1, "one advanced tick must produce exactly one sample")
	try expect(
		harness.service.snapshotReads == afterFirst,
		"samples without time advancement must be throttled"
	)
	harness.clock.advance(1)
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: .init(x: 903, y: 700)))
	try expect(
		harness.service.snapshotReads == afterFirst + 1,
		"advancing the clock must allow the next sample"
	)
}

// MARK: - The same sequences through the whole adoption chain

@MainActor
private func testButtonStateSamplesDriveTheSameChain() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	let grab: CGPoint = harness.grabPoint(window)

	// Native title-bar tracking can withhold every NSEvent delivery. Adoption
	// must still work from button-state sampling alone.
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: grab))
	window.offset(dx: drop.x - grab.x, dy: drop.y - grab.y)
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: drop))
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: false, appKitScreenLocation: drop))

	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a sampled drag must adopt exactly like a delivered one"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1,
		"a sampled drag must lease the window exactly once"
	)
}

@MainActor
private func testStaleButtonSampleAfterTheDropDoesNotReadopt() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	try harness.adopt(window, into: leftPanelID)
	let length: Int = harness.log.operations.count

	// A sampler tick that predates the release arrives after it. The pointer is
	// now over the window Teaser just adopted.
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: drop))
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: false, appKitScreenLocation: drop))

	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a stale sample must not re-adopt or move the window it follows"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1,
		"a stale sample must not lease the window a second time"
	)
	try expect(
		harness.log.operations.count == length,
		"a stale sample must not touch any window: \(harness.log.operations.suffix(3))"
	)
	try expect(
		harness.orchestrator.statusMessage == "Window adopted · Undo available",
		"a stale sample must not overwrite the outcome the user was told"
	)
}

// MARK: - Gaps closed after the first audit of this matrix

@MainActor
private func testSubThresholdNudgeIsNotADrag() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let grab: CGPoint = harness.grabPoint(window)

	// The pointer and the window move together, but by less than the movement
	// floors that separate a jiggled title bar from a deliberate drag.
	harness.press(window)
	harness.dragWindow(window, to: .init(x: grab.x + 3, y: grab.y + 1))
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"a 3 pt nudge must not become a drag"
	)
	harness.releasePointer()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0
			&& harness.orchestrator.statusMessage == nil,
		"a nudge must adopt nothing and report nothing"
	)

	// The same gesture past the floor is a drag.
	let panel: CGRect = try harness.panelFrame(leftPanelID)
	harness.press(window)
	harness.dragWindow(window, to: .init(x: panel.midX, y: panel.midY))
	try expect(
		harness.orchestrator.dropHighlight?.panelID == leftPanelID,
		"a deliberate move past the floor must qualify"
	)
	harness.releasePointer()
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"the qualified drag must adopt"
	)
}

@MainActor
private func testCorrelatedResizeIsNotADrag() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let corner: CGPoint = .init(
		x: window.appKitScreenFrame.minX,
		y: window.appKitScreenFrame.minY
	)

	// Dragging the bottom-leading corner moves the origin exactly with the
	// pointer, so only the size change distinguishes it from a move.
	harness.press(at: corner)
	let frame: CGRect = window.appKitScreenFrame
	window.appKitScreenFrame = .init(
		x: frame.minX - 100,
		y: frame.minY - 100,
		width: frame.width + 100,
		height: frame.height + 100
	)
	harness.dragPointerOnly(to: .init(x: corner.x - 100, y: corner.y - 100))
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"a corner resize must not qualify even though the origin follows the pointer"
	)
	harness.releasePointer()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a resize must adopt nothing"
	)
}

@MainActor
private func testSamplerAloneKeepsTheHighlightFollowingThePointer() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let grab: CGPoint = harness.grabPoint(window)
	let leftCenter: CGPoint = try harness.center(of: leftPanelID)
	let rightCenter: CGPoint = try harness.center(of: rightPanelID)

	// Every delivery is a button-state sample; the global monitor contributes
	// nothing, which is the native title-bar case.
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: grab))
	window.offset(dx: leftCenter.x - grab.x, dy: leftCenter.y - grab.y)
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: leftCenter))
	try expect(
		harness.orchestrator.dropHighlight?.panelID == leftPanelID,
		"a sampled drag must expose a target while the button is held"
	)

	window.offset(dx: rightCenter.x - leftCenter.x, dy: rightCenter.y - leftCenter.y)
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: rightCenter))
	try expect(
		harness.orchestrator.dropHighlight?.panelID == rightPanelID,
		"the sampled target must follow the pointer between Panels"
	)

	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: false, appKitScreenLocation: rightCenter))
	try expect(
		harness.orchestrator.panelAssignments == [rightPanelID: window.identity],
		"the sampled drag must drop where its last target promised"
	)
}

@MainActor
private func testReleaseInsideTheSamplingIntervalStillDrops() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let grab: CGPoint = harness.grabPoint(window)
	let panel: CGRect = try harness.panelFrame(leftPanelID)
	let drop: CGPoint = .init(x: panel.midX, y: panel.midY)

	// One sub-threshold sample arms the throttle, then the whole move and the
	// release arrive inside the same sampling interval.
	harness.press(window)
	harness.dragWindow(window, to: .init(x: grab.x + 2, y: grab.y))
	try expect(
		!harness.orchestrator.isDragging,
		"the arming sample must not qualify on its own"
	)
	window.offset(dx: drop.x - harness.pointerLocation.x, dy: drop.y - harness.pointerLocation.y)
	harness.clock.advance(0.001)
	harness.pointer.send(.monitored(phase: .up, appKitScreenLocation: drop))

	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a release inside the sampling interval must still qualify and drop"
	)
	try expect(
		try harness.readBackFrame(window.identity) == panel,
		"that drop must place the window in its Panel"
	)
}

@MainActor
private func testCancelledDragStaysDisarmedWhileTheButtonIsHeld() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let leftCenter: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: leftCenter)

	// The dragged window disappears, cancelling the pending adoption.
	window.exists = false
	harness.dragWindow(window, to: .init(x: leftCenter.x + 20, y: leftCenter.y))
	try expect(
		!harness.orchestrator.isDragging,
		"the drag must be cancelled before the substitute appears"
	)

	// A different window slides under the still-held pointer, and the sampler
	// keeps ticking. Nothing may re-arm until the button comes up.
	let substitute: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 99,
		frame: .init(
			x: harness.pointerLocation.x - 200,
			y: harness.pointerLocation.y - 100,
			width: 400,
			height: 200
		)
	)
	harness.clock.advance(1)
	harness.pointer.send(
		.sampled(isButtonDown: true, appKitScreenLocation: harness.pointerLocation)
	)
	let rightCenter: CGPoint = try harness.center(of: rightPanelID)
	substitute.offset(
		dx: rightCenter.x - harness.pointerLocation.x,
		dy: rightCenter.y - harness.pointerLocation.y
	)
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: true, appKitScreenLocation: rightCenter))
	harness.clock.advance(1)
	harness.pointer.send(.sampled(isButtonDown: false, appKitScreenLocation: rightCenter))

	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a cancelled drag must not hand the held button to another window"
	)
	try expect(
		harness.log.bindCount(for: substitute.identity) == 0,
		"the substitute must never be leased"
	)
}

@MainActor
private func testRestartedStageObservesTheNextDrag() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let leftCenter: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: leftCenter)

	// The stage stops with a qualified drag in flight and is started again.
	harness.orchestrator.stopStage()
	try harness.orchestrator.startStage()
	try expect(
		harness.pointer.isRunning && harness.pointer.startCount == 2,
		"restarting must observe the pointer again"
	)

	try harness.adopt(window, into: rightPanelID)
	try expect(
		harness.orchestrator.panelAssignments == [rightPanelID: window.identity],
		"a restarted stage must adopt the next drag from a clean press state"
	)
}

@MainActor
private func testRejectionIsNotReportedAfterItsPressEnded() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	let outcome: String = try unwrap(
		harness.orchestrator.statusMessage,
		"the adoption must report its own outcome"
	)

	// A press on empty desktop selects nothing and is released immediately.
	harness.press(at: .init(x: 1_950, y: 980))
	harness.releasePointer()
	// A later stray movement belongs to no press.
	harness.clock.advance(1)
	harness.pointer.send(
		.monitored(phase: .dragged, appKitScreenLocation: .init(x: 1_890, y: 980))
	)

	try expect(
		harness.orchestrator.statusMessage == outcome,
		"a retired press must not report over what the user actually did: \(harness.orchestrator.statusMessage ?? "none")"
	)
}

@MainActor
private func testUnmanageableWindowsAreNeverAdopted() throws {
	let cases: [(String, (FakeWindow) -> Void)] = [
		("full-screen", { $0.isFullScreen = true }),
		("minimized", { $0.isMinimized = true }),
		("non-standard", { $0.isStandard = false }),
		("immovable", { $0.allowsMove = false }),
		("unresizable", { $0.allowsResize = false }),
	]
	for (name, makeUnmanageable): (String, (FakeWindow) -> Void) in cases {
		let harness: Harness = try makeStartedHarness()
		let window: FakeWindow = harness.addWindow()
		makeUnmanageable(window)
		let logLength: Int = harness.log.operations.count

		// The user's own drag still moves the window; the claim is that Teaser
		// never selects, leases, or writes to it.
		try harness.adopt(window, into: leftPanelID)
		try expect(
			harness.orchestrator.panelAssignments.isEmpty
				&& harness.log.bindCount(for: window.identity) == 0,
			"a \(name) window must never be adopted"
		)
		try expect(
			harness.orchestrator.dropHighlight == nil,
			"a \(name) window must never expose a drop target"
		)
		try expect(
			harness.log.operations.count == logLength,
			"Teaser must issue no window operation for a \(name) window: \(harness.log.operations.suffix(3))"
		)
	}
}

@MainActor
private func testEdgeAndCentreBoundaryIsWhereTheHitTestSaysItIs() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let panel: CGRect = try harness.panelFrame(leftPanelID)
	// min(width, height) * 0.22 exceeds the 120 pt ceiling on this Panel, so the
	// edge band is exactly 120 pt wide.
	let band: CGFloat = 120

	harness.press(second)
	harness.dragWindow(second, to: .init(x: panel.minX + band - 1, y: panel.midY))
	try expect(
		harness.orchestrator.dropHighlight?.edge == .leading,
		"a point inside the edge band must be an edge target"
	)
	harness.dragWindow(second, to: .init(x: panel.minX + band + 1, y: panel.midY))
	try expect(
		harness.orchestrator.dropHighlight?.edge == nil
			&& harness.orchestrator.dropHighlight?.label == "Occupied · use an edge",
		"a point past the edge band must be the centre: \(String(describing: harness.orchestrator.dropHighlight?.edge))"
	)
	harness.releasePointer()
}

@MainActor
private func testSplitPanelDescribesTheWindowThatCreatedIt() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		name: "Second",
		title: "Second Window",
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let panel: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(second, at: .init(x: panel.maxX - 12, y: panel.midY))

	let descriptor: PanelDescriptor = try unwrap(
		harness.orchestrator.presentation.workspaces[testWorkspaceID]?
			.panels[.init("adopted-1")],
		"an edge drop must record a Panel descriptor"
	)
	try expect(
		descriptor.title == "Second Window",
		"the new Panel must be named for the window that created it: \(descriptor.title)"
	)
	try expect(
		descriptor.providerHint?.displayName == "Second"
			&& descriptor.providerHint?.bundleIdentifier == "com.example.provider4243",
		"the provider hint must identify the dropped window's application"
	)
	try expect(
		descriptor.nativeContent == .none,
		"an adopted Panel holds a provider window, not Teaser content"
	)
}

@MainActor
func dragObserverCases() -> [TestCase] {
	[
		.init("duplicate press does not restart the drag", testDuplicatePressDoesNotRestartTheDrag),
		.init("duplicate release ends the drag once", testDuplicateReleaseEndsTheDragOnce),
		.init("monitored and sampled deliveries interleave into one drag", testMonitoredAndSampledDeliveriesInterleaveIntoOneDrag),
		.init("missing drag deliveries still complete the drop", testMissingDragDeliveriesStillCompleteTheDrop),
		.init("missing release is closed by button sampling", testMissingReleaseIsClosedByButtonSampling),
		.init("unqualified drag is never announced", testUnqualifiedDragIsNeverAnnounced),
		.init("cancelled drag ignores its late release", testCancelledDragIgnoresItsLateRelease),
		.init("stopping the observer cancels an in-flight drag", testStoppingTheObserverCancelsAnInFlightDrag),
		.init("rejected candidate is diagnosed once the drag is real", testRejectedCandidateIsDiagnosedOnceTheDragIsReal),
		.init("time advancement gates resampling", testTimeAdvancementGatesResampling),
		.init("button-state samples drive the same chain", testButtonStateSamplesDriveTheSameChain),
		.init("stale button sample after the drop does not readopt", testStaleButtonSampleAfterTheDropDoesNotReadopt),
		.init("sub-threshold nudge is not a drag", testSubThresholdNudgeIsNotADrag),
		.init("correlated resize is not a drag", testCorrelatedResizeIsNotADrag),
		.init("sampler alone keeps the highlight following the pointer", testSamplerAloneKeepsTheHighlightFollowingThePointer),
		.init("release inside the sampling interval still drops", testReleaseInsideTheSamplingIntervalStillDrops),
		.init("cancelled drag stays disarmed while the button is held", testCancelledDragStaysDisarmedWhileTheButtonIsHeld),
		.init("restarted stage observes the next drag", testRestartedStageObservesTheNextDrag),
		.init("rejection is not reported after its press ended", testRejectionIsNotReportedAfterItsPressEnded),
		.init("unmanageable windows are never adopted", testUnmanageableWindowsAreNeverAdopted),
		.init("edge and centre boundary is where the hit test says it is", testEdgeAndCentreBoundaryIsWhereTheHitTestSaysItIs),
		.init("split Panel describes the window that created it", testSplitPanelDescribesTheWindowThatCreatedIt),
	]
}
