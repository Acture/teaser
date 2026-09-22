import AppKit
import CoreGraphics
import Darwin
import Foundation
@testable import TeaserKit

// The substituted external-window environment shared by every adoption
// regression: deterministic pointer events, a manual clock, a fixture window
// world, one ordered operation log, and a recording host. Only the system
// boundary is replaced. `DesktopStageOrchestrator` and `WindowDragObserver` run
// exactly as the application runs them, so nothing here installs a global event
// monitor, shows a window, requests Accessibility permission, or touches a
// window the user owns.

enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message): return message
		}
	}
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
	guard try condition() else { throw TestFailure.assertion(message) }
}

func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
	guard let value else { throw TestFailure.assertion(message) }
	return value
}

/// One regression case. The runner reports the failing name, so a case is named
/// after the behavior it defends rather than the code it touches.
struct TestCase {
	let name: String
	let run: @MainActor () throws -> Void

	init(_ name: String, _ run: @escaping @MainActor () throws -> Void) {
		self.name = name
		self.run = run
	}
}

// MARK: - Ordered operation log

/// Everything the substituted boundary was asked to do, in the order it was
/// asked. Ordering claims — chrome closes before leases release, rollback runs
/// in reverse — are assertions about this sequence, not about counters that
/// happen to agree.
enum FakeWindowOperation: Equatable {
	case pointerObservationStarted
	case pointerObservationStopped
	case bind(ExternalWindowIdentity)
	case apply(ExternalWindowIdentity, CGRect)
	case applyRejected(ExternalWindowIdentity, requested: CGRect, actual: CGRect)
	case applyCoalesced(ExternalWindowIdentity, CGRect)
	case restore(ExternalWindowIdentity, CGRect)
	case restoreRejected(ExternalWindowIdentity)
	case restoreOriginal(ExternalWindowIdentity, CGRect)
	case raise(ExternalWindowIdentity)
	case focusAndRaise(ExternalWindowIdentity)
	case release(ExternalWindowIdentity, restoringOriginalFrame: Bool)
	case releaseRefused(ExternalWindowIdentity)
	case windowDestroyed(ExternalWindowIdentity)
	case hostWillStopStage
}

@MainActor
final class FakeOperationLog {
	private(set) var operations: [FakeWindowOperation] = []

	func record(_ operation: FakeWindowOperation) {
		operations.append(operation)
	}

	func contains(_ operation: FakeWindowOperation) -> Bool {
		operations.contains(operation)
	}

	func contains(where predicate: (FakeWindowOperation) -> Bool) -> Bool {
		operations.contains(where: predicate)
	}

	func firstIndex(of operation: FakeWindowOperation) -> Int? {
		operations.firstIndex(of: operation)
	}

	func bindCount(for identity: ExternalWindowIdentity) -> Int {
		operations.filter { $0 == .bind(identity) }.count
	}

	func applies(for identity: ExternalWindowIdentity) -> [CGRect] {
		operations.compactMap { operation in
			guard case .apply(let applied, let frame) = operation, applied == identity
			else { return nil }
			return frame
		}
	}

	func lastApply(for identity: ExternalWindowIdentity) -> CGRect? {
		applies(for: identity).last
	}

	/// Frame-affecting operations recorded after `index`, in order. Rollback
	/// order is a claim about this projection.
	func frameOperations(after index: Int) -> [FakeWindowOperation] {
		operations.dropFirst(index).filter { operation in
			switch operation {
			case .apply, .applyRejected, .restore, .restoreRejected, .restoreOriginal:
				return true
			default:
				return false
			}
		}
	}
}

// MARK: - Fixture window world

@MainActor
final class FakeWindow {
	let identity: ExternalWindowIdentity
	let applicationName: String
	let title: String
	var appKitScreenFrame: CGRect
	var exists: Bool = true
	/// Whether the window is visible on the current Space right now. It gates the
	/// drag hit test only: a window hidden by Stage Manager cannot be dragged,
	/// but it remains adoptable and movable once Teaser holds its identity.
	var isVisibleOnCurrentSpace: Bool = true
	/// Whether the provider publishes an Accessibility element for this window.
	/// Stage Manager's strip thumbnails and menu-bar windows do not, and the real
	/// service omits them from the candidate list entirely.
	var hasAccessibilityElement: Bool = true
	/// The window refuses every geometry write; a read back after the write
	/// still reports the old frame.
	var rejectsFrames: Bool = false
	/// The window takes a size of its own instead of the requested one, which is
	/// the readback mismatch a real provider with a minimum size produces.
	var minimumSize: CGSize?
	var refusesRelease: Bool = false
	var refusesRestore: Bool = false
	/// Manageability, exactly as `ExternalWindowSystem.requireManageable` reads
	/// it at selection time. Each of these makes the real selection throw.
	var isStandard: Bool = true
	var isMinimized: Bool = false
	var isFullScreen: Bool = false
	var allowsMove: Bool = true
	var allowsResize: Bool = true

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
			isMinimized: isMinimized
		)
	}

	/// The reason the real selection would refuse this window, if any.
	var manageabilityFailure: ManagedExternalWindowError? {
		if !isStandard { return .windowNotStandard }
		if isMinimized { return .windowIsMinimized }
		if isFullScreen { return .windowIsFullScreen }
		if !allowsMove { return .windowCannotMove }
		if !allowsResize { return .windowCannotResize }
		return nil
	}

	func offset(dx: CGFloat, dy: CGFloat) {
		appKitScreenFrame = appKitScreenFrame.offsetBy(dx: dx, dy: dy)
	}

	/// The frame this window actually takes for a requested one. The real lease
	/// writes, reads back, and reports any difference as `windowCannotFit`.
	func accepting(_ frame: CGRect) -> CGRect {
		if rejectsFrames { return appKitScreenFrame }
		guard let minimumSize else { return frame }
		// A real provider keeps its top-left corner and grows right and down, so
		// in AppKit coordinates the top edge (`maxY`) is what stays put.
		let width: CGFloat = max(frame.size.width, minimumSize.width)
		let height: CGFloat = max(frame.size.height, minimumSize.height)
		return .init(x: frame.minX, y: frame.maxY - height, width: width, height: height)
	}
}

/// The production handle carries a live `AXUIElement`, so a window that merely
/// reuses a retired PID and `CGWindowID` is a different element and is refused.
/// Holding the fixture object is this fake's equivalent of that reference.
@MainActor
final class FakeWindowHandle: ExternalWindowHandle {
	let identity: ExternalWindowIdentity
	let initialSnapshot: ManagedExternalWindowSnapshot
	let window: FakeWindow

	init(window: FakeWindow) {
		self.identity = window.identity
		self.initialSnapshot = window.snapshot
		self.window = window
	}
}

@MainActor
final class FakeExternalWindowService: ExternalWindowService {
	/// Revoking this models Accessibility being withdrawn mid-session: every
	/// window query fails the way the real AX reads fail once access is gone.
	var permission: ExternalWindowPermissionStatus = .authorized
	/// Front-to-back, exactly as the window server orders the current Space.
	var windows: [FakeWindow] = []
	private(set) var promptCount: Int = 0
	private(set) var snapshotReads: Int = 0

	let log: FakeOperationLog
	private var leases: [FakeExternalWindowLease] = []

	init(log: FakeOperationLog) {
		self.log = log
	}

	func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		if prompt { promptCount += 1 }
		return permission
	}

	func selectWindow(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t>
	) throws -> any ExternalWindowHandle {
		try requirePermission()
		guard let window: FakeWindow = windows.first(where: {
			$0.exists && $0.isVisibleOnCurrentSpace && $0.appKitScreenFrame.contains(point)
		}), !excludingProcessIdentifiers.contains(window.identity.processIdentifier) else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		if let failure: ManagedExternalWindowError = window.manageabilityFailure {
			throw failure
		}
		return FakeWindowHandle(window: window)
	}

	func selectWindow(identity: ExternalWindowIdentity) throws -> any ExternalWindowHandle {
		try requirePermission()
		let window: FakeWindow = try require(identity)
		if let failure: ManagedExternalWindowError = window.manageabilityFailure {
			throw failure
		}
		return FakeWindowHandle(window: window)
	}

	func adoptableWindows(
		excludingProcessIdentifiers: Set<pid_t>
	) -> [ExternalWindowCandidate] {
		guard permission == .authorized else { return [] }
		return windows.filter {
			$0.exists && $0.hasAccessibilityElement
				&& !excludingProcessIdentifiers.contains($0.identity.processIdentifier)
		}.map { window in
			.init(
				identity: window.identity,
				applicationName: window.applicationName,
				bundleIdentifier: "com.example.\(window.applicationName)",
				windowTitle: window.title.isEmpty ? nil : window.title,
				appKitScreenFrame: window.appKitScreenFrame,
				isVisibleOnCurrentSpace: window.isVisibleOnCurrentSpace,
				rejectionReason: window.manageabilityFailure?.localizedDescription
			)
		}
	}

	func validateIdentity(of handle: any ExternalWindowHandle) throws {
		_ = try requireElement(handle)
	}

	func validateWindowIsLive(of handle: any ExternalWindowHandle) throws {
		// Mirrors the real check: the window server must still list the window.
		// Being hidden by Stage Manager or on another Space is not a failure.
		_ = try requireElement(handle)
	}

	func snapshot(
		of handle: any ExternalWindowHandle
	) throws -> ManagedExternalWindowSnapshot {
		let window: FakeWindow = try requireElement(handle)
		snapshotReads += 1
		return window.snapshot
	}

	func bundleIdentifier(forProcessIdentifier processIdentifier: pid_t) -> String? {
		"com.example.provider\(processIdentifier)"
	}

	func makeLease(
		onEvent: @escaping ManagedExternalWindowEventHandler,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) -> any ExternalWindowLease {
		let lease: FakeExternalWindowLease = .init(
			service: self,
			onEvent: onEvent,
			onApplyError: onApplyError
		)
		leases.append(lease)
		return lease
	}

	func window(_ identity: ExternalWindowIdentity) throws -> FakeWindow {
		try require(identity)
	}

	/// The provider closes its own window. The real lease clears its binding from
	/// the destruction observation and only then reports the event.
	func close(_ window: FakeWindow) {
		window.exists = false
		log.record(.windowDestroyed(window.identity))
		for lease: FakeExternalWindowLease in leases
			where lease.identity == window.identity
		{
			lease.notifyDestroyed()
		}
	}

	private func requirePermission() throws {
		guard permission == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
	}

	/// Production re-reads a window through the `AXUIElement` it selected. When
	/// Accessibility is revoked or the element is gone those reads fail as an
	/// unavailable window, never as a permission error, so a window that only
	/// reuses the identity does not answer for the one that was selected.
	func requireElement(
		_ handle: any ExternalWindowHandle
	) throws -> FakeWindow {
		guard permission == .authorized,
			let handle = handle as? FakeWindowHandle,
			handle.window.exists,
			windows.contains(where: { $0 === handle.window })
		else {
			throw ManagedExternalWindowError.windowUnavailable(handle.identity)
		}
		return handle.window
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
final class FakeExternalWindowLease: ExternalWindowLease {
	private(set) var identity: ExternalWindowIdentity?

	private let service: FakeExternalWindowService
	private let onEvent: ManagedExternalWindowEventHandler
	private let onApplyError: ManagedExternalWindowApplyErrorHandler
	private var originalFrame: CGRect?
	private var lastAppliedFrame: CGRect?

	init(
		service: FakeExternalWindowService,
		onEvent: @escaping ManagedExternalWindowEventHandler,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) {
		self.service = service
		self.onEvent = onEvent
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
		// The real bind re-checks permission, that the window server still lists
		// the window, and manageability before it takes the window, so a lease is
		// never established blind.
		guard service.permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		let window: FakeWindow = try service.window(identity)
		if let failure: ManagedExternalWindowError = window.manageabilityFailure {
			throw failure
		}
		self.identity = identity
		originalFrame = window.appKitScreenFrame
		lastAppliedFrame = nil
		service.log.record(.bind(identity))
		return window.snapshot
	}

	func snapshot() throws -> ManagedExternalWindowSnapshot {
		try boundWindow().snapshot
	}

	@discardableResult
	func apply(appKitScreenFrame frame: CGRect) throws -> ManagedExternalWindowSnapshot {
		let window: FakeWindow = try boundWindow()
		try requireLiveWindow(window)
		guard window.appKitScreenFrame != frame else {
			lastAppliedFrame = frame
			return window.snapshot
		}
		let previousFrame: CGRect = window.appKitScreenFrame
		let acceptedFrame: CGRect = window.accepting(frame)
		// Mirrors the real lease: a window that reached the requested top-left
		// corner is placed even when it took its own size.
		let landed: Bool = abs(acceptedFrame.minX - frame.minX) <= 2
			&& abs(acceptedFrame.maxY - frame.maxY) <= 2
		if landed, acceptedFrame != frame {
			window.appKitScreenFrame = acceptedFrame
			lastAppliedFrame = acceptedFrame
			service.log.record(.apply(window.identity, acceptedFrame))
			return window.snapshot
		}
		guard acceptedFrame == frame else {
			// The real lease writes the previous frame back before reporting a
			// readback mismatch, so a refused move leaves the window untouched.
			window.appKitScreenFrame = previousFrame
			service.log.record(
				.applyRejected(window.identity, requested: frame, actual: acceptedFrame)
			)
			throw ManagedExternalWindowError.windowCannotFit(
				requested: frame,
				actual: acceptedFrame
			)
		}
		window.appKitScreenFrame = frame
		lastAppliedFrame = frame
		service.log.record(.apply(window.identity, frame))
		return window.snapshot
	}

	func applyCoalesced(appKitScreenFrame frame: CGRect) {
		do {
			let window: FakeWindow = try boundWindow()
			try requireLiveWindow(window)
			guard window.appKitScreenFrame != frame else { return }
			guard window.accepting(frame) == frame else {
				throw ManagedExternalWindowError.windowCannotFit(
					requested: frame,
					actual: window.accepting(frame)
				)
			}
			window.appKitScreenFrame = frame
			lastAppliedFrame = frame
			service.log.record(.applyCoalesced(window.identity, frame))
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
		// The real lease restores by applying a frame, and applying the frame a
		// window already has writes nothing and cannot fail.
		if window.appKitScreenFrame != snapshot.appKitScreenFrame {
			guard !window.refusesRestore else {
				service.log.record(.restoreRejected(window.identity))
				throw ManagedExternalWindowError.windowCannotFit(
					requested: snapshot.appKitScreenFrame,
					actual: window.appKitScreenFrame
				)
			}
			window.appKitScreenFrame = snapshot.appKitScreenFrame
		}
		lastAppliedFrame = snapshot.appKitScreenFrame
		service.log.record(.restore(window.identity, snapshot.appKitScreenFrame))
		return window.snapshot
	}

	func raise() throws {
		let window: FakeWindow = try boundWindow()
		try requireLiveWindow(window)
		service.log.record(.raise(window.identity))
	}

	func focusAndRaise() throws {
		let window: FakeWindow = try boundWindow()
		try requireLiveWindow(window)
		service.log.record(.focusAndRaise(window.identity))
	}

	@discardableResult
	func release(restoringOriginalFrame: Bool) -> Bool {
		guard let identity else { return true }
		guard let window: FakeWindow = try? service.window(identity),
			service.permissionStatus(prompt: false) == .authorized
		else {
			// Production validates the window before restoring anything and
			// returns false from that failure, keeping the lease for a retry.
			guard !restoringOriginalFrame else {
				service.log.record(.releaseRefused(identity))
				return false
			}
			clearBinding()
			return true
		}
		// A release that is not restoring is unconditional in the real lease: it
		// drops the binding without touching the window.
		guard restoringOriginalFrame else {
			service.log.record(.release(identity, restoringOriginalFrame: false))
			clearBinding()
			return true
		}
		guard !window.refusesRelease else {
			service.log.record(.releaseRefused(identity))
			return false
		}
		if let originalFrame,
			let lastAppliedFrame,
			window.appKitScreenFrame == lastAppliedFrame
		{
			window.appKitScreenFrame = originalFrame
			service.log.record(.restoreOriginal(identity, originalFrame))
		}
		service.log.record(.release(identity, restoringOriginalFrame: true))
		clearBinding()
		return true
	}

	func notifyDestroyed() {
		clearBinding()
		onEvent(.destroyed)
	}

	private func clearBinding() {
		identity = nil
		originalFrame = nil
		lastAppliedFrame = nil
	}

	private func requireLiveWindow(_ window: FakeWindow) throws {
		guard window.exists else {
			throw ManagedExternalWindowError.windowUnavailable(window.identity)
		}
	}

	private func boundWindow() throws -> FakeWindow {
		guard let identity else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		guard service.permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
		}
		return try service.window(identity)
	}
}

// MARK: - Deterministic time, pointer, identity, and host

@MainActor
final class ManualClock: ExternalWindowClock {
	private(set) var now: TimeInterval = 1_000

	func advance(_ interval: TimeInterval) {
		now += interval
	}
}

@MainActor
final class RecordingPointerSource: ExternalWindowPointerSource {
	private(set) var startCount: Int = 0
	private(set) var stopCount: Int = 0
	private let log: FakeOperationLog
	private var handler: ExternalWindowPointerEventHandler?

	init(log: FakeOperationLog) {
		self.log = log
	}

	var isRunning: Bool { handler != nil }

	func start(handler: @escaping ExternalWindowPointerEventHandler) throws {
		guard self.handler == nil else { return }
		startCount += 1
		self.handler = handler
		log.record(.pointerObservationStarted)
	}

	func stop() {
		if handler != nil {
			stopCount += 1
			log.record(.pointerObservationStopped)
		}
		handler = nil
	}

	func send(_ event: ExternalWindowPointerEvent) {
		handler?(event)
	}
}

@MainActor
final class CountingIdentifierSource: DesktopStageIdentifierSource {
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
final class RecordingStageHost: DesktopStageOrchestratorHost {
	/// Panels the host claims as Teaser-owned content.
	var contentPanels: Set<PanelID> = []
	private(set) var createdPanels: [PanelID] = []
	private(set) var inputHandoffs: [PanelID] = []
	private(set) var stateChanges: Int = 0
	private(set) var saveRequests: Int = 0
	private let log: FakeOperationLog

	init(log: FakeOperationLog) {
		self.log = log
	}

	func orchestratorDidChangeState(_ orchestrator: DesktopStageOrchestrator) {
		stateChanges += 1
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didSolve layout: PresentationLayout
	) {}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		raiseContentIn panelID: PanelID
	) {}

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
		log.record(.hostWillStopStage)
	}
}

// MARK: - Fixture presentation

let testDisplayID: DisplayID = .init("test-display")
let testWorkspaceID: WorkspaceID = .init("alpha")
let leftPanelID: PanelID = .init("left")
let rightPanelID: PanelID = .init("right")
let providerPID: pid_t = 4_242
let secondProviderPID: pid_t = 4_243
let thirdProviderPID: pid_t = 4_244
let testDisplayFrame: CGRect = .init(x: 0, y: 0, width: 2_000, height: 1_000)

func fixturePanel(
	_ id: PanelID,
	_ title: String,
	_ workspaceID: WorkspaceID = testWorkspaceID
) -> PanelDescriptor {
	.init(
		id: id,
		title: title,
		workspaceID: workspaceID,
		kindID: .generic,
		providerHint: nil,
		profileOverride: nil,
		nativeContent: .none
	)
}

func testPresentation() throws -> WorkspacePresentation {
	.init(
		virtualFocus: .init(panelID: leftPanelID),
		canvases: [
			testDisplayID: .init(
				displayID: testDisplayID,
				panelTree: .split(
					id: .init("alpha-root"),
					axis: .horizontal,
					preference: .user(0.5),
					first: .leaf(leftPanelID),
					second: .leaf(rightPanelID)
				)
			),
		],
		workspaces: [
			testWorkspaceID: .init(
				id: testWorkspaceID,
				title: "Alpha",
				detail: "Deterministic adoption fixture"
			),
		],
		panels: [
			leftPanelID: fixturePanel(leftPanelID, "Left"),
			rightPanelID: fixturePanel(rightPanelID, "Right"),
		],
		panelKinds: try .init()
	)
}

// MARK: - Harness

let notesPanelID: PanelID = .init("notes")
let betaWorkspaceID: WorkspaceID = .init("beta")
let betaPanelID: PanelID = .init("beta-panel")

/// The fixture with `rightPanelID` holding Teaser-owned content rather than an
/// adoptable slot, which is how the shipped showcase pairs Notes with providers.
func testPresentationWithContentPanel() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = try testPresentation()
	var panel: PanelDescriptor = try unwrap(
		presentation.panels[rightPanelID],
		"fixture Panel is missing"
	)
	panel.nativeContent = .notes
	presentation.panels[rightPanelID] = panel
	return presentation
}

/// Two groups interleaved in one canvas tree, so a drop can cross a group
/// border without either group owning a rectangle.
func testPresentationWithTwoWorkspaces() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = try testPresentation()
	presentation.workspaces[betaWorkspaceID] = .init(
		id: betaWorkspaceID,
		title: "Beta",
		detail: "Second Workspace"
	)
	presentation.panels[betaPanelID] = fixturePanel(
		betaPanelID,
		"Beta Panel",
		betaWorkspaceID
	)
	presentation.canvases[testDisplayID] = .init(
		displayID: testDisplayID,
		panelTree: .split(
			id: .init("display-root"),
			axis: .horizontal,
			preference: .user(0.5),
			first: .split(
				id: .init("alpha-root"),
				axis: .horizontal,
				preference: .user(0.5),
				first: .leaf(leftPanelID),
				second: .leaf(rightPanelID)
			),
			second: .leaf(betaPanelID)
		)
	)
	return presentation
}

/// The substituted pointer world: a fixture window set, a manual clock, and the
/// gestures that drive them. Both harnesses compose one of these, so "what a
/// window drag is" is defined once.
@MainActor
final class PointerDriver {
	let log: FakeOperationLog = .init()
	let service: FakeExternalWindowService
	let clock: ManualClock = .init()
	let pointer: RecordingPointerSource
	private(set) var pointerLocation: CGPoint = .zero

	init() {
		service = .init(log: log)
		pointer = .init(log: log)
	}

	@discardableResult
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

	/// The second and third providers appear in most multi-window cases, and
	/// their frames must start outside the layout so a drop is a real move.
	@discardableResult
	func addSecondWindow() -> FakeWindow {
		addWindow(
			pid: secondProviderPID,
			windowID: 11,
			name: "Second",
			title: "Second Window",
			frame: .init(x: 1_100, y: 20, width: 400, height: 200)
		)
	}

	@discardableResult
	func addThirdWindow() -> FakeWindow {
		addWindow(
			pid: thirdProviderPID,
			windowID: 12,
			name: "Third",
			title: "Third Window",
			frame: .init(x: 1_100, y: 20, width: 400, height: 200)
		)
	}

	/// Where a user grabs a window to move it.
	func grabPoint(_ window: FakeWindow) -> CGPoint {
		.init(
			x: window.appKitScreenFrame.midX,
			y: window.appKitScreenFrame.maxY - 8
		)
	}

	func press(_ window: FakeWindow) {
		press(at: grabPoint(window))
	}

	func press(at point: CGPoint) {
		pointerLocation = point
		pointer.send(.monitored(phase: .down, appKitScreenLocation: point))
	}

	/// Moves the pointer and the window together, which is what makes a drag a
	/// window drag rather than a content drag.
	func dragWindow(_ window: FakeWindow, to point: CGPoint) {
		moveWithoutDelivery(window, to: point)
		clock.advance(1)
		pointer.send(.monitored(phase: .dragged, appKitScreenLocation: point))
	}

	/// Moves the pointer while the window stays put: a tab, text, or file drag.
	func dragPointerOnly(to point: CGPoint) {
		pointerLocation = point
		clock.advance(1)
		pointer.send(.monitored(phase: .dragged, appKitScreenLocation: point))
	}

	/// Moves pointer and window together with no delivery at all, which is what
	/// native title-bar tracking that withholds events looks like.
	func moveWithoutDelivery(_ window: FakeWindow, to point: CGPoint) {
		window.offset(dx: point.x - pointerLocation.x, dy: point.y - pointerLocation.y)
		pointerLocation = point
	}

	/// One periodic button-state reading, the delivery that keeps a drag alive
	/// when the global monitor stays silent.
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

	func beginDrag(_ window: FakeWindow, to point: CGPoint) {
		press(window)
		dragWindow(window, to: point)
	}
}

@MainActor
final class Harness {
	let driver: PointerDriver = .init()
	let host: RecordingStageHost
	let orchestrator: DesktopStageOrchestrator

	var log: FakeOperationLog { driver.log }
	var service: FakeExternalWindowService { driver.service }
	var clock: ManualClock { driver.clock }
	var pointer: RecordingPointerSource { driver.pointer }
	var pointerLocation: CGPoint { driver.pointerLocation }

	init(presentation: WorkspacePresentation) {
		host = .init(log: driver.log)
		orchestrator = .init(
			presentation: presentation,
			notes: [:],
			service: driver.service,
			clock: driver.clock,
			pointerSource: driver.pointer,
			identifiers: CountingIdentifierSource()
		)
		orchestrator.host = host
		orchestrator.setDisplays([.init(id: testDisplayID, frame: layoutRect(testDisplayFrame))])
	}

	@discardableResult
	func addWindow(
		pid: pid_t = providerPID,
		windowID: CGWindowID = 10,
		name: String = "Provider",
		title: String = "Provider Window",
		frame: CGRect = .init(x: 1_200, y: 600, width: 600, height: 300)
	) -> FakeWindow {
		driver.addWindow(
			pid: pid,
			windowID: windowID,
			name: name,
			title: title,
			frame: frame
		)
	}

	@discardableResult
	func addSecondWindow() -> FakeWindow { driver.addSecondWindow() }

	@discardableResult
	func addThirdWindow() -> FakeWindow { driver.addThirdWindow() }

	func grabPoint(_ window: FakeWindow) -> CGPoint { driver.grabPoint(window) }

	func press(_ window: FakeWindow) { driver.press(window) }

	func press(at point: CGPoint) { driver.press(at: point) }

	func dragWindow(_ window: FakeWindow, to point: CGPoint) {
		driver.dragWindow(window, to: point)
	}

	func dragPointerOnly(to point: CGPoint) { driver.dragPointerOnly(to: point) }

	func moveWithoutDelivery(_ window: FakeWindow, to point: CGPoint) {
		driver.moveWithoutDelivery(window, to: point)
	}

	func sample(isButtonDown: Bool, at point: CGPoint? = nil) {
		driver.sample(isButtonDown: isButtonDown, at: point)
	}

	func releasePointer(at point: CGPoint? = nil) { driver.releasePointer(at: point) }

	func beginDrag(_ window: FakeWindow, to point: CGPoint) {
		driver.beginDrag(window, to: point)
	}

	func panelFrame(_ panelID: PanelID) throws -> CGRect {
		nsRect(
			try unwrap(
				orchestrator.layout?.panelFrames[panelID],
				"missing solved Panel \(panelID.rawValue)"
			)
		)
	}

	func center(of panelID: PanelID) throws -> CGPoint {
		let frame: CGRect = try panelFrame(panelID)
		return .init(x: frame.midX, y: frame.midY)
	}

	/// The frame the window world reports for an identity, which is what a read
	/// back through the boundary sees rather than what Teaser believes.
	func readBackFrame(_ identity: ExternalWindowIdentity) throws -> CGRect {
		try service.window(identity).appKitScreenFrame
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

	@discardableResult
	func adopt(_ window: FakeWindow, into panelID: PanelID) throws -> CGRect {
		dropWindow(window, at: try center(of: panelID))
	}

	func setDisplayFrame(_ frame: CGRect) {
		orchestrator.screenParametersDidChange(displays: [
			.init(id: testDisplayID, frame: layoutRect(frame)),
		])
	}
}

@MainActor
func makeStartedHarness() throws -> Harness {
	let harness: Harness = .init(presentation: try testPresentation())
	try harness.orchestrator.startStage()
	return harness
}

func layoutRect(_ rect: CGRect) -> LayoutRect {
	.init(
		x: rect.origin.x,
		y: rect.origin.y,
		width: rect.size.width,
		height: rect.size.height
	)
}
