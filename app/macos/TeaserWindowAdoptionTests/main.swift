import AppKit
import CoreGraphics
import Darwin
import Foundation

// Drives the production window-adoption orchestration with a substituted
// external-window environment: deterministic pointer events, a manual clock, a
// fixture window world, and a recording host. Nothing here installs a global
// event monitor, shows a window, requests Accessibility permission, or touches a
// window the user owns.

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message): return message
		}
	}
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

private func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
	guard let value else { throw TestFailure.assertion(message) }
	return value
}

// MARK: - Substituted environment

private enum FakeWindowOperation: Equatable {
	case bind(ExternalWindowIdentity)
	case apply(ExternalWindowIdentity, CGRect)
	case applyCoalesced(ExternalWindowIdentity, CGRect)
	case restore(ExternalWindowIdentity, CGRect)
	case restoreOriginal(ExternalWindowIdentity, CGRect)
	case raise(ExternalWindowIdentity)
	case focusAndRaise(ExternalWindowIdentity)
	case release(ExternalWindowIdentity, restoringOriginalFrame: Bool)
}

@MainActor
private final class FakeWindow {
	let identity: ExternalWindowIdentity
	let applicationName: String
	let title: String
	var appKitScreenFrame: CGRect
	var exists: Bool = true
	var isOnCurrentSpace: Bool = true
	var rejectsFrames: Bool = false
	var refusesRelease: Bool = false

	init(
		processIdentifier: pid_t,
		windowID: CGWindowID,
		applicationName: String,
		title: String,
		appKitScreenFrame: CGRect
	) {
		self.identity = .init(processIdentifier: processIdentifier, windowID: windowID)
		self.applicationName = applicationName
		self.title = title
		self.appKitScreenFrame = appKitScreenFrame
	}

	var snapshot: ManagedExternalWindowSnapshot {
		.init(
			identity: identity,
			applicationName: applicationName,
			title: title,
			appKitScreenFrame: appKitScreenFrame,
			isMinimized: false
		)
	}

	func offset(dx: CGFloat, dy: CGFloat) {
		appKitScreenFrame = appKitScreenFrame.offsetBy(dx: dx, dy: dy)
	}
}

@MainActor
private final class FakeWindowHandle: ExternalWindowHandle {
	let identity: ExternalWindowIdentity
	let initialSnapshot: ManagedExternalWindowSnapshot

	init(window: FakeWindow) {
		self.identity = window.identity
		self.initialSnapshot = window.snapshot
	}
}

@MainActor
private final class FakeExternalWindowService: ExternalWindowService {
	var permission: ExternalWindowPermissionStatus = .authorized
	/// Front-to-back, exactly as the window server orders the current Space.
	var windows: [FakeWindow] = []
	private(set) var promptCount: Int = 0
	private(set) var operations: [FakeWindowOperation] = []
	private(set) var snapshotReads: Int = 0

	func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		if prompt { promptCount += 1 }
		return permission
	}

	func selectWindow(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t>
	) throws -> any ExternalWindowHandle {
		guard permission == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		guard let window: FakeWindow = windows.first(where: {
			$0.exists && $0.isOnCurrentSpace && $0.appKitScreenFrame.contains(point)
		}), !excludingProcessIdentifiers.contains(window.identity.processIdentifier) else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		return FakeWindowHandle(window: window)
	}

	func selectWindow(identity: ExternalWindowIdentity) throws -> any ExternalWindowHandle {
		FakeWindowHandle(window: try require(identity))
	}

	func validateIdentity(of handle: any ExternalWindowHandle) throws {
		_ = try require(handle.identity)
	}

	func validateCurrentSpace(of handle: any ExternalWindowHandle) throws {
		let window: FakeWindow = try require(handle.identity)
		guard window.isOnCurrentSpace else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace(handle.identity)
		}
	}

	func snapshot(
		of handle: any ExternalWindowHandle
	) throws -> ManagedExternalWindowSnapshot {
		snapshotReads += 1
		return try require(handle.identity).snapshot
	}

	func bundleIdentifier(forProcessIdentifier processIdentifier: pid_t) -> String? {
		"com.example.provider\(processIdentifier)"
	}

	func makeLease(
		onEvent: @escaping ManagedExternalWindowEventHandler,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) -> any ExternalWindowLease {
		FakeExternalWindowLease(service: self, onApplyError: onApplyError)
	}

	func window(_ identity: ExternalWindowIdentity) throws -> FakeWindow {
		try require(identity)
	}

	func record(_ operation: FakeWindowOperation) {
		operations.append(operation)
	}

	func lastApply(for identity: ExternalWindowIdentity) -> CGRect? {
		for operation: FakeWindowOperation in operations.reversed() {
			guard case .apply(let applied, let frame) = operation, applied == identity else {
				continue
			}
			return frame
		}
		return nil
	}

	private func require(_ identity: ExternalWindowIdentity) throws -> FakeWindow {
		guard let window: FakeWindow = windows.first(where: {
			$0.identity == identity && $0.exists
		}) else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
		}
		return window
	}
}

@MainActor
private final class FakeExternalWindowLease: ExternalWindowLease {
	private(set) var identity: ExternalWindowIdentity?

	private let service: FakeExternalWindowService
	private let onApplyError: ManagedExternalWindowApplyErrorHandler
	private var originalFrame: CGRect?
	private var lastAppliedFrame: CGRect?

	init(
		service: FakeExternalWindowService,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) {
		self.service = service
		self.onApplyError = onApplyError
	}

	@discardableResult
	func bind(handle: any ExternalWindowHandle) throws -> ManagedExternalWindowSnapshot {
		guard handle is FakeWindowHandle else {
			throw ManagedExternalWindowError.windowUnavailable(handle.identity)
		}
		return try bind(identity: handle.identity)
	}

	@discardableResult
	func bind(identity: ExternalWindowIdentity) throws -> ManagedExternalWindowSnapshot {
		guard self.identity == nil else { throw ManagedExternalWindowError.alreadyBound }
		let window: FakeWindow = try service.window(identity)
		self.identity = identity
		originalFrame = window.appKitScreenFrame
		lastAppliedFrame = nil
		service.record(.bind(identity))
		return window.snapshot
	}

	func snapshot() throws -> ManagedExternalWindowSnapshot {
		try boundWindow().snapshot
	}

	@discardableResult
	func apply(appKitScreenFrame frame: CGRect) throws -> ManagedExternalWindowSnapshot {
		let window: FakeWindow = try boundWindow()
		guard window.appKitScreenFrame != frame else {
			lastAppliedFrame = frame
			return window.snapshot
		}
		guard !window.rejectsFrames else {
			throw ManagedExternalWindowError.windowCannotFit(
				requested: frame,
				actual: window.appKitScreenFrame
			)
		}
		window.appKitScreenFrame = frame
		lastAppliedFrame = frame
		service.record(.apply(window.identity, frame))
		return window.snapshot
	}

	func applyCoalesced(appKitScreenFrame frame: CGRect) {
		do {
			let window: FakeWindow = try boundWindow()
			guard window.appKitScreenFrame != frame else { return }
			window.appKitScreenFrame = frame
			lastAppliedFrame = frame
			service.record(.applyCoalesced(window.identity, frame))
		} catch let error as ManagedExternalWindowError {
			onApplyError(error)
		} catch {
			onApplyError(.windowUnavailable(identity))
		}
	}

	@discardableResult
	func restore(
		snapshot: ManagedExternalWindowSnapshot
	) throws -> ManagedExternalWindowSnapshot {
		let window: FakeWindow = try boundWindow()
		guard snapshot.identity == window.identity else {
			throw ManagedExternalWindowError.snapshotIdentityMismatch(
				expected: window.identity,
				actual: snapshot.identity
			)
		}
		window.appKitScreenFrame = snapshot.appKitScreenFrame
		lastAppliedFrame = snapshot.appKitScreenFrame
		service.record(.restore(window.identity, snapshot.appKitScreenFrame))
		return window.snapshot
	}

	func raise() throws {
		service.record(.raise(try boundWindow().identity))
	}

	func focusAndRaise() throws {
		service.record(.focusAndRaise(try boundWindow().identity))
	}

	@discardableResult
	func release(restoringOriginalFrame: Bool) -> Bool {
		guard let identity else { return true }
		guard let window: FakeWindow = try? service.window(identity) else {
			self.identity = nil
			return true
		}
		guard !window.refusesRelease else { return false }
		if restoringOriginalFrame,
			let originalFrame,
			let lastAppliedFrame,
			window.appKitScreenFrame == lastAppliedFrame
		{
			window.appKitScreenFrame = originalFrame
			service.record(.restoreOriginal(identity, originalFrame))
		}
		service.record(.release(identity, restoringOriginalFrame: restoringOriginalFrame))
		self.identity = nil
		originalFrame = nil
		lastAppliedFrame = nil
		return true
	}

	private func boundWindow() throws -> FakeWindow {
		guard let identity else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		return try service.window(identity)
	}
}

@MainActor
private final class ManualClock: ExternalWindowClock {
	private(set) var now: TimeInterval = 1_000

	func advance(_ interval: TimeInterval) {
		now += interval
	}
}

@MainActor
private final class RecordingPointerSource: ExternalWindowPointerSource {
	private(set) var startCount: Int = 0
	private(set) var stopCount: Int = 0
	private var handler: ExternalWindowPointerEventHandler?

	var isRunning: Bool { handler != nil }

	func start(handler: @escaping ExternalWindowPointerEventHandler) throws {
		guard self.handler == nil else { return }
		startCount += 1
		self.handler = handler
	}

	func stop() {
		if handler != nil { stopCount += 1 }
		handler = nil
	}

	func send(_ event: ExternalWindowPointerEvent) {
		handler?(event)
	}
}

@MainActor
private final class CountingIdentifierSource: DesktopStageIdentifierSource {
	private var panelCount: Int = 0
	private var splitCount: Int = 0

	func makePanelID(prefix: String) -> PanelID {
		panelCount += 1
		return .init("\(prefix)-\(panelCount)")
	}

	func makeSplitID(prefix: String) -> LayoutSplitID {
		splitCount += 1
		return .init("\(prefix)-\(splitCount)")
	}
}

@MainActor
private final class RecordingStageHost: DesktopStageOrchestratorHost {
	/// Panels the host claims as Teaser-owned content.
	var contentPanels: Set<PanelID> = []
	private(set) var stateChanges: Int = 0
	private(set) var solvedLayouts: [PresentationLayout] = []
	private(set) var createdPanels: [PanelID] = []
	private(set) var raisedContent: [PanelID] = []
	private(set) var inputHandoffs: [PanelID] = []
	private(set) var saveRequests: Int = 0
	private(set) var willStopCount: Int = 0

	func orchestratorDidChangeState(_ orchestrator: DesktopStageOrchestrator) {
		stateChanges += 1
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didSolve layout: PresentationLayout
	) {
		solvedLayouts.append(layout)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		raiseContentIn panelID: PanelID
	) {
		raisedContent.append(panelID)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		handInputToContentIn panelID: PanelID
	) -> Bool {
		guard contentPanels.contains(panelID) else { return false }
		inputHandoffs.append(panelID)
		return true
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didCreatePanel panelID: PanelID
	) {
		createdPanels.append(panelID)
	}

	func orchestratorDidRequestSave(_ orchestrator: DesktopStageOrchestrator) {
		saveRequests += 1
	}

	func orchestratorWillStopStage(_ orchestrator: DesktopStageOrchestrator) {
		willStopCount += 1
	}
}

// MARK: - Fixture

private let testDisplayID: DisplayID = .init("test-display")
private let testWorkspaceID: WorkspaceID = .init("alpha")
private let leftPanelID: PanelID = .init("left")
private let rightPanelID: PanelID = .init("right")
private let providerPID: pid_t = 4_242
private let secondProviderPID: pid_t = 4_243

private func testPresentation() throws -> WorkspacePresentation {
	func panel(_ id: PanelID, _ title: String) -> PanelDescriptor {
		.init(
			id: id,
			title: title,
			kindID: .generic,
			providerHint: nil,
			profileOverride: nil,
			nativeContent: .none
		)
	}
	let workspace: WorkspaceDescriptor = .init(
		id: testWorkspaceID,
		title: "Alpha",
		detail: "Deterministic adoption fixture",
		displayAffinity: testDisplayID,
		panelTree: .split(
			id: .init("alpha-root"),
			axis: .horizontal,
			preference: .init(desiredRatio: 0.5),
			first: .leaf(leftPanelID),
			second: .leaf(rightPanelID)
		),
		panels: [
			leftPanelID: panel(leftPanelID, "Left"),
			rightPanelID: panel(rightPanelID, "Right"),
		]
	)
	return .init(
		mode: .tiled,
		virtualFocus: .init(workspaceID: testWorkspaceID, panelID: leftPanelID),
		displayLayouts: [
			testDisplayID: .init(displayID: testDisplayID, workspaceTree: .leaf(testWorkspaceID)),
		],
		workspaces: [testWorkspaceID: workspace],
		panelKinds: try .init()
	)
}

@MainActor
private struct Harness {
	let service: FakeExternalWindowService = .init()
	let clock: ManualClock = .init()
	let pointer: RecordingPointerSource = .init()
	let host: RecordingStageHost = .init()
	let orchestrator: DesktopStageOrchestrator

	init(presentation: WorkspacePresentation) {
		orchestrator = .init(
			presentation: presentation,
			notes: [:],
			service: service,
			clock: clock,
			pointerSource: pointer,
			identifiers: CountingIdentifierSource()
		)
		orchestrator.host = host
		orchestrator.setDisplays([
			.init(id: testDisplayID, frame: .init(x: 0, y: 0, width: 2_000, height: 1_000)),
		])
	}

	func addWindow(
		pid: pid_t = providerPID,
		windowID: CGWindowID = 10,
		name: String = "Provider",
		title: String = "Provider Window",
		frame: CGRect = .init(x: 1_200, y: 600, width: 600, height: 300)
	) -> FakeWindow {
		let window: FakeWindow = .init(
			processIdentifier: pid,
			windowID: windowID,
			applicationName: name,
			title: title,
			appKitScreenFrame: frame
		)
		service.windows.insert(window, at: 0)
		return window
	}

	func panelFrame(_ panelID: PanelID) throws -> CGRect {
		nsRect(try unwrap(orchestrator.layout?.panelFrames[panelID], "missing solved Panel \(panelID.rawValue)"))
	}

	func press(_ window: FakeWindow) {
		pointer.send(
			.monitored(
				phase: .down,
				appKitScreenLocation: CGPoint(
					x: window.appKitScreenFrame.midX,
					y: window.appKitScreenFrame.maxY - 8
				)
			)
		)
	}

	/// Moves the pointer and the window together, which is what makes a drag a
	/// window drag rather than a content drag.
	func dragWindow(_ window: FakeWindow, to point: CGPoint, from origin: CGPoint) {
		window.offset(dx: point.x - origin.x, dy: point.y - origin.y)
		clock.advance(1)
		pointer.send(.monitored(phase: .dragged, appKitScreenLocation: point))
	}

	func releasePointer(at point: CGPoint) {
		clock.advance(1)
		pointer.send(.monitored(phase: .up, appKitScreenLocation: point))
	}

	/// A complete qualified title-bar drag from the window's own title bar to
	/// `point`, leaving the drop unfinished so highlights stay observable.
	@discardableResult
	func beginDrag(_ window: FakeWindow, to point: CGPoint) -> CGPoint {
		let grab: CGPoint = .init(
			x: window.appKitScreenFrame.midX,
			y: window.appKitScreenFrame.maxY - 8
		)
		press(window)
		dragWindow(window, to: point, from: grab)
		return point
	}

	/// Completes a drag and returns the frame the user left the window at, which
	/// is the frame a graceful release must restore.
	@discardableResult
	func dropWindow(_ window: FakeWindow, at point: CGPoint) -> CGRect {
		beginDrag(window, to: point)
		let frameAtDrop: CGRect = window.appKitScreenFrame
		releasePointer(at: point)
		return frameAtDrop
	}
}

@MainActor
private func makeStartedHarness() throws -> Harness {
	let harness: Harness = .init(presentation: try testPresentation())
	try harness.orchestrator.startStage()
	return harness
}

// MARK: - Tests

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
		harness.service.operations.isEmpty,
		"starting the stage with no adopted window must not move any window"
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

	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments == [leftPanelID: window.identity],
		"dropping on an empty Panel must bind that exact window"
	)
	try expect(
		harness.service.operations.contains(.bind(window.identity)),
		"adoption must establish a lease before applying geometry"
	)
	try expect(
		harness.service.lastApply(for: window.identity) == target
			&& window.appKitScreenFrame == target,
		"the adopted window must be moved to its Panel frame"
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
private func testContentDragNeverAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let drop: CGPoint = .init(x: target.midX, y: target.midY)
	let originalFrame: CGRect = window.appKitScreenFrame

	// The pointer travels; the window does not. This is a tab, text, or file drag.
	harness.press(window)
	harness.clock.advance(1)
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: drop))
	try expect(
		harness.orchestrator.dropHighlight == nil,
		"an unqualified drag must never expose a drop target"
	)
	harness.releasePointer(at: drop)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty
			&& harness.service.operations.isEmpty
			&& window.appKitScreenFrame == originalFrame,
		"a content drag must not adopt, lease, or move a window"
	)
}

@MainActor
private func testOccupiedCenterRejectsUnmanagedWindow() throws {
	let harness: Harness = try makeStartedHarness()
	let adopted: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(adopted, at: .init(x: target.midX, y: target.midY))

	let intruder: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		frame: .init(x: 100, y: 20, width: 400, height: 200)
	)
	let occupied: CGRect = try harness.panelFrame(leftPanelID)
	let center: CGPoint = .init(x: occupied.midX, y: occupied.midY)
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
		!harness.service.operations.contains(.bind(intruder.identity)),
		"a rejected drop must not leave a lease behind"
	)
}

@MainActor
private func testEdgeDropSplitsAndAdopts() throws {
	let harness: Harness = try makeStartedHarness()
	let first: FakeWindow = harness.addWindow()
	let leftFrame: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(first, at: .init(x: leftFrame.midX, y: leftFrame.midY))

	let second: FakeWindow = harness.addWindow(
		pid: secondProviderPID,
		windowID: 11,
		name: "Second",
		title: "Second Window",
		frame: .init(x: 100, y: 20, width: 400, height: 200)
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
		second.appKitScreenFrame == adoptedFrame
			&& first.appKitScreenFrame == splitFrame,
		"both windows must land in their solved Panel frames"
	)
}

@MainActor
private func testDropOutsideEveryPanelDetachesWithoutRestoring() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(window, at: .init(x: target.midX, y: target.midY))

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
		!harness.service.operations.contains(where: {
			if case .restoreOriginal = $0 { return true }
			return false
		}),
		"detaching is the user placing the window; Teaser must not move it back"
	)
}

@MainActor
private func testUndoReleasesTheAdoptedWindow() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let frameAtDrop: CGRect = harness.dropWindow(
		window,
		at: .init(x: target.midX, y: target.midY)
	)

	harness.orchestrator.undoLastLayoutChange()
	try expect(
		harness.orchestrator.panelAssignments.isEmpty && !harness.orchestrator.canUndo,
		"undo must return to the state before the adoption"
	)
	try expect(
		harness.service.operations.contains(
			.release(window.identity, restoringOriginalFrame: true)
		) && window.appKitScreenFrame == frameAtDrop,
		"undo must give the window back where the user dropped it"
	)
	try expect(
		harness.orchestrator.statusMessage == "Last layout change undone",
		"undo must report its own outcome"
	)
}

@MainActor
private func testWindowThatCannotFitRollsBackAndReports() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	window.rejectsFrames = true
	let target: CGRect = try harness.panelFrame(leftPanelID)

	let frameAtDrop: CGRect = harness.dropWindow(
		window,
		at: .init(x: target.midX, y: target.midY)
	)
	try expect(
		harness.orchestrator.panelAssignments.isEmpty,
		"a window that cannot take its Panel frame must not stay bound"
	)
	try expect(
		window.appKitScreenFrame == frameAtDrop,
		"a failed adoption must leave the window exactly where the user left it"
	)
	try expect(
		harness.orchestrator.statusMessage?.contains("cannot fit") == true,
		"the failure reason must reach the user: \(harness.orchestrator.statusMessage ?? "none")"
	)
}

@MainActor
private func testWindowLostDuringDragCancelsAndDiagnoses() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let drop: CGPoint = .init(x: target.midX, y: target.midY)
	harness.beginDrag(window, to: drop)
	try expect(
		harness.orchestrator.dropHighlight != nil,
		"the drag must be qualified before the window disappears"
	)

	window.exists = false
	harness.clock.advance(1)
	harness.pointer.send(
		.monitored(phase: .dragged, appKitScreenLocation: .init(x: drop.x + 10, y: drop.y))
	)
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
private func testTimeAdvancementGatesResampling() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	harness.press(window)
	let before: Int = harness.service.snapshotReads

	// The first sample after the press is always taken; later samples wait for
	// the clock, so a burst of pointer deliveries cannot flood window queries.
	harness.clock.advance(1)
	harness.pointer.send(.monitored(phase: .dragged, appKitScreenLocation: .init(x: 900, y: 700)))
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

@MainActor
private func testButtonStateSamplesDriveTheSameChain() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let drop: CGPoint = .init(x: target.midX, y: target.midY)
	let grab: CGPoint = .init(
		x: window.appKitScreenFrame.midX,
		y: window.appKitScreenFrame.maxY - 8
	)

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
}

@MainActor
private func testStoppingTheStageRestoresAdoptedWindows() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	let frameAtDrop: CGRect = harness.dropWindow(
		window,
		at: .init(x: target.midX, y: target.midY)
	)

	harness.orchestrator.stopStage()
	try expect(
		harness.host.willStopCount == 1,
		"Teaser chrome must close before provider leases release"
	)
	try expect(
		window.appKitScreenFrame == frameAtDrop
			&& harness.service.operations.contains(
				.release(window.identity, restoringOriginalFrame: true)
			),
		"stopping must return every adopted window to where the user dropped it"
	)
	try expect(
		harness.orchestrator.statusMessage == "Layout stopped"
			&& !harness.orchestrator.isStageActive
			&& !harness.orchestrator.hasRetainedLeases,
		"a clean stop must report a clean stop"
	)
	try expect(harness.pointer.stopCount == 1, "stopping must release the pointer source")
}

@MainActor
private func testUnrestorableWindowRetainsItsLease() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let target: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(window, at: .init(x: target.midX, y: target.midY))

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
}

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
	let target: CGRect = try harness.panelFrame(leftPanelID)
	harness.dropWindow(window, at: .init(x: target.midX, y: target.midY))

	harness.orchestrator.handInputToVirtualPanel()
	try expect(
		harness.service.operations.contains(.focusAndRaise(window.identity))
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

do {
	NSApplication.shared.setActivationPolicy(.prohibited)
	try testDefaultRunTouchesNoDesktopState()
	try testQualifiedDragAdoptsEmptyPanel()
	try testContentDragNeverAdopts()
	try testOccupiedCenterRejectsUnmanagedWindow()
	try testEdgeDropSplitsAndAdopts()
	try testDropOutsideEveryPanelDetachesWithoutRestoring()
	try testUndoReleasesTheAdoptedWindow()
	try testWindowThatCannotFitRollsBackAndReports()
	try testWindowLostDuringDragCancelsAndDiagnoses()
	try testTimeAdvancementGatesResampling()
	try testButtonStateSamplesDriveTheSameChain()
	try testStoppingTheStageRestoresAdoptedWindows()
	try testUnrestorableWindowRetainsItsLease()
	try testDeniedPermissionNeverObservesOrPrompts()
	try testInputHandoffPrefersTheAdoptedWindow()
	try testNoWindowIsEverDisplayed()
	print("Teaser window-adoption tests passed (no desktop, no monitors, no prompts)")
} catch {
	fputs("Teaser window-adoption tests failed: \(error)\n", stderr)
	exit(1)
}
