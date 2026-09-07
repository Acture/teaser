import CoreGraphics
import Foundation

// The desktop stage's adoption and layout orchestration, separated from the
// AppKit windows that present it. `DesktopStageController` supplies the real
// chrome, displays, and persistence; a test supplies deterministic pointer
// events, window snapshots, and time through `ExternalWindowService`,
// `ExternalWindowClock`, and `ExternalWindowPointerSource`. Both drive this exact
// orchestration.

enum DesktopStageOrchestratorError: Error, LocalizedError {
	case displayUnavailable
	case layoutUnavailable
	case panelUnavailable(PanelID)
	case workspaceUnavailable(WorkspaceID)
	case occupiedDropTarget
	case missingDropTarget
	case unmanagedWindowUnavailable
	case restorationFailed
	case rollbackFailed(operation: String, rollback: String)

	var errorDescription: String? {
		switch self {
		case .displayUnavailable:
			"macOS did not report a usable display."
		case .layoutUnavailable:
			"Teaser has not produced a usable desktop layout yet."
		case .panelUnavailable(let panelID):
			"Panel \(panelID.rawValue) is unavailable."
		case .workspaceUnavailable(let workspaceID):
			"Workspace \(workspaceID.rawValue) is unavailable."
		case .occupiedDropTarget:
			"That Panel is occupied. Drop on an edge to split it."
		case .missingDropTarget:
			"Drop the window inside a Teaser Panel target."
		case .unmanagedWindowUnavailable:
			"Teaser could not establish a lease for that window."
		case .restorationFailed:
			"A provider window could not be restored. Its lease is retained for retry."
		case .rollbackFailed(let operation, let rollback):
			"\(operation) Rollback also failed: \(rollback)"
		}
	}
}

/// Fresh Panel and split identity. Production draws from `UUID`; a test draws a
/// deterministic sequence so recorded bindings are assertable.
@MainActor
protocol DesktopStageIdentifierSource: AnyObject {
	func makePanelID(prefix: String) -> PanelID
	func makeSplitID(prefix: String) -> LayoutSplitID
}

@MainActor
final class UUIDDesktopStageIdentifierSource: DesktopStageIdentifierSource {
	func makePanelID(prefix: String) -> PanelID {
		.init("\(prefix)-\(UUID().uuidString.lowercased())")
	}

	func makeSplitID(prefix: String) -> LayoutSplitID {
		.init("\(prefix)-\(UUID().uuidString.lowercased())")
	}
}

/// Everything the orchestration cannot do without creating AppKit windows.
@MainActor
protocol DesktopStageOrchestratorHost: AnyObject {
	/// Chrome that reflects orchestration state: overlays, controls, status menu.
	func orchestratorDidChangeState(_ orchestrator: DesktopStageOrchestrator)
	/// Teaser-owned Panel content follows the same solved layout.
	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didSolve layout: PresentationLayout
	)
	/// Teaser-owned Panel content is raised alongside adopted windows.
	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		raiseContentIn panelID: PanelID
	)
	/// Returns true when Teaser-owned content accepted Input Focus.
	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		handInputToContentIn panelID: PanelID
	) -> Bool
	/// A newly adopted or split Panel still needs a kind.
	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didCreatePanel panelID: PanelID
	)
	/// Durable presentation or Notes state changed.
	func orchestratorDidRequestSave(_ orchestrator: DesktopStageOrchestrator)
	/// Teaser chrome and Teaser-owned Panel windows close before leases release.
	func orchestratorWillStopStage(_ orchestrator: DesktopStageOrchestrator)
}

private struct DesktopStageStateSnapshot {
	let presentation: WorkspacePresentation
	let notes: [PanelID: String]
	let panelAssignments: [PanelID: ExternalWindowIdentity]
	let detachedIdentities: Set<ExternalWindowIdentity>
}

@MainActor
final class DesktopStageOrchestrator {
	weak var host: (any DesktopStageOrchestratorHost)?

	private let service: any ExternalWindowService
	private let clock: any ExternalWindowClock
	private let pointerSource: any ExternalWindowPointerSource
	private let identifiers: any DesktopStageIdentifierSource
	private let excludedProcessIdentifiers: Set<pid_t>
	private let solver: ConstrainedLayoutSolver = .init()

	private(set) var presentation: WorkspacePresentation
	private(set) var notes: [PanelID: String]
	private(set) var displays: [DesktopStageDisplay] = []
	private(set) var layout: PresentationLayout?
	private(set) var panelAssignments: [PanelID: ExternalWindowIdentity] = [:]
	private(set) var statusMessage: String?
	private(set) var isStageActive: Bool = false
	private(set) var isArrangeModeEnabled: Bool = false
	private(set) var dropHighlight: DesktopOverlayDropHighlight?

	private var leases: [ExternalWindowIdentity: any ExternalWindowLease] = [:]
	private var detachedIdentities: Set<ExternalWindowIdentity> = []
	private var draggingIdentity: ExternalWindowIdentity?
	private var undoSnapshot: DesktopStageStateSnapshot?
	private var undoCoalescingKey: String?
	private var undoCoalescingTask: Task<Void, Never>?

	private lazy var dragObserver: WindowDragObserver = {
		let observer: WindowDragObserver = .init(
			service: service,
			clock: clock,
			pointerSource: pointerSource,
			excludedProcessIdentifiers: excludedProcessIdentifiers,
			onEvent: { [weak self] event in self?.handleDragEvent(event) }
		)
		observer.onDiagnostic = { [weak self] message in self?.setStatus(message) }
		return observer
	}()

	init(
		presentation: WorkspacePresentation,
		notes: [PanelID: String],
		statusMessage: String? = nil,
		service: any ExternalWindowService = SystemExternalWindowService.shared,
		clock: any ExternalWindowClock = SystemExternalWindowClock(),
		pointerSource: any ExternalWindowPointerSource = SystemExternalWindowPointerSource(),
		identifiers: any DesktopStageIdentifierSource = UUIDDesktopStageIdentifierSource(),
		excludedProcessIdentifiers: Set<pid_t> = [getpid()]
	) {
		self.presentation = presentation
		self.notes = notes
		self.statusMessage = statusMessage
		self.service = service
		self.clock = clock
		self.pointerSource = pointerSource
		self.identifiers = identifiers
		self.excludedProcessIdentifiers = excludedProcessIdentifiers
	}

	var canUndo: Bool { undoSnapshot != nil }

	var isDragging: Bool { draggingIdentity != nil }

	var hasRetainedLeases: Bool { !leases.isEmpty }

	var isDraggingManagedWindow: Bool {
		draggingIdentity.map(panelAssignments.values.contains) == true
	}

	func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		service.permissionStatus(prompt: prompt)
	}

	// MARK: - Lifecycle

	func setDisplays(_ displays: [DesktopStageDisplay]) {
		self.displays = displays
		adaptPresentationToDisplays()
	}

	func startStage() throws {
		guard !isStageActive else { return }
		isStageActive = true
		try solveAndApply(synchronously: true)
		try dragObserver.start()
		ExternalWindowDiagnostics.logger.notice("stage-ready panels=\(self.layout?.panelFrames.count ?? 0, privacy: .public)")
	}

	func startDragObservation(promptForAccessibility: Bool) throws {
		try dragObserver.start(promptForAccessibility: promptForAccessibility)
	}

	func stopStage() {
		isStageActive = false
		isArrangeModeEnabled = false
		dragObserver.stop()
		host?.orchestratorWillStopStage(self)
		dropHighlight = nil
		draggingIdentity = nil
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		undoCoalescingKey = nil
		undoSnapshot = nil
		var failedRestorations: Int = 0
		for (identity, lease): (ExternalWindowIdentity, any ExternalWindowLease) in leases {
			if !lease.release(restoringOriginalFrame: !detachedIdentities.contains(identity)) {
				failedRestorations += 1
			}
		}
		leases = leases.filter { $0.value.identity != nil }
		detachedIdentities.removeAll()
		panelAssignments.removeAll()
		statusMessage = failedRestorations == 0
			? "Layout stopped" : "Layout stopped; \(failedRestorations) window(s) could not be restored"
		host?.orchestratorDidChangeState(self)
	}

	/// Final teardown. Leases that still refuse restoration are dropped with the
	/// process, so this reports nothing the user could still retry.
	func shutdown() {
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		dragObserver.stop()
		for lease: any ExternalWindowLease in leases.values {
			_ = lease.release(restoringOriginalFrame: true)
		}
		leases.removeAll()
		panelAssignments.removeAll()
	}

	/// Retries restoration for leases retained after a failed release. Returns
	/// true once none remain.
	@discardableResult
	func releaseRetainedLeases() -> Bool {
		for (identity, lease): (ExternalWindowIdentity, any ExternalWindowLease) in leases {
			if lease.release(restoringOriginalFrame: true) {
				leases.removeValue(forKey: identity)
			}
		}
		return leases.isEmpty
	}

	func perform(_ command: DesktopStageCommand) {
		guard isStageActive else { return }
		switch command {
		case .stopLayout:
			stopStage()
		case .exitArrange:
			isArrangeModeEnabled = false
			setStatus("Live mode")
		case .toggleArrange:
			isArrangeModeEnabled.toggle()
			setStatus(isArrangeModeEnabled ? "Arrange mode" : "Live mode")
		case .splitPanel:
			splitVirtualPanel()
		case .toggleWorkspaceFocus:
			toggleWorkspaceFocus(workspaceID: presentation.virtualFocus.workspaceID)
		case .previousWorkspace:
			cycleWorkspace(offset: -1)
		case .nextWorkspace:
			cycleWorkspace(offset: 1)
		case .moveVirtualFocus(let direction):
			moveVirtualFocus(direction)
		case .handInputToPanel:
			handInputToVirtualPanel()
		case .undo:
			undoLastLayoutChange()
		}
	}

	func setStatus(_ message: String?) {
		statusMessage = message
		host?.orchestratorDidChangeState(self)
	}

	func setNote(_ text: String, for panelID: PanelID) {
		notes[panelID] = text
		host?.orchestratorDidRequestSave(self)
	}

	func resetShowcase(defaultNotes: String) {
		guard leases.isEmpty else {
			setStatus("Reset paused: a provider window could not be restored. Restore Accessibility and stop again to retry.")
			return
		}
		let primaryID: DisplayID = displays.first?.id ?? ShowcasePreset.mainDisplayID
		var resetPresentation: WorkspacePresentation = ShowcasePreset.presentation(
			displayID: primaryID
		)
		resetPresentation = DesktopStageDisplayTopology.adapt(
			resetPresentation,
			to: displays
		).presentation
		presentation = resetPresentation
		notes = [ShowcasePreset.notesPanelID: defaultNotes]
		panelAssignments.removeAll()
		layout = nil
		host?.orchestratorDidRequestSave(self)
		setStatus("Showcase reset. Click Start Layout when ready.")
	}

	private func adaptPresentationToDisplays() {
		let adapted = DesktopStageDisplayTopology.adapt(presentation, to: displays)
		guard adapted.changed else { return }
		presentation = adapted.presentation
		host?.orchestratorDidRequestSave(self)
	}

	// MARK: - Drag adoption

	func screenParametersDidChange(displays: [DesktopStageDisplay]) {
		self.displays = displays
		adaptPresentationToDisplays()
		if isStageActive { relayout(synchronously: true) }
	}

	private func handleDragEvent(_ event: ExternalWindowDragEvent) {
		switch event {
		case .began(let snapshot), .changed(let snapshot):
			draggingIdentity = snapshot.selection.identity
			dropHighlight = dropHighlight(
				at: snapshot.currentSample.mouseAppKitScreenLocation
			)
			if case .began = event {
				ExternalWindowDiagnostics.logger.notice("drag-target highlighted=\(self.dropHighlight != nil, privacy: .public)")
			}
			host?.orchestratorDidChangeState(self)
		case .ended(let snapshot):
			draggingIdentity = nil
			dropHighlight = nil
			acceptDrop(snapshot)
		case .cancelled:
			draggingIdentity = nil
			dropHighlight = nil
			host?.orchestratorDidChangeState(self)
		}
	}

	private func acceptDrop(_ drag: ExternalWindowDragSnapshot) {
		ExternalWindowDiagnostics.logger.notice("drop-received")
		let identity: ExternalWindowIdentity = drag.selection.identity
		let sourcePanelID: PanelID? = panelAssignments.first {
			$0.value == identity
		}?.key
		guard let target: ExternalWindowPanelDropTarget = dropTarget(
			at: drag.currentSample.mouseAppKitScreenLocation
		) else {
			guard let sourcePanelID else {
				setStatus(DesktopStageOrchestratorError.missingDropTarget.localizedDescription)
				return
			}
			detachWindow(identity: identity, from: sourcePanelID)
			return
		}
		let targetPanelID: PanelID = .init(target.panelID)
		let targetIsOccupied: Bool = isPanelOccupied(targetPanelID)

		do {
			switch target.region {
			case .empty:
				try performTransaction(label: "Window adopted") {
					try ensureLease(for: drag.selection)
					if let sourcePanelID, sourcePanelID != targetPanelID {
						panelAssignments.removeValue(forKey: sourcePanelID)
					}
					panelAssignments[targetPanelID] = identity
					try focusModel(on: targetPanelID)
				}
			case .center:
				guard let sourcePanelID else {
					throw DesktopStageOrchestratorError.occupiedDropTarget
				}
				guard sourcePanelID != targetPanelID else {
					relayout(synchronously: true)
					setStatus("Window returned to its Panel")
					return
				}
				guard targetIsOccupied,
					let targetIdentity: ExternalWindowIdentity = panelAssignments[targetPanelID]
				else {
					throw DesktopStageOrchestratorError.occupiedDropTarget
				}
				try performTransaction(label: "Panels swapped") {
					panelAssignments[sourcePanelID] = targetIdentity
					panelAssignments[targetPanelID] = identity
					try focusModel(on: targetPanelID)
				}
			case .leading, .trailing, .top, .bottom:
				guard let edge: LayoutEdge = layoutEdge(for: target.region) else {
					throw DesktopStageOrchestratorError.missingDropTarget
				}
				let newPanelID: PanelID = identifiers.makePanelID(prefix: "adopted")
				let newPanel: PanelDescriptor = descriptor(
					for: drag.selection.initialSnapshot,
					panelID: newPanelID
				)
				try performTransaction(label: "Panel split") {
					try ensureLease(for: drag.selection)
					guard let workspaceID: WorkspaceID = workspaceID(
						containing: targetPanelID
					) else {
						throw DesktopStageOrchestratorError.panelUnavailable(targetPanelID)
					}
					try presentation.insertPanel(
						newPanel,
						in: workspaceID,
						at: edge,
						of: targetPanelID,
						splitID: identifiers.makeSplitID(prefix: "drop"),
						desiredRatio: 0.5
					)
					if let sourcePanelID {
						panelAssignments.removeValue(forKey: sourcePanelID)
					}
					panelAssignments[newPanelID] = identity
					try presentation.setVirtualFocus(
						workspaceID: workspaceID,
						panelID: newPanelID
					)
				}
				host?.orchestrator(self, didCreatePanel: newPanelID)
			}
		} catch {
			setStatus(error.localizedDescription)
			relayout(synchronously: true)
		}
	}

	private func detachWindow(
		identity: ExternalWindowIdentity,
		from panelID: PanelID
	) {
		do {
			try performTransaction(label: "Window detached") {
				panelAssignments.removeValue(forKey: panelID)
				guard leases[identity] != nil else {
					throw DesktopStageOrchestratorError.unmanagedWindowUnavailable
				}
				detachedIdentities.insert(identity)
			}
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func ensureLease(for handle: any ExternalWindowHandle) throws {
		let identity: ExternalWindowIdentity = handle.identity
		detachedIdentities.remove(identity)
		if let existing: any ExternalWindowLease = leases[identity] {
			if existing.identity == nil {
				_ = try existing.bind(handle: handle)
			}
			return
		}
		let lease: any ExternalWindowLease = makeLease(identity: identity)
		_ = try lease.bind(handle: handle)
		leases[identity] = lease
	}

	private func makeLease(identity: ExternalWindowIdentity) -> any ExternalWindowLease {
		service.makeLease(
			onEvent: { [weak self] event in
				self?.handleLeaseEvent(event, identity: identity)
			},
			onApplyError: { [weak self] error in
				self?.setStatus(error.localizedDescription)
			}
		)
	}

	private func handleLeaseEvent(
		_ event: ManagedExternalWindowEvent,
		identity: ExternalWindowIdentity
	) {
		switch event {
		case .moved, .resized:
			break
		case .destroyed:
			let panelIDs: [PanelID] = panelAssignments.compactMap { panelID, value in
				value == identity ? panelID : nil
			}
			for panelID: PanelID in panelIDs {
				panelAssignments.removeValue(forKey: panelID)
			}
			leases.removeValue(forKey: identity)
			setStatus("A provider window closed; its Panel is ready for another window")
			relayout(synchronously: false)
		}
	}

	func synchronizeVirtualFocus(with identity: ExternalWindowIdentity) {
		guard let panelID: PanelID = panelAssignments.first(where: {
			$0.value == identity
		})?.key,
			let workspaceID: WorkspaceID = workspaceID(containing: panelID)
		else { return }
		do {
			try presentation.setVirtualFocus(workspaceID: workspaceID, panelID: panelID)
			statusMessage = nil
			host?.orchestratorDidRequestSave(self)
			host?.orchestratorDidChangeState(self)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	// MARK: - Virtual focus and Workspace presentation

	func setVirtualFocus(_ focus: VirtualFocusState) {
		guard let workspaceID: WorkspaceID = focus.workspaceID else { return }
		do {
			try presentation.setVirtualFocus(
				workspaceID: workspaceID,
				panelID: focus.panelID
			)
			statusMessage = nil
			host?.orchestratorDidRequestSave(self)
			host?.orchestratorDidChangeState(self)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func moveVirtualFocus(_ direction: DesktopStageFocusDirection) {
		guard let layout else {
			setStatus(DesktopStageOrchestratorError.layoutUnavailable.localizedDescription)
			return
		}
		let visiblePanels: [(PanelID, LayoutRect)] = layout.panelFrames.sorted {
			$0.key.rawValue < $1.key.rawValue
		}
		guard !visiblePanels.isEmpty else { return }
		guard let currentID: PanelID = presentation.virtualFocus.panelID,
			let currentFrame: LayoutRect = layout.panelFrames[currentID]
		else {
			setVirtualPanel(visiblePanels[0].0)
			return
		}
		let candidates: [(PanelID, Double)] = visiblePanels.compactMap { panelID, frame in
			guard panelID != currentID else { return nil }
			let dx: Double = frame.midX - currentFrame.midX
			let dy: Double = frame.midY - currentFrame.midY
			let major: Double
			let minor: Double
			switch direction {
			case .left where dx < -1:
				major = -dx
				minor = abs(dy)
			case .right where dx > 1:
				major = dx
				minor = abs(dy)
			case .up where dy > 1:
				major = dy
				minor = abs(dx)
			case .down where dy < -1:
				major = -dy
				minor = abs(dx)
			default:
				return nil
			}
			return (panelID, major + minor * 2.25)
		}
		guard let next: PanelID = candidates.min(by: { $0.1 < $1.1 })?.0 else {
			return
		}
		setVirtualPanel(next)
	}

	func setVirtualPanel(_ panelID: PanelID) {
		guard let workspaceID: WorkspaceID = workspaceID(containing: panelID) else {
			return
		}
		do {
			try presentation.setVirtualFocus(workspaceID: workspaceID, panelID: panelID)
			host?.orchestratorDidRequestSave(self)
			host?.orchestratorDidChangeState(self)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func focusModel(on panelID: PanelID) throws {
		guard let workspaceID: WorkspaceID = workspaceID(containing: panelID) else {
			throw DesktopStageOrchestratorError.panelUnavailable(panelID)
		}
		try presentation.setVirtualFocus(workspaceID: workspaceID, panelID: panelID)
	}

	private func cycleWorkspace(offset: Int) {
		let before: WorkspacePresentation = presentation
		let workspaceIDs: [WorkspaceID] = workspaceOrder()
		guard workspaceIDs.count > 1 else { return }
		let currentID: WorkspaceID? = presentation.virtualFocus.workspaceID
		let currentIndex: Int = currentID.flatMap { workspaceIDs.firstIndex(of: $0) } ?? 0
		let nextIndex: Int = (currentIndex + offset + workspaceIDs.count) % workspaceIDs.count
		let nextID: WorkspaceID = workspaceIDs[nextIndex]
		guard let workspace: WorkspaceDescriptor = presentation.workspaces[nextID] else {
			return
		}
		do {
			try presentation.setVirtualFocus(
				workspaceID: nextID,
				panelID: workspace.panelTree.leaves.first
			)
			if case .focused = presentation.mode {
				try presentation.focusWorkspace(nextID)
				try solveAndApply(synchronously: true)
			}
			host?.orchestratorDidChangeState(self)
			host?.orchestratorDidRequestSave(self)
		} catch {
			presentation = before
			setStatus(error.localizedDescription)
		}
	}

	func toggleWorkspaceFocus(workspaceID requestedID: WorkspaceID?) {
		guard let workspaceID: WorkspaceID = requestedID
			?? presentation.virtualFocus.workspaceID
		else { return }
		do {
			try performTransaction(label: "Workspace presentation changed") {
				switch presentation.mode {
				case .focused(let focusedID) where focusedID == workspaceID:
					presentation.showTiled()
				case .focused, .tiled:
					try presentation.focusWorkspace(workspaceID)
				}
			}
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func splitVirtualPanel() {
		guard let targetPanelID: PanelID = presentation.virtualFocus.panelID,
			let workspaceID: WorkspaceID = workspaceID(containing: targetPanelID),
			let targetFrame: LayoutRect = layout?.panelFrames[targetPanelID]
		else {
			setStatus(DesktopStageOrchestratorError.layoutUnavailable.localizedDescription)
			return
		}
		let panelID: PanelID = identifiers.makePanelID(prefix: "panel")
		let panel: PanelDescriptor = .init(
			id: panelID,
			title: "New Panel",
			kindID: .generic,
			providerHint: nil,
			profileOverride: nil,
			nativeContent: .none
		)
		do {
			try performTransaction(label: "Panel split") {
				try presentation.splitPanel(
					targetPanelID,
					with: panel,
					in: workspaceID,
					targetFrame: targetFrame,
					splitID: identifiers.makeSplitID(prefix: "command")
				)
				try presentation.setVirtualFocus(
					workspaceID: workspaceID,
					panelID: panelID
				)
			}
			host?.orchestrator(self, didCreatePanel: panelID)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	func handInputToVirtualPanel() {
		guard let panelID: PanelID = presentation.virtualFocus.panelID else { return }
		if let identity: ExternalWindowIdentity = panelAssignments[panelID],
			let lease: any ExternalWindowLease = leases[identity]
		{
			do {
				try lease.focusAndRaise()
				setStatus("Input handed to provider window")
			} catch {
				setStatus(error.localizedDescription)
			}
			return
		}
		if host?.orchestrator(self, handInputToContentIn: panelID) == true {
			setStatus("Input handed to Teaser Notes")
		}
	}

	func setDividerRatio(
		_ ratio: Double,
		scope: LayoutScope,
		splitID: LayoutSplitID
	) {
		let key: String = "\(scope)-\(splitID.rawValue)"
		let before: DesktopStageStateSnapshot = stateSnapshot()
		do {
			try presentation.setDesiredRatio(ratio, for: splitID, in: scope)
			try solveAndApply(synchronously: true)
			if undoCoalescingKey != key {
				prepareForNewUndo()
				undoSnapshot = before
				undoCoalescingKey = key
			}
			statusMessage = "Divider adjusted · Undo available"
			host?.orchestratorDidRequestSave(self)
			scheduleUndoCoalescingEnd()
			host?.orchestratorDidChangeState(self)
		} catch {
			let operationError: String = error.localizedDescription
			do { try restore(before); setStatus(operationError) }
			catch { setStatus("\(operationError) Rollback failed: \(error.localizedDescription)") }
		}
	}

	func setPanelKind(_ kindID: PanelKindID, panelID: PanelID) {
		do {
			try performTransaction(label: "Panel type changed") {
				guard let workspaceID: WorkspaceID = workspaceID(containing: panelID),
					var workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID],
					var panel: PanelDescriptor = workspace.panels[panelID]
				else {
					throw DesktopStageOrchestratorError.panelUnavailable(panelID)
				}
				panel.kindID = kindID
				panel.profileOverride = nil
				workspace.panels[panelID] = panel
				presentation.workspaces[workspaceID] = workspace
			}
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	func registerPanelKind(_ definition: PanelKindDefinition) {
		do {
			try performTransaction(label: "Panel type added") {
				try presentation.panelKinds.register(definition)
			}
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	// MARK: - Transactions and Undo

	private func performTransaction(
		label: String,
		change: () throws -> Void
	) throws {
		let before: DesktopStageStateSnapshot = stateSnapshot()
		do {
			try change()
			try solveAndApply(synchronously: true)
			prepareForNewUndo(preserving: before.detachedIdentities.union(before.panelAssignments.values))
			undoSnapshot = before
			statusMessage = "\(label) · Undo available"
			host?.orchestratorDidRequestSave(self)
			host?.orchestratorDidChangeState(self)
		} catch {
			let operationError: any Error = error
			do { try restore(before) }
			catch {
				throw DesktopStageOrchestratorError.rollbackFailed(
					operation: operationError.localizedDescription, rollback: error.localizedDescription
				)
			}
			throw operationError
		}
	}

	func undoLastLayoutChange() {
		guard let undoSnapshot else { return }
		undoCoalescingKey = nil
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		do {
			try restore(undoSnapshot)
			self.undoSnapshot = nil
			statusMessage = "Last layout change undone"
			host?.orchestratorDidRequestSave(self)
			host?.orchestratorDidChangeState(self)
		} catch {
			setStatus("Undo could not restore every provider: \(error.localizedDescription)")
		}
	}

	private func stateSnapshot() -> DesktopStageStateSnapshot {
		.init(
			presentation: presentation,
			notes: notes,
			panelAssignments: panelAssignments,
			detachedIdentities: detachedIdentities
		)
	}

	private func restore(_ snapshot: DesktopStageStateSnapshot) throws {
		let desiredIdentities: Set<ExternalWindowIdentity> = Set(
			snapshot.panelAssignments.values
		).union(snapshot.detachedIdentities)
		for identity: ExternalWindowIdentity in leases.keys where
			!desiredIdentities.contains(identity)
		{
			guard let lease: any ExternalWindowLease = leases[identity] else { continue }
			guard lease.release(restoringOriginalFrame: true) else {
				throw DesktopStageOrchestratorError.restorationFailed
			}
			leases.removeValue(forKey: identity)
		}
		for identity: ExternalWindowIdentity in desiredIdentities {
			let lease: any ExternalWindowLease
			if let existing: any ExternalWindowLease = leases[identity] {
				lease = existing
			} else {
				let created: any ExternalWindowLease = makeLease(identity: identity)
				leases[identity] = created
				lease = created
			}
			if lease.identity == nil {
				_ = try lease.bind(identity: identity)
			}
		}
		presentation = snapshot.presentation
		notes = snapshot.notes
		panelAssignments = snapshot.panelAssignments
		detachedIdentities = snapshot.detachedIdentities
		try solveAndApply(synchronously: true)
	}

	private func prepareForNewUndo(preserving retained: Set<ExternalWindowIdentity> = []) {
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		undoCoalescingKey = nil
		undoSnapshot = nil
		let assigned: Set<ExternalWindowIdentity> = .init(panelAssignments.values)
		for identity: ExternalWindowIdentity in detachedIdentities
			where !assigned.contains(identity) && !retained.contains(identity)
		{
			guard let lease: any ExternalWindowLease = leases.removeValue(
				forKey: identity
			) else { continue }
			_ = lease.release(restoringOriginalFrame: false)
			detachedIdentities.remove(identity)
		}
	}

	private func scheduleUndoCoalescingEnd() {
		undoCoalescingTask?.cancel()
		undoCoalescingTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(350))
			} catch {
				return
			}
			self?.undoCoalescingKey = nil
			self?.undoCoalescingTask = nil
		}
	}

	// MARK: - Layout

	func relayout(synchronously: Bool) {
		guard isStageActive else { return }
		do {
			try solveAndApply(synchronously: synchronously)
			host?.orchestratorDidChangeState(self)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func solveAndApply(synchronously: Bool) throws {
		guard !displays.isEmpty else {
			throw DesktopStageOrchestratorError.displayUnavailable
		}
		let displayFrames: [DisplayID: LayoutRect] = Dictionary(
			uniqueKeysWithValues: displays.map { ($0.id, $0.frame) }
		)
		let nextLayout: PresentationLayout = try solver.solve(
			presentation: presentation,
			displayFrames: displayFrames
		)
		if synchronously {
			try applySynchronously(nextLayout)
		} else {
			applyCoalesced(nextLayout)
		}
		presentation.applyEffectiveRatios(nextLayout.effectiveRatios)
		layout = nextLayout
		if isStageActive {
			host?.orchestrator(self, didSolve: nextLayout)
			raiseFocusedWorkspaceIfNeeded()
		}
	}

	private func applySynchronously(_ nextLayout: PresentationLayout) throws {
		var applied: [(any ExternalWindowLease, ManagedExternalWindowSnapshot)] = []
		do {
			for panelID: PanelID in panelAssignments.keys.sorted(
				by: { $0.rawValue < $1.rawValue }
			) {
				guard let frame: LayoutRect = nextLayout.panelFrames[panelID],
					let identity: ExternalWindowIdentity = panelAssignments[panelID],
					let lease: any ExternalWindowLease = leases[identity]
				else { continue }
				let previous: ManagedExternalWindowSnapshot = try lease.snapshot()
				applied.append((lease, previous))
				_ = try lease.apply(appKitScreenFrame: nsRect(frame))
			}
		} catch {
			var rollbackErrors: [String] = []
			for (lease, previous): (any ExternalWindowLease, ManagedExternalWindowSnapshot)
				in applied.reversed()
			{
				do { _ = try lease.restore(snapshot: previous) }
				catch { rollbackErrors.append(error.localizedDescription) }
			}
			if !rollbackErrors.isEmpty {
				throw DesktopStageOrchestratorError.rollbackFailed(
					operation: error.localizedDescription, rollback: rollbackErrors.joined(separator: "; ")
				)
			}
			throw error
		}
	}

	private func applyCoalesced(_ nextLayout: PresentationLayout) {
		for (panelID, identity): (PanelID, ExternalWindowIdentity) in panelAssignments {
			guard let frame: LayoutRect = nextLayout.panelFrames[panelID],
				let lease: any ExternalWindowLease = leases[identity]
			else { continue }
			lease.applyCoalesced(appKitScreenFrame: nsRect(frame))
		}
	}

	private func raiseFocusedWorkspaceIfNeeded() {
		guard case .focused(let workspaceID) = presentation.mode,
			let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
		else { return }
		for panelID: PanelID in workspace.panelTree.leaves {
			if let identity: ExternalWindowIdentity = panelAssignments[panelID],
				let lease: any ExternalWindowLease = leases[identity]
			{
				try? lease.raise()
			} else {
				host?.orchestrator(self, raiseContentIn: panelID)
			}
		}
	}

	// MARK: - Drop targets

	private func dropTarget(at point: CGPoint) -> ExternalWindowPanelDropTarget? {
		guard let layout else { return nil }
		let panels: [ExternalWindowPanelGeometry] = layout.panelFrames.map {
			panelID, frame in
			.init(
				panelID: panelID.rawValue,
				appKitScreenFrame: nsRect(frame),
				isOccupied: isPanelOccupied(panelID)
			)
		}
		return externalWindowPanelDropTarget(at: point, panels: panels)
	}

	private func dropHighlight(at point: CGPoint) -> DesktopOverlayDropHighlight? {
		guard let target: ExternalWindowPanelDropTarget = dropTarget(at: point),
			let layout
		else { return nil }
		let panelID: PanelID = .init(target.panelID)
		guard
			let panelFrame: LayoutRect = layout.panelFrames[panelID],
			let workspaceID: WorkspaceID = workspaceID(containing: panelID)
		else { return nil }
		let edge: LayoutEdge? = layoutEdge(for: target.region)
		let frame: LayoutRect = highlightedFrame(panelFrame, edge: edge)
		let label: String
		switch target.region {
		case .empty:
			label = "Adopt window"
		case .center:
			label = isDraggingManagedWindow ? "Swap Panels" : "Occupied · use an edge"
		case .leading, .trailing, .top, .bottom:
			label = "Split and adopt"
		}
		return .init(
			workspaceID: workspaceID,
			panelID: panelID,
			edge: edge,
			frame: frame,
			label: label
		)
	}

	private func highlightedFrame(
		_ frame: LayoutRect,
		edge: LayoutEdge?
	) -> LayoutRect {
		guard let edge else { return frame }
		switch edge {
		case .leading:
			return .init(
				x: frame.minX,
				y: frame.minY,
				width: frame.size.width * 0.5,
				height: frame.size.height
			)
		case .trailing:
			return .init(
				x: frame.midX,
				y: frame.minY,
				width: frame.size.width * 0.5,
				height: frame.size.height
			)
		case .top:
			return .init(
				x: frame.minX,
				y: frame.midY,
				width: frame.size.width,
				height: frame.size.height * 0.5
			)
		case .bottom:
			return .init(
				x: frame.minX,
				y: frame.minY,
				width: frame.size.width,
				height: frame.size.height * 0.5
			)
		}
	}

	// MARK: - Presentation queries

	func isPanelOccupied(_ panelID: PanelID) -> Bool {
		if panelAssignments[panelID] != nil { return true }
		guard let descriptor: PanelDescriptor = panelDescriptor(panelID) else {
			return false
		}
		return descriptor.nativeContent != .none
	}

	private func descriptor(
		for snapshot: ManagedExternalWindowSnapshot,
		panelID: PanelID
	) -> PanelDescriptor {
		let ratio: Double = Double(
			snapshot.appKitScreenFrame.width / snapshot.appKitScreenFrame.height
		)
		let lowerRatio: Double = max(0.35, ratio * 0.82)
		let upperRatio: Double = max(lowerRatio, min(4.0, ratio * 1.18))
		return .init(
			id: panelID,
			title: snapshot.title.isEmpty ? snapshot.applicationName : snapshot.title,
			kindID: .generic,
			providerHint: .init(
				displayName: snapshot.applicationName,
				bundleIdentifier: service.bundleIdentifier(
					forProcessIdentifier: snapshot.identity.processIdentifier
				),
				context: nil
			),
			profileOverride: .init(
				minimumSize: PanelKindDefinition.generic.defaultProfile.minimumSize,
				preferredAspectRatio: .init(lowerRatio, upperRatio),
				growthWeight: 1
			),
			nativeContent: .none
		)
	}

	func workspaceOrder() -> [WorkspaceID] {
		var seen: Set<WorkspaceID> = []
		var ordered: [WorkspaceID] = []
		for displayID: DisplayID in presentation.displayLayouts.keys.sorted(
			by: { $0.rawValue < $1.rawValue }
		) {
			guard let displayLayout: DisplayWorkspaceLayout =
				presentation.displayLayouts[displayID]
			else { continue }
			for workspaceID: WorkspaceID in displayLayout.workspaceTree.leaves where
				seen.insert(workspaceID).inserted
			{
				ordered.append(workspaceID)
			}
		}
		for workspaceID: WorkspaceID in presentation.workspaces.keys.sorted(
			by: { $0.rawValue < $1.rawValue }
		) where seen.insert(workspaceID).inserted {
			ordered.append(workspaceID)
		}
		return ordered
	}

	func workspaceID(containing panelID: PanelID) -> WorkspaceID? {
		presentation.workspaces.values.first { workspace in
			workspace.panels[panelID] != nil
		}?.id
	}

	private func panelDescriptor(_ panelID: PanelID) -> PanelDescriptor? {
		guard let workspaceID: WorkspaceID = workspaceID(containing: panelID) else {
			return nil
		}
		return presentation.workspaces[workspaceID]?.panels[panelID]
	}

	private func layoutEdge(
		for region: ExternalWindowPanelDropRegion
	) -> LayoutEdge? {
		switch region {
		case .leading: .leading
		case .trailing: .trailing
		case .top: .top
		case .bottom: .bottom
		case .empty, .center: nil
		}
	}
}

func nsRect(_ rect: LayoutRect) -> CGRect {
	.init(
		x: rect.origin.x,
		y: rect.origin.y,
		width: rect.size.width,
		height: rect.size.height
	)
}
