import AppKit
import CoreGraphics
import Foundation

// Regressions that drive `DesktopStageOrchestrator`: press, window movement,
// drop-target highlighting, release, binding, layout application, compensation,
// and release. Each case asserts the observable contract — highlight state,
// Panel bindings, the ordered operation log, and frames read back through the
// boundary — rather than the absence of a thrown error.

// MARK: - A. A window dragged into a Panel

@MainActor
private func testDefaultRunTouchesNoDesktopState() throws {
	let harness: Harness = try makeStartedHarness()
	try expect(
		harness.pointer.startCount == 1 && harness.pointer.isRunning,
		"the stage must observe drags through the substituted pointer source only"
	)
	try expect(
		harness.service.promptCount == 0,
		"a default run must never request Accessibility permission"
	)
	try expect(
		harness.log.operations == [.pointerObservationStarted],
		"starting the stage with no adopted window must not touch any window"
	)
	try expect(
		harness.orchestrator.isStageActive && harness.orchestrator.layout != nil,
		"the stage must solve a layout without a real display"
	)
}

@MainActor
private func testQualifiedDragAdoptsEmptyPanel() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let drop: CGPoint = .init(x: target.midX, y: target.midY)

	harness.beginDrag(window, to: drop)
	let highlight: DesktopOverlayDropHighlight = try unwrap(
		harness.orchestrator.dropHighlight,
		"a qualified drag over an empty Panel must expose a drop target"
	)
	try expect(
		highlight.panelID == leftPanelID && highlight.edge == nil
			&& highlight.label == "Adopt window",
		"an empty Panel must highlight as one whole adoption target"
	)
	try expect(
		nsRect(highlight.frame) == target,
		"an empty-Panel highlight must promise the whole Panel frame"
	)

	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"dropping on an empty Panel must bind that exact window"
	)
	let bindIndex: Int = try unwrap(
		harness.log.firstIndex(of: .bind(window.identity)),
		"adoption must establish a lease for the dropped window"
	)
	let applyIndex: Int = try unwrap(
		harness.log.firstIndex(of: .apply(window.identity, target)),
		"adoption must apply the solved Panel frame"
	)
	try expect(
		bindIndex < applyIndex,
		"adoption must establish a lease before applying geometry"
	)
	try expect(
		try harness.log.lastApply(for: window.identity) == target
			&& harness.readBackFrame(window.identity) == target,
		"the adopted window must read back at its Panel frame"
	)
	try expect(
		harness.orchestrator.statusMessage == "Window adopted · Undo available"
			&& harness.orchestrator.canUndo,
		"a completed adoption is one undoable transaction"
	)
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"targets must disappear once the drag ends"
	)
}

@MainActor
private func testHighlightFollowsThePointerAcrossPanels() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let leftCenter: CGPoint = try harness.center(of: leftPanelID)
	let rightCenter: CGPoint = try harness.center(of: rightPanelID)

	harness.beginDrag(window, to: leftCenter)
	try expect(
		harness.orchestrator.dropHighlight?.panelID == leftPanelID,
		"the highlight must name the Panel under the pointer"
	)
	harness.dragWindow(window, to: rightCenter)
	try expect(
		harness.orchestrator.dropHighlight?.panelID == rightPanelID,
		"moving to another Panel must move the highlight with it"
	)
	harness.dragWindow(window, to: .init(x: 2_400, y: 1_400))
	try expect(
		harness.orchestrator.dropHighlight == nil && harness.orchestrator.isDragging,
		"leaving the layout must clear the target while the drag continues"
	)
	harness.dragWindow(window, to: rightCenter)
	try expect(
		harness.orchestrator.dropHighlight?.panelID == rightPanelID,
		"re-entering the layout must restore the target"
	)
	harness.releasePointer(at: rightCenter)
	try expect(
		harness.orchestrator.panelAssignments == [rightPanelID: window.identity],
		"the drop must land in the Panel the last highlight promised"
	)
}

@MainActor
private func testEveryOccupiedEdgeHighlightsItsOwnSplit() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)

	let panel: CGRect = try harness.panelFrame(leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let expectations: [(LayoutEdge, CGPoint, CGRect)] = [
		(
			.leading,
			.init(x: panel.minX + 10, y: panel.midY),
			.init(x: panel.minX, y: panel.minY, width: panel.width / 2, height: panel.height)
		),
		(
			.trailing,
			.init(x: panel.maxX - 10, y: panel.midY),
			.init(x: panel.midX, y: panel.minY, width: panel.width / 2, height: panel.height)
		),
		(
			.top,
			.init(x: panel.midX, y: panel.maxY - 10),
			.init(x: panel.minX, y: panel.midY, width: panel.width, height: panel.height / 2)
		),
		(
			.bottom,
			.init(x: panel.midX, y: panel.minY + 10),
			.init(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height / 2)
		),
	]
	harness.press(second)
	for (edge, point, expectedFrame): (LayoutEdge, CGPoint, CGRect) in expectations {
		harness.dragWindow(second, to: point)
		let highlight: DesktopOverlayDropHighlight = try unwrap(
			harness.orchestrator.dropHighlight,
			"an occupied Panel edge must expose a split target for \(edge)"
		)
		try expect(
			highlight.edge == edge && highlight.label == "Split and adopt",
			"the \(edge) edge must promise a \(edge) split, not \(String(describing: highlight.edge))"
		)
		try expect(
			nsRect(highlight.frame) == expectedFrame,
			"the \(edge) highlight must cover the half the split will create"
		)
	}
	harness.releasePointer(at: .init(x: 2_400, y: 1_400))
	try expect(
		harness.log.bindCount(for: second.identity) == 0
			&& harness.orchestrator.panelAssignments == [leftPanelID: first.identity],
		"a drag released outside every Panel must adopt nothing"
	)
	try expect(
		harness.orchestrator.statusMessage
			== DesktopStageOrchestratorError.missingDropTarget.localizedDescription,
		"a drop with no target must say where the window belongs"
	)
}

// MARK: - B. Content drags never adopt

@MainActor
private func testContentDragNeverAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	let originalFrame: CGRect = window.appKitScreenFrame

	// The pointer travels; the window does not. This is a tab, text, or file drag.
	harness.press(window)
	harness.dragPointerOnly(to: drop)
	try expect(
		harness.orchestrator.dropHighlight == nil,
		"an unqualified drag must never expose a drop target"
	)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0
			&& window.appKitScreenFrame == originalFrame,
		"a content drag must not adopt, lease, or move a window"
	)
}

@MainActor
private func testResizeDragNeverAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)

	// A corner resize moves the pointer and one window edge together. The size
	// changes, so this is not a move and must not qualify.
	harness.press(at: .init(x: window.appKitScreenFrame.maxX, y: window.appKitScreenFrame.minY))
	window.appKitScreenFrame = .init(
		x: window.appKitScreenFrame.minX,
		y: window.appKitScreenFrame.minY,
		width: window.appKitScreenFrame.width + 120,
		height: window.appKitScreenFrame.height + 60
	)
	harness.dragPointerOnly(to: drop)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a resize must not be mistaken for a window drag"
	)
}

@MainActor
private func testWindowMovedWithoutThePointerNeverAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)

	// The application moves its own window while the button happens to be held.
	harness.press(window)
	window.appKitScreenFrame = target
	harness.clock.advance(1)
	harness.pointer.send(
		.monitored(phase: .dragged, appKitScreenLocation: harness.pointerLocation)
	)
	try expect(
		harness.orchestrator.dropHighlight == nil,
		"a window that moves on its own must not become a drag"
	)
	harness.releasePointer()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a window that moved without the pointer must not be adopted"
	)
}

@MainActor
private func testDivergentPointerAndWindowMotionNeverAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)

	// Both move, but not together: the window is not following the pointer.
	harness.press(window)
	window.offset(dx: -400, dy: 300)
	harness.dragPointerOnly(to: drop)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a window moving against the pointer must not be adopted"
	)
}

// MARK: - D. Product contracts for each drop region

@MainActor
private func testOccupiedCenterRejectsUnmanagedWindow() throws {
	let harness: Harness = try makeStartedHarness()
	let adopted: FakeWindow = harness.addWindow()
	try harness.adopt(adopted, into: leftPanelID)

	let intruder: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let center: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(intruder, to: center)
	try expect(
		harness.orchestrator.dropHighlight?.label == "Occupied · use an edge",
		"an occupied center must say so rather than promise a silent replacement"
	)
	harness.releasePointer(at: center)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: adopted.identity],
		"an occupied center must not replace the Panel's existing window"
	)
	try expect(
		harness.orchestrator.statusMessage
			== DesktopStageOrchestratorError.occupiedDropTarget.localizedDescription,
		"the rejection must be reported to the user"
	)
	try expect(
		harness.log.bindCount(for: intruder.identity) == 0,
		"a rejected drop must not leave a lease behind"
	)
}

@MainActor
private func testEdgeDropSplitsAndAdopts() throws {
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
	let occupied: CGRect = try harness.panelFrame(leftPanelID)
	let trailing: CGPoint = .init(x: occupied.maxX - 12, y: occupied.midY)
	harness.beginDrag(second, to: trailing)
	try expect(
		harness.orchestrator.dropHighlight?.edge == .trailing
			&& harness.orchestrator.dropHighlight?.label == "Split and adopt",
		"an occupied edge must promise a local split"
	)
	harness.releasePointer(at: trailing)

	let adoptedPanelID: PanelID = .init("adopted-1")
	try expect(
		harness.orchestrator.panelAssignments == [
			leftPanelID: first.identity,
			adoptedPanelID: second.identity,
		],
		"an edge drop must split the target and bind the new Panel"
	)
	try expect(
		harness.host.createdPanels == [adoptedPanelID],
		"a new Panel must be offered a kind exactly once"
	)
	let adoptedFrame: CGRect = try harness.panelFrame(adoptedPanelID)
	let splitFrame: CGRect = try harness.panelFrame(leftPanelID)
	try expect(
		try harness.readBackFrame(second.identity) == adoptedFrame
			&& harness.readBackFrame(first.identity) == splitFrame,
		"both windows must read back at their solved Panel frames"
	)
	try expect(
		adoptedFrame.minX >= occupied.midX - 1 && splitFrame.maxX <= occupied.midX + 1,
		"a trailing split must place the new Panel on the trailing half"
	)
}

@MainActor
private func testTopEdgeDropSplitsOnTheOtherAxis() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)

	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let occupied: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(second, at: .init(x: occupied.midX, y: occupied.maxY - 12))

	let adoptedPanelID: PanelID = .init("adopted-1")
	let adoptedFrame: CGRect = try harness.panelFrame(adoptedPanelID)
	let splitFrame: CGRect = try harness.panelFrame(leftPanelID)
	try expect(
		harness.orchestrator.panelAssignments[adoptedPanelID] == second.identity,
		"a top-edge drop must adopt into the Panel it created"
	)
	try expect(
		adoptedFrame.minY >= occupied.midY - 1 && splitFrame.maxY <= occupied.midY + 1,
		"a top split must divide the Panel horizontally, not vertically"
	)
	try expect(
		abs(adoptedFrame.width - occupied.width) <= 1,
		"a top split must keep the Panel's full width"
	)
}

@MainActor
private func testManagedWindowMovesToAnEmptyPanelWithoutRebinding() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	let destination: CGPoint = try harness.center(of: rightPanelID)
	harness.beginDrag(window, to: destination)
	try expect(
		harness.orchestrator.isDraggingManagedWindow
			&& harness.orchestrator.dropHighlight?.panelID == rightPanelID,
		"a managed window keeps its identity while it is moved"
	)
	harness.releasePointer(at: destination)

	try expect(
		harness.orchestrator.panelAssignments == [rightPanelID: window.identity],
		"moving a managed window must free the Panel it left"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1,
		"an already leased window must not be leased a second time"
	)
	try expect(
		try harness.readBackFrame(window.identity) == harness.panelFrame(rightPanelID),
		"the moved window must read back in its new Panel"
	)
}

@MainActor
private func testManagedWindowsSwapOnAnOccupiedCenter() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(second, into: rightPanelID)

	let destination: CGPoint = try harness.center(of: rightPanelID)
	harness.beginDrag(first, to: destination)
	try expect(
		harness.orchestrator.dropHighlight?.label == "Swap Panels",
		"dragging a managed window onto an occupied center must promise a swap"
	)
	harness.releasePointer(at: destination)

	try expect(
		harness.orchestrator.panelAssignments == [
			leftPanelID: second.identity,
			rightPanelID: first.identity,
		],
		"an occupied center must swap two managed windows"
	)
	try expect(
		harness.log.bindCount(for: first.identity) == 1
			&& harness.log.bindCount(for: second.identity) == 1,
		"a swap must reuse both existing leases"
	)
	try expect(
		try harness.readBackFrame(first.identity) == harness.panelFrame(rightPanelID)
			&& harness.readBackFrame(second.identity)
				== harness.panelFrame(leftPanelID),
		"both windows must read back in the Panel they swapped into"
	)
}

@MainActor
private func testManagedWindowDroppedOnItsOwnPanelReturns() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	let panel: CGRect = try harness.panelFrame(leftPanelID)

	let nudged: CGPoint = .init(x: panel.midX + 30, y: panel.midY - 20)
	harness.dropWindow(window, at: nudged)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a window dropped back on its own Panel keeps that Panel"
	)
	try expect(
		harness.orchestrator.statusMessage == "Window returned to its Panel",
		"the no-op drop must report itself rather than an error"
	)
	try expect(
		try harness.readBackFrame(window.identity) == panel,
		"a window returned to its Panel must be snapped back to the Panel frame"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1,
		"returning a window must not re-lease it"
	)
}

@MainActor
private func testDropOutsideEveryPanelDetachesWithoutRestoring() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	harness.dropWindow(window, at: .init(x: 2_400, y: 1_400))
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"dropping outside the layout must free the Panel"
	)
	try expect(
		harness.orchestrator.hasRetainedLeases,
		"a detached window keeps its lease until the stage stops"
	)
	try expect(
		!harness.log.operations.contains(where: {
			if case .restoreOriginal = $0 { return true }
			return false
		}),
		"detaching is the user placing the window; Teaser must not move it back"
	)
}

@MainActor
private func testDetachedWindowIsReadoptedWithoutRebinding() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	harness.dropWindow(window, at: .init(x: 2_400, y: 1_400))

	let destination: CGPoint = try harness.center(of: rightPanelID)
	harness.dropWindow(window, at: destination)
	try expect(
		harness.orchestrator.panelAssignments == [rightPanelID: window.identity],
		"a detached window must be adoptable again by dragging it back"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1,
		"re-adoption must reuse the retained lease"
	)
	try expect(
		try harness.readBackFrame(window.identity) == harness.panelFrame(rightPanelID),
		"the re-adopted window must read back in its Panel"
	)
}

@MainActor
private func testUndoReleasesTheAdoptedWindow() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)

	harness.orchestrator.undoLastLayoutChange()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty && !harness.orchestrator.canUndo,
		"undo must return to the state before the adoption"
	)
	try expect(
		harness.log.contains(.release(window.identity, restoringOriginalFrame: true))
			&& window.appKitScreenFrame == frameAtDrop,
		"undo must give the window back where the user dropped it"
	)
	try expect(
		harness.orchestrator.statusMessage == "Last layout change undone",
		"undo must report its own outcome"
	)
}

// MARK: - E. Conditions that must stop an adoption

@MainActor
private func testWindowLostDuringDragCancelsAndDiagnoses() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: drop)
	try expect(
		harness.orchestrator.dropHighlight != nil,
		"the drag must be qualified before the window disappears"
	)

	window.exists = false
	harness.dragWindow(window, to: .init(x: drop.x + 10, y: drop.y))
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"losing the window mid-drag must cancel the pending adoption"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("unavailable") == true,
		"the cancellation reason must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a cancelled drag must not adopt on release"
	)
}

@MainActor
private func testSubstituteWindowAtTheSamePointIsNeverAdopted() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: drop)

	// The dragged window closes and a different application's window takes the
	// same screen position before the button is released.
	window.exists = false
	let substitute: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 99,
		name: "Substitute",
		title: "Substitute Window",
		frame: .init(x: drop.x - 200, y: drop.y - 100, width: 400, height: 200)
	)
	harness.clock.advance(1)
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: drop))
	harness.releasePointer(at: drop)

	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a lost window must not hand its drag to whatever is underneath"
	)
	try expect(
		harness.log.bindCount(for: substitute.identity) == 0
			&& harness.log.bindCount(for: window.identity) == 0,
		"neither the lost window nor its substitute may be leased"
	)
}

@MainActor
private func testPermissionLostDuringDragStopsAdoption() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: drop)

	// Revoking Accessibility does not announce itself: the window reads that
	// production performs mid-drag simply stop answering.
	harness.service.permission = .notAuthorized
	harness.dragWindow(window, to: .init(x: drop.x + 10, y: drop.y))
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"losing Accessibility mid-drag must cancel the pending adoption"
	)
	try expect(
		harness.orchestrator.statusMessage
			== ManagedExternalWindowError.windowUnavailable(window.identity)
				.localizedDescription,
		"the user must be told the window stopped answering: \(harness.orchestrator.statusMessage ?? "none")"
	)
	harness.releasePointer()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a drag that lost permission must not adopt on release"
	)

	// A fresh press is where production checks permission explicitly, so that is
	// where the user learns the real reason.
	harness.press(window)
	harness.dragWindow(window, to: drop)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.statusMessage
			== ManagedExternalWindowError.accessibilityPermissionRequired.localizedDescription,
		"a press without Accessibility must name the permission: \(harness.orchestrator.statusMessage ?? "none")"
	)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"no window may be adopted while Accessibility is denied"
	)
	try expect(
		harness.service.promptCount == 0,
		"losing permission must not make Teaser prompt on its own"
	)
}

@MainActor
private func testWindowOffTheCurrentSpaceAtReleaseIsNotAdopted() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: drop)

	// The window leaves the current Space between qualification and release.
	window.isOnCurrentSpace = false
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a window that left the current Space must not be adopted"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("current Space") == true,
		"the Space mismatch must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"a refused release must still clear the drag state"
	)
}

@MainActor
private func testClosedProviderWindowFreesItsPanel() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	harness.service.close(window)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a closed provider window must free the Panel it occupied"
	)
	try expect(
		!harness.orchestrator.hasRetainedLeases,
		"a destroyed window leaves nothing to restore"
	)
	try expect(
		harness.orchestrator.statusMessage
			== "A provider window closed; its Panel is ready for another window",
		"the freed Panel must be reported: \(harness.orchestrator.statusMessage ?? "none")"
	)
	try expect(
		!harness.orchestrator.isPanelOccupied(leftPanelID),
		"the freed Panel must accept another window"
	)
}

// MARK: - F. Geometry failures, readback, and compensation

@MainActor
private func testWindowThatRefusesToMoveRollsBackAndReports() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	window.rejectsFrames = true

	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a window that cannot take its Panel frame must not stay bound"
	)
	try expect(
		try harness.readBackFrame(window.identity) == frameAtDrop,
		"a failed adoption must leave the window exactly where the user left it"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("cannot fit") == true,
		"the failure reason must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
}

@MainActor
private func testFrameReadbackMismatchRefusesTheAdoption() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	// The provider enforces a minimum size larger than the Panel, so the write
	// succeeds but reads back as a different frame.
	window.minimumSize = .init(width: 1_400, height: 1_400)
	let panel: CGRect = try harness.panelFrame(leftPanelID)

	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a frame that does not read back must not be committed to the model"
	)
	try expect(
		harness.log.contains(
			.applyRejected(
				window.identity,
				requested: panel,
				actual: .init(
					x: panel.minX,
					y: panel.minY,
					width: 1_400,
					height: 1_400
				)
			)
		),
		"the mismatch must be recorded as what was asked and what the window took"
	)
	try expect(
		try harness.readBackFrame(window.identity) == frameAtDrop,
		"a rejected placement must leave the window where the user dropped it"
	)
	try expect(
		harness.log.applies(for: window.identity).isEmpty,
		"a frame that failed readback must never be recorded as applied"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("cannot fit") == true,
		"the readback mismatch must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
}

@MainActor
private func testPartialMultiWindowApplyRollsBackInReverseOrder() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(second, into: rightPanelID)

	let leftBefore: CGRect = try harness.readBackFrame(first.identity)
	let rightBefore: CGRect = try harness.readBackFrame(second.identity)
	// `applySynchronously` walks Panels in Panel-ID order, so "left" is applied
	// before "right" and only "right" fails.
	second.minimumSize = .init(width: 1_400, height: 1_400)
	let logLength: Int = harness.log.operations.count
	harness.setDisplayFrame(.init(x: 0, y: 0, width: 1_600, height: 900))

	let sequence: [FakeWindowOperation] = harness.log.frameOperations(after: logLength)
	try expect(
		sequence.count == 4,
		"one failed relayout must be one apply, one rejection, and two restores: \(sequence)"
	)
	guard case .apply(let appliedIdentity, _) = sequence[0],
		case .applyRejected(let rejectedIdentity, _, _) = sequence[1],
		case .restore(let firstRestored, _) = sequence[2],
		case .restore(let secondRestored, _) = sequence[3]
	else {
		throw TestFailure.assertion("unexpected rollback sequence: \(sequence)")
	}
	try expect(
		appliedIdentity == first.identity && rejectedIdentity == second.identity,
		"the first Panel must be applied before the failing one"
	)
	try expect(
		firstRestored == second.identity && secondRestored == first.identity,
		"compensation must undo applied windows in reverse order"
	)
	try expect(
		try harness.readBackFrame(first.identity) == leftBefore
			&& harness.readBackFrame(second.identity) == rightBefore,
		"a partly applied layout must leave every window where it was"
	)
	try expect(
		harness.orchestrator.panelAssignments == [
			leftPanelID: first.identity,
			rightPanelID: second.identity,
		],
		"a failed relayout must not change which window owns which Panel"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("cannot fit") == true,
		"the failed relayout must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
}

@MainActor
private func testFailedCompensationReportsBothErrorsAndKeepsLeases() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(second, into: rightPanelID)

	second.minimumSize = .init(width: 1_400, height: 1_400)
	first.refusesRestore = true
	harness.setDisplayFrame(.init(x: 0, y: 0, width: 1_600, height: 900))

	let status: String = try unwrap(
		harness.orchestrator.statusMessage,
		"a failed rollback must report something"
	)
	try expect(
		status.contains("cannot fit") && status.contains("Rollback also failed"),
		"the user must be told both what failed and that recovery failed: \(status)"
	)
	try expect(
		harness.log.contains(.restoreRejected(first.identity)),
		"the failed compensation attempt must be recorded, not skipped"
	)
	try expect(
		harness.orchestrator.panelAssignments == [
			leftPanelID: first.identity,
			rightPanelID: second.identity,
		],
		"an unrecovered layout must keep the bindings it had"
	)
	try expect(
		harness.orchestrator.hasRetainedLeases,
		"leases must be retained while a window is still where Teaser put it"
	)
}

@MainActor
private func testUnrestorableWindowRetainsItsLease() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	window.refusesRelease = true
	harness.orchestrator.stopStage()
	try expect(
		harness.orchestrator.hasRetainedLeases,
		"a lease that could not release must be retained for retry"
	)
	try expect(
		harness.orchestrator.statusMessage
			== "Layout stopped; 1 window(s) could not be restored",
		"an incomplete stop must say so: \(harness.orchestrator.statusMessage ?? "none")"
	)

	window.refusesRelease = false
	try expect(
		harness.orchestrator.releaseRetainedLeases()
			&& !harness.orchestrator.hasRetainedLeases,
		"retrying must clear the retained lease once the window cooperates"
	)
	try expect(
		harness.log.contains(.releaseRefused(window.identity))
			&& harness.log.contains(.release(window.identity, restoringOriginalFrame: true)),
		"both the refusal and the successful retry must be recorded"
	)
}

// MARK: - G. Stop, shutdown, and what the user does afterwards

@MainActor
private func testStoppingTheStageRestoresAdoptedWindows() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)

	harness.orchestrator.stopStage()
	let stoppedObservation: Int = try unwrap(
		harness.log.firstIndex(of: .pointerObservationStopped),
		"stopping must release the pointer source"
	)
	let closedChrome: Int = try unwrap(
		harness.log.firstIndex(of: .hostWillStopStage),
		"stopping must close Teaser chrome"
	)
	let released: Int = try unwrap(
		harness.log.firstIndex(of: .release(window.identity, restoringOriginalFrame: true)),
		"stopping must release every lease"
	)
	try expect(
		stoppedObservation < closedChrome && closedChrome < released,
		"observation stops, then chrome closes, then provider leases release"
	)
	try expect(
		try harness.readBackFrame(window.identity) == frameAtDrop,
		"stopping must return every adopted window to where the user dropped it"
	)
	try expect(
		harness.orchestrator.statusMessage == "Layout stopped"
			&& !harness.orchestrator.isStageActive
			&& !harness.orchestrator.hasRetainedLeases,
		"a clean stop must report a clean stop"
	)
	try expect(harness.pointer.stopCount == 1, "stopping must release the pointer source once")
}

@MainActor
private func testStoppingMidDragCancelsWithoutAdopting() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let drop: CGPoint = try harness.center(of: leftPanelID)
	harness.beginDrag(window, to: drop)
	try expect(
		harness.orchestrator.dropHighlight != nil,
		"the drag must be qualified before the stage stops"
	)

	harness.orchestrator.stopStage()
	try expect(
		harness.orchestrator.dropHighlight == nil && !harness.orchestrator.isDragging,
		"stopping must clear the in-flight drag"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 0
			&& harness.orchestrator.panelAssignments.isEmpty,
		"a drag interrupted by a stop must not adopt"
	)
	let length: Int = harness.log.operations.count
	harness.releasePointer(at: drop)
	try expect(
		harness.log.operations.count == length,
		"a release delivered after the stop must reach nothing"
	)
}

@MainActor
private func testStoppedStageNeverMovesTheWindowAgain() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	harness.orchestrator.stopStage()

	// The user puts the window where they want it after Teaser let go.
	window.appKitScreenFrame = .init(x: 320, y: 240, width: 700, height: 500)
	let userFrame: CGRect = window.appKitScreenFrame
	let length: Int = harness.log.operations.count

	harness.setDisplayFrame(.init(x: 0, y: 0, width: 1_600, height: 900))
	harness.orchestrator.relayout(synchronously: true)
	harness.orchestrator.perform(.splitPanel)
	harness.pointer.send(.monitored(phase: .down, appKitScreenLocation: .init(x: 400, y: 400)))

	try expect(
		harness.log.operations.count == length,
		"a stopped stage must not touch any window again: \(harness.log.operations.suffix(4))"
	)
	try expect(
		window.appKitScreenFrame == userFrame,
		"a stopped stage must not overwrite where the user put the window"
	)
}

@MainActor
private func testShutdownReleasesEveryLeaseAndObserver() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)

	harness.orchestrator.shutdown()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& !harness.orchestrator.hasRetainedLeases,
		"shutdown must leave no lease and no assignment behind"
	)
	try expect(
		harness.log.contains(.release(window.identity, restoringOriginalFrame: true))
			&& harness.readBackFrame(window.identity) == frameAtDrop,
		"shutdown must return the window to where the user dropped it"
	)
	try expect(
		!harness.pointer.isRunning && harness.pointer.stopCount == 1,
		"shutdown must stop observing the pointer"
	)
}

// MARK: - H. Environment invariants

@MainActor
private func testDeniedPermissionNeverObservesOrPrompts() throws {
	let harness: Harness = .init(presentation: try testPresentation())
	harness.service.permission = .notAuthorized
	var startError: (any Error)?
	do { try harness.orchestrator.startStage() } catch { startError = error }
	try expect(
		startError as? ManagedExternalWindowError == .accessibilityPermissionRequired,
		"the stage must refuse to observe drags without Accessibility"
	)
	try expect(
		harness.pointer.startCount == 0 && harness.service.promptCount == 0,
		"a denied environment must neither observe nor prompt on its own"
	)
}

@MainActor
private func testInputHandoffPrefersTheAdoptedWindow() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	harness.orchestrator.handInputToVirtualPanel()
	try expect(
		harness.log.contains(.focusAndRaise(window.identity))
			&& harness.host.inputHandoffs.isEmpty,
		"an adopted Panel hands Input Focus to its provider window"
	)

	harness.host.contentPanels = [rightPanelID]
	harness.orchestrator.setVirtualPanel(rightPanelID)
	harness.orchestrator.handInputToVirtualPanel()
	try expect(
		harness.host.inputHandoffs == [rightPanelID],
		"a Teaser-owned Panel hands Input Focus to the host instead"
	)
}

@MainActor
private func testNoWindowIsEverDisplayed() throws {
	try expect(
		!NSApplication.shared.windows.contains(where: \.isVisible),
		"adoption tests must not display any window"
	)
}

@MainActor
func adoptionCases() -> [TestCase] {
	[
		.init("default run touches no desktop state", testDefaultRunTouchesNoDesktopState),
		.init("qualified drag adopts an empty Panel", testQualifiedDragAdoptsEmptyPanel),
		.init("highlight follows the pointer across Panels", testHighlightFollowsThePointerAcrossPanels),
		.init("every occupied edge highlights its own split", testEveryOccupiedEdgeHighlightsItsOwnSplit),
		.init("content drag never adopts", testContentDragNeverAdopts),
		.init("resize drag never adopts", testResizeDragNeverAdopts),
		.init("window moved without the pointer never adopts", testWindowMovedWithoutThePointerNeverAdopts),
		.init("divergent pointer and window motion never adopts", testDivergentPointerAndWindowMotionNeverAdopts),
		.init("occupied center rejects an unmanaged window", testOccupiedCenterRejectsUnmanagedWindow),
		.init("edge drop splits and adopts", testEdgeDropSplitsAndAdopts),
		.init("top-edge drop splits on the other axis", testTopEdgeDropSplitsOnTheOtherAxis),
		.init("managed window moves to an empty Panel without rebinding", testManagedWindowMovesToAnEmptyPanelWithoutRebinding),
		.init("managed windows swap on an occupied center", testManagedWindowsSwapOnAnOccupiedCenter),
		.init("managed window dropped on its own Panel returns", testManagedWindowDroppedOnItsOwnPanelReturns),
		.init("drop outside every Panel detaches without restoring", testDropOutsideEveryPanelDetachesWithoutRestoring),
		.init("detached window is readopted without rebinding", testDetachedWindowIsReadoptedWithoutRebinding),
		.init("undo releases the adopted window", testUndoReleasesTheAdoptedWindow),
		.init("window lost during drag cancels and diagnoses", testWindowLostDuringDragCancelsAndDiagnoses),
		.init("substitute window at the same point is never adopted", testSubstituteWindowAtTheSamePointIsNeverAdopted),
		.init("permission lost during drag stops adoption", testPermissionLostDuringDragStopsAdoption),
		.init("window off the current Space at release is not adopted", testWindowOffTheCurrentSpaceAtReleaseIsNotAdopted),
		.init("closed provider window frees its Panel", testClosedProviderWindowFreesItsPanel),
		.init("window that refuses to move rolls back and reports", testWindowThatRefusesToMoveRollsBackAndReports),
		.init("frame readback mismatch refuses the adoption", testFrameReadbackMismatchRefusesTheAdoption),
		.init("partial multi-window apply rolls back in reverse order", testPartialMultiWindowApplyRollsBackInReverseOrder),
		.init("failed compensation reports both errors and keeps leases", testFailedCompensationReportsBothErrorsAndKeepsLeases),
		.init("unrestorable window retains its lease", testUnrestorableWindowRetainsItsLease),
		.init("stopping the stage restores adopted windows", testStoppingTheStageRestoresAdoptedWindows),
		.init("stopping mid-drag cancels without adopting", testStoppingMidDragCancelsWithoutAdopting),
		.init("stopped stage never moves the window again", testStoppedStageNeverMovesTheWindowAgain),
		.init("shutdown releases every lease and observer", testShutdownReleasesEveryLeaseAndObserver),
		.init("denied permission never observes or prompts", testDeniedPermissionNeverObservesOrPrompts),
		.init("input handoff prefers the adopted window", testInputHandoffPrefersTheAdoptedWindow),
		.init("no window is ever displayed", testNoWindowIsEverDisplayed),
		.init("content Panel is never offered as a swap", testContentPanelIsNeverOfferedAsASwap),
		.init("content Panel is occupied for an unmanaged window", testContentPanelIsOccupiedForAnUnmanagedWindow),
		.init("managed window split onto another edge frees its old Panel", testManagedWindowSplitOntoAnotherEdgeFreesItsOldPanel),
		.init("failed split leaves no half-created Panel", testFailedSplitLeavesNoHalfCreatedPanel),
		.init("drops move Virtual Focus to where the window landed", testDropsMoveVirtualFocusToWhereTheWindowLanded),
		.init("window moved across Workspaces follows its focus", testWindowMovedAcrossWorkspacesFollowsItsFocus),
		.init("stopping leaves a detached window where the user put it", testStoppingLeavesADetachedWindowWhereTheUserPutIt),
		.init("user-moved window is not snapped back on stop", testUserMovedWindowIsNotSnappedBackOnStop),
		.init("undo that cannot release reports and retains its lease", testUndoThatCannotReleaseReportsAndRetainsItsLease),
		.init("compensation continues past a window that refuses restoration", testCompensationContinuesPastAWindowThatRefusesRestoration),
	]
}

// MARK: - I. Gaps closed after the first audit of this matrix

@MainActor
private func testContentPanelIsNeverOfferedAsASwap() throws {
	let harness: Harness = .init(presentation: try testPresentationWithContentPanel())
	try harness.orchestrator.startStage()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	let notesCenter: CGPoint = try harness.center(of: rightPanelID)
	harness.beginDrag(window, to: notesCenter)
	try expect(
		harness.orchestrator.dropHighlight?.label == "Occupied · use an edge",
		"a Panel holding Teaser content has no window to trade: \(harness.orchestrator.dropHighlight?.label ?? "none")"
	)
	harness.releasePointer(at: notesCenter)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a rejected content-Panel drop must leave the window in the Panel it had"
	)
	try expect(
		harness.orchestrator.statusMessage
			== DesktopStageOrchestratorError.occupiedDropTarget.localizedDescription,
		"the rejection must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
	try expect(
		try harness.readBackFrame(window.identity) == harness.panelFrame(leftPanelID),
		"the window must be snapped back to the Panel it still owns"
	)
}

@MainActor
private func testContentPanelIsOccupiedForAnUnmanagedWindow() throws {
	let harness: Harness = .init(presentation: try testPresentationWithContentPanel())
	try harness.orchestrator.startStage()
	let window: FakeWindow = harness.addWindow()

	let notesCenter: CGPoint = try harness.center(of: rightPanelID)
	harness.beginDrag(window, to: notesCenter)
	try expect(
		harness.orchestrator.dropHighlight?.label == "Occupied · use an edge"
			&& harness.orchestrator.dropHighlight?.edge == nil,
		"Teaser content occupies its Panel: \(harness.orchestrator.dropHighlight?.label ?? "none")"
	)
	harness.releasePointer(at: notesCenter)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.log.bindCount(for: window.identity) == 0,
		"a window must never replace Teaser-owned content"
	)

	// The same Panel still splits, which is how a window joins that region.
	let panel: CGRect = try harness.panelFrame(rightPanelID)
	harness.dropWindow(window, at: .init(x: panel.maxX - 12, y: panel.midY))
	let adoptedPanelID: PanelID = .init("adopted-1")
	try expect(
		harness.orchestrator.panelAssignments == [adoptedPanelID: window.identity],
		"an edge drop beside Teaser content must split and adopt"
	)
	try expect(
		try harness.readBackFrame(window.identity) == harness.panelFrame(adoptedPanelID),
		"the split window must read back in the Panel it created"
	)
}

@MainActor
private func testManagedWindowSplitOntoAnotherEdgeFreesItsOldPanel() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(second, into: rightPanelID)

	let target: CGRect = try harness.panelFrame(rightPanelID)
	harness.dropWindow(first, at: .init(x: target.maxX - 12, y: target.midY))

	let adoptedPanelID: PanelID = .init("adopted-1")
	try expect(
		harness.orchestrator.panelAssignments == [
			rightPanelID: second.identity,
			adoptedPanelID: first.identity,
		],
		"splitting a managed window into another Panel must free the Panel it left"
	)
	try expect(
		harness.log.bindCount(for: first.identity) == 1,
		"a split move must reuse the existing lease"
	)
	try expect(
		try harness.readBackFrame(first.identity) == harness.panelFrame(adoptedPanelID)
			&& harness.readBackFrame(second.identity)
				== harness.panelFrame(rightPanelID),
		"both windows must read back in their solved Panels"
	)
	try expect(
		harness.orchestrator.layout?.panelFrames[leftPanelID] != nil
			&& !harness.orchestrator.isPanelOccupied(leftPanelID),
		"the Panel the window left must stay as an empty slot for another window"
	)
}

@MainActor
private func testFailedSplitLeavesNoHalfCreatedPanel() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	second.minimumSize = .init(width: 1_800, height: 1_800)

	let target: CGRect = try harness.panelFrame(leftPanelID)
	let frameAtDrop: CGRect = harness.dropWindow(
		second,
		at: .init(x: target.maxX - 12, y: target.midY)
	)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: first.identity],
		"a split whose window cannot fit must not bind it"
	)
	try expect(
		harness.orchestrator.layout?.panelFrames[.init("adopted-1")] == nil
			&& harness.host.createdPanels.isEmpty,
		"a failed split must not leave the Panel it was creating behind"
	)
	try expect(
		try harness.readBackFrame(second.identity) == frameAtDrop
			&& harness.readBackFrame(first.identity) == harness.panelFrame(leftPanelID),
		"a failed split must leave both windows where they were"
	)
}

@MainActor
private func testDropsMoveVirtualFocusToWhereTheWindowLanded() throws {
	let harness: Harness = try makeStartedHarness()
	try expect(
		harness.orchestrator.presentation.virtualFocus.panelID == leftPanelID,
		"the fixture starts focused on the left Panel"
	)
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: rightPanelID)
	try expect(
		harness.orchestrator.presentation.virtualFocus
			== .init(workspaceID: testWorkspaceID, panelID: rightPanelID),
		"an adoption must focus the Panel the window landed in"
	)

	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 100, y: 20, width: 400, height: 200)
	)
	let occupied: CGRect = try harness.panelFrame(rightPanelID)
	harness.dropWindow(second, at: .init(x: occupied.maxX - 12, y: occupied.midY))
	let adoptedPanelID: PanelID = .init("adopted-1")
	try expect(
		harness.orchestrator.presentation.virtualFocus
			== .init(workspaceID: testWorkspaceID, panelID: adoptedPanelID),
		"a split must focus the Panel it created"
	)

	// A rejected drop changes nothing, focus included.
	let third: FakeWindow = harness.addWindow(
		pid: thirdProviderPID,
		windowID: 12,
		frame: .init(x: 100, y: 20, width: 400, height: 200)
	)
	harness.dropWindow(third, at: try harness.center(of: adoptedPanelID))
	try expect(
		harness.orchestrator.presentation.virtualFocus
			== .init(workspaceID: testWorkspaceID, panelID: adoptedPanelID),
		"a rejected drop must not move Virtual Focus"
	)
}

@MainActor
private func testWindowMovedAcrossWorkspacesFollowsItsFocus() throws {
	let harness: Harness = .init(presentation: try testPresentationWithTwoWorkspaces())
	try harness.orchestrator.startStage()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	let destination: CGPoint = try harness.center(of: betaPanelID)
	harness.beginDrag(window, to: destination)
	try expect(
		harness.orchestrator.dropHighlight?.workspaceID == betaWorkspaceID,
		"a highlight in another Workspace must name that Workspace"
	)
	harness.releasePointer(at: destination)

	try expect(
		harness.orchestrator.panelAssignments == [betaPanelID: window.identity],
		"a window must be movable into another Workspace's Panel"
	)
	try expect(
		harness.orchestrator.presentation.virtualFocus
			== .init(workspaceID: betaWorkspaceID, panelID: betaPanelID),
		"moving across Workspaces must move Workspace focus with the window"
	)
	try expect(
		harness.log.bindCount(for: window.identity) == 1
			&& harness.readBackFrame(window.identity) == harness.panelFrame(betaPanelID),
		"a cross-Workspace move must reuse the lease and land the window"
	)
}

@MainActor
private func testStoppingLeavesADetachedWindowWhereTheUserPutIt() throws {
	let harness: Harness = try makeStartedHarness()
	let detached: FakeWindow = harness.addWindow()
	let adopted: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(detached, into: leftPanelID)
	// A lease restores the frame the window had when it was bound, which is
	// where the user's own drag left it.
	let adoptedFrameAtDrop: CGRect = try harness.adopt(adopted, into: rightPanelID)

	// The user pulls one window out of the layout and parks it.
	let parked: CGRect = harness.dropWindow(detached, at: .init(x: 2_400, y: 1_400))

	harness.orchestrator.stopStage()
	try expect(
		harness.log.contains(.release(detached.identity, restoringOriginalFrame: false)),
		"a detached window must be released without a restoration"
	)
	try expect(
		!harness.log.contains(.release(detached.identity, restoringOriginalFrame: true))
			&& !harness.log.contains(where: {
				if case .restoreOriginal(let identity, _) = $0 {
					return identity == detached.identity
				}
				return false
			}),
		"stopping must never pull a parked window back to its pre-adoption frame"
	)
	try expect(
		try harness.readBackFrame(detached.identity) == parked,
		"the parked window must stay exactly where the user left it"
	)
	try expect(
		harness.log.contains(.release(adopted.identity, restoringOriginalFrame: true))
			&& harness.readBackFrame(adopted.identity) == adoptedFrameAtDrop,
		"the still-adopted window in the same stop must be restored"
	)
	try expect(
		harness.orchestrator.statusMessage == "Layout stopped"
			&& !harness.orchestrator.hasRetainedLeases,
		"a stop that handled both windows must report a clean stop"
	)
}

@MainActor
private func testUserMovedWindowIsNotSnappedBackOnStop() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)

	// The user moves the window themselves; no pointer event tells Teaser.
	let userFrame: CGRect = .init(x: 320, y: 240, width: 700, height: 500)
	window.appKitScreenFrame = userFrame

	harness.orchestrator.stopStage()
	try expect(
		try harness.readBackFrame(window.identity) == userFrame,
		"a window the user moved must not be pulled back on stop"
	)
	try expect(
		!harness.log.contains(where: {
			if case .restoreOriginal(let identity, _) = $0 { return identity == window.identity }
			return false
		}),
		"Teaser must not restore a frame it no longer owns"
	)
	try expect(
		harness.log.contains(.release(window.identity, restoringOriginalFrame: true))
			&& harness.orchestrator.statusMessage == "Layout stopped",
		"the lease must still release cleanly"
	)
}

@MainActor
private func testUndoThatCannotReleaseReportsAndRetainsItsLease() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let frameAtDrop: CGRect = try harness.adopt(window, into: leftPanelID)
	let panel: CGRect = try harness.panelFrame(leftPanelID)

	window.refusesRelease = true
	harness.orchestrator.undoLastLayoutChange()
	try expect(
		harness.orchestrator.statusMessage?
			.contains("Undo could not restore every provider") == true,
		"an undo that cannot let go must say so: \(harness.orchestrator.statusMessage ?? "none")"
	)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"a failed undo must not pretend the adoption was reversed"
	)
	try expect(
		harness.orchestrator.hasRetainedLeases
			&& harness.log.contains(.releaseRefused(window.identity)),
		"the lease must be retained after a refused release"
	)
	try expect(
		try harness.readBackFrame(window.identity) == panel,
		"a window Teaser still holds must stay in its Panel"
	)

	window.refusesRelease = false
	harness.orchestrator.undoLastLayoutChange()
	try expect(
		try harness.orchestrator.panelAssignments.isEmpty
			&& harness.readBackFrame(window.identity) == frameAtDrop,
		"retrying the undo must give the window back where the user dropped it"
	)
}

@MainActor
private func testCompensationContinuesPastAWindowThatRefusesRestoration() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	try harness.adopt(first, into: leftPanelID)
	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	try harness.adopt(second, into: rightPanelID)
	let third: FakeWindow = harness.addWindow(
		pid: thirdProviderPID,
		windowID: 12,
		frame: .init(x: 1_100, y: 20, width: 400, height: 200)
	)
	let rightFrame: CGRect = try harness.panelFrame(rightPanelID)
	harness.dropWindow(third, at: .init(x: rightFrame.maxX - 12, y: rightFrame.midY))
	let adoptedPanelID: PanelID = .init("adopted-1")
	try expect(
		harness.orchestrator.panelAssignments.count == 3,
		"the fixture needs three adopted windows to order a rollback"
	)

	// Panels apply in Panel-ID order: adopted-1, left, right. The last one
	// fails, and the middle one refuses to be put back.
	let framesBefore: [ExternalWindowIdentity: CGRect] = [
		third.identity: try harness.readBackFrame(third.identity),
		first.identity: try harness.readBackFrame(first.identity),
		second.identity: try harness.readBackFrame(second.identity),
	]
	second.minimumSize = .init(width: 1_800, height: 1_800)
	first.refusesRestore = true
	let logLength: Int = harness.log.operations.count
	harness.setDisplayFrame(.init(x: 0, y: 0, width: 1_600, height: 900))

	let sequence: [FakeWindowOperation] = harness.log.frameOperations(after: logLength)
	try expect(
		sequence.contains(.restoreRejected(first.identity)),
		"the refusing window must be attempted, not skipped: \(sequence)"
	)
	try expect(
		sequence.contains(where: {
			if case .restore(let identity, _) = $0 { return identity == third.identity }
			return false
		}),
		"compensation must continue past the refusal to the window behind it: \(sequence)"
	)
	try expect(
		try harness.readBackFrame(third.identity) == framesBefore[third.identity],
		"the window behind the refusal must still be put back"
	)
	try expect(
		try harness.readBackFrame(first.identity)
			== harness.log.lastApply(for: first.identity),
		"an unrestorable window must stay exactly where Teaser last put it"
	)
	try expect(
		harness.orchestrator.panelAssignments == [
			leftPanelID: first.identity,
			rightPanelID: second.identity,
			adoptedPanelID: third.identity,
		],
		"a failed relayout must not change which window owns which Panel"
	)
	_ = framesBefore[second.identity]
}
