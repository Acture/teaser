import AppKit
import CoreGraphics
import Foundation

private struct DesktopStageStateSnapshot {
	let presentation: WorkspacePresentation
	let notes: [PanelID: String]
	let panelAssignments: [PanelID: ExternalWindowIdentity]
	let detachedIdentities: Set<ExternalWindowIdentity>
}

private enum DesktopStageControllerError: Error, LocalizedError {
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

@MainActor
final class DesktopStageController: NSObject {
	private struct InitialState {
		let presentation: WorkspacePresentation
		let notes: [PanelID: String]
		let store: PresentationStore?
		let statusMessage: String?
	}

	private static let defaultNotes: String = """
		Teaser — interaction notes

		Keep project context visible while agents work in parallel.

		Open questions
		• How narrow can a task panel be before the board becomes unreadable?
		• Keep the editor beside its CLI; give the active project more room.
		• A stopped layout must leave the desktop usable immediately.
		"""

	private let solver: ConstrainedLayoutSolver = .init()
	private let store: PresentationStore?
	private let panelTypeChooser: PanelTypeChooserController = .init()
	private let panelDefinitionEditor: PanelDefinitionEditorController = .init()

	private var presentation: WorkspacePresentation
	private var notes: [PanelID: String]
	private var displays: [DesktopStageDisplay] = []
	private var layout: PresentationLayout?
	private var leases: [ExternalWindowIdentity: ManagedExternalWindow] = [:]
	private var panelAssignments: [PanelID: ExternalWindowIdentity] = [:]
	private var detachedIdentities: Set<ExternalWindowIdentity> = []
	private var notesWindows: [PanelID: NotesWindowController] = [:]
	private var arrangeModeEnabled: Bool = false
	private var dropHighlight: DesktopOverlayDropHighlight?
	private var draggingIdentity: ExternalWindowIdentity?
	private var statusMessage: String?
	private var undoSnapshot: DesktopStageStateSnapshot?
	private var undoCoalescingKey: String?
	private var undoCoalescingTask: Task<Void, Never>?
	private var saveTask: Task<Void, Never>?
	private var isRunning: Bool = false
	private var isStageActive: Bool = false
	private var permissionTask: Task<Void, Never>?
	private var lastPermissionStatus: ExternalWindowPermissionStatus?

	private lazy var controlWindow: DesktopStageControlWindow = .init(
		onToggleStage: { [weak self] in self?.toggleStage() },
		onArrange: { [weak self] in self?.perform(.toggleArrange) },
		onRequestPermission: { [weak self] in self?.requestAccessibility() }
	)

	private lazy var overlayController: DesktopOverlayController = .init(
		callbacks: .init(
			onVirtualFocusChange: { [weak self] focus in
				self?.setVirtualFocus(focus)
			},
			onWorkspaceFocusRequest: { [weak self] workspaceID in
				self?.toggleWorkspaceFocus(workspaceID: workspaceID)
			},
			onPanelInputFocusRequest: { [weak self] panelID in
				self?.setVirtualPanel(panelID)
				self?.handInputToVirtualPanel()
			},
			onUndoRequest: { [weak self] in
				self?.undoLastLayoutChange()
			},
			onDividerRatioChange: { [weak self] scope, splitID, ratio in
				self?.setDividerRatio(ratio, scope: scope, splitID: splitID)
			}
		)
	)

	private lazy var dragObserver: WindowDragObserver = .init(
		excludedProcessIdentifiers: [getpid()],
		onEvent: { [weak self] event in
			self?.handleDragEvent(event)
		}
	)

	private lazy var managedWindowFocusObserver: ManagedWindowFocusObserver = .init {
		[weak self] identity in
		self?.synchronizeVirtualFocus(with: identity)
	}

	private lazy var shortcutMonitor: DesktopStageShortcutMonitor = .init {
		[weak self] command in
		self?.perform(command)
	}

	private lazy var statusController: DesktopStageStatusController = .init(
		callbacks: .init(
			onCommand: { [weak self] command in
				self?.perform(command)
			},
			onAddPanelKind: { [weak self] in
				self?.presentPanelDefinitionEditor()
			},
			onResetShowcase: { [weak self] in
				self?.confirmResetShowcase()
			},
			onRequestAccessibility: { [weak self] in
				self?.requestAccessibility()
			},
			onQuit: {
				NSApplication.shared.terminate(nil)
			},
			onShowControls: { [weak self] in self?.showControls() },
			onToggleStage: { [weak self] in self?.toggleStage() }
		)
	)

	override init() {
		let initialState: InitialState = Self.loadInitialState()
		self.presentation = initialState.presentation
		self.notes = initialState.notes
		self.store = initialState.store
		self.statusMessage = initialState.statusMessage
		super.init()
		dragObserver.onDiagnostic = { [weak self] message in self?.setStatus(message) }
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		installSystemObservers()
		displays = connectedDisplaysWithFallback()
		adaptPresentationToDisplays()
		controlWindow.show()
		do {
			try shortcutMonitor.start()
		} catch {
			setStatus(error.localizedDescription)
		}
		refreshPermission()
		permissionTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				do { try await Task.sleep(for: .seconds(1)) }
				catch { return }
				guard let self else { return }
				self.refreshPermission()
			}
		}
		updateChrome()
	}

	func showControls() { controlWindow.show() }

	private func toggleStage() {
		if isStageActive { stopStage(); return }
		guard ManagedExternalWindow.permissionStatus(prompt: false) == .authorized else {
			requestAccessibility()
			return
		}
		isStageActive = true
		displays = connectedDisplaysWithFallback()
		adaptPresentationToDisplays()
		do {
			try solveAndApply(synchronously: true)
			try dragObserver.start()
			try managedWindowFocusObserver.start()
			ExternalWindowDiagnostics.logger.notice("stage-ready panels=\(self.layout?.panelFrames.count ?? 0, privacy: .public)")
			controlWindow.close()
			setStatus("Drag a window by its title bar into a Panel")
		} catch {
			stopStage()
			setStatus(error.localizedDescription)
		}
	}

	private func stopStage() {
		isStageActive = false
		arrangeModeEnabled = false
		shortcutMonitor.setArrangeModeEnabled(false)
		dragObserver.stop()
		managedWindowFocusObserver.stop()
		panelTypeChooser.close()
		overlayController.close()
		closeNotesWindows()
		dropHighlight = nil
		draggingIdentity = nil
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		undoCoalescingKey = nil
		undoSnapshot = nil
		var failedRestorations: Int = 0
		for (identity, lease): (ExternalWindowIdentity, ManagedExternalWindow) in leases {
			if !lease.release(restoringOriginalFrame: !detachedIdentities.contains(identity)) {
				failedRestorations += 1
			}
		}
		leases = leases.filter { $0.value.identity != nil }
		detachedIdentities.removeAll()
		panelAssignments.removeAll()
		statusMessage = failedRestorations == 0
			? "Layout stopped" : "Layout stopped; \(failedRestorations) window(s) could not be restored"
		updateChrome()
	}

	private func refreshPermission() {
		let permission: ExternalWindowPermissionStatus = ManagedExternalWindow.permissionStatus(prompt: false)
		guard permission != lastPermissionStatus else { return }
		lastPermissionStatus = permission
		NSLog("Teaser: accessibility %@", permission == .authorized ? "authorized" : "not authorized")
		if permission == .notAuthorized {
			if isStageActive { stopStage() }
			statusMessage = "Allow Accessibility, then click Start Layout"
		} else {
			statusMessage = "Accessibility allowed. Ready to start."
			if !isStageActive {
				for (identity, lease): (ExternalWindowIdentity, ManagedExternalWindow) in leases {
					if lease.release(restoringOriginalFrame: true) { leases.removeValue(forKey: identity) }
				}
				if !leases.isEmpty { statusMessage = "Accessibility allowed; some window restorations still need retry." }
			}
			if isStageActive { startExternalObservation(promptForAccessibility: false) }
		}
		updateChrome()
	}

	func applicationDidBecomeActive() {
		guard isRunning else { return }
		refreshPermission()
		if isStageActive, ManagedExternalWindow.permissionStatus(prompt: false) == .authorized {
			startExternalObservation(promptForAccessibility: false)
		}
		updateChrome()
	}

	func stop() {
		guard isRunning else { return }
		stopStage()
		isRunning = false
		permissionTask?.cancel()
		permissionTask = nil
		saveTask?.cancel()
		saveTask = nil
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		saveNow()
		removeSystemObservers()
		dragObserver.stop()
		managedWindowFocusObserver.stop()
		shortcutMonitor.stop()
		panelTypeChooser.close()
		overlayController.close()
		statusController.close()
		controlWindow.close()
		closeNotesWindows()
		for lease: ManagedExternalWindow in leases.values {
			_ = lease.release(restoringOriginalFrame: true)
		}
		leases.removeAll()
		panelAssignments.removeAll()
	}

	func perform(_ command: DesktopStageCommand) {
		guard isStageActive else { return }
		switch command {
		case .stopLayout:
			stopStage()
		case .exitArrange:
			arrangeModeEnabled = false
			shortcutMonitor.setArrangeModeEnabled(false)
			setStatus("Live mode")
		case .toggleArrange:
			arrangeModeEnabled.toggle()
			shortcutMonitor.setArrangeModeEnabled(arrangeModeEnabled)
			setStatus(arrangeModeEnabled ? "Arrange mode" : "Live mode")
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

	func requestAccessibility() {
		_ = ManagedExternalWindow.permissionStatus(prompt: true)
		refreshPermission()
		if ManagedExternalWindow.permissionStatus(prompt: false) != .authorized {
			setStatus("Allow Teaser in System Settings, then drag the window again")
		}
	}

	private static func loadInitialState() -> InitialState {
		let displays: [DesktopStageDisplay] = connectedDisplaysWithFallback()
		let primaryDisplayID: DisplayID = displays.first?.id ?? ShowcasePreset.mainDisplayID
		let liveStore: PresentationStore?
		do {
			liveStore = try PresentationStore.live()
		} catch {
			var presentation: WorkspacePresentation = ShowcasePreset.presentation(
				displayID: primaryDisplayID
			)
			presentation = DesktopStageDisplayTopology.adapt(
				presentation,
				to: displays
			).presentation
			return .init(
				presentation: presentation,
				notes: [ShowcasePreset.notesPanelID: defaultNotes],
				store: nil,
				statusMessage: "Local layout persistence is unavailable: \(error.localizedDescription)"
			)
		}

		do {
			if let document: PresentationDocument = try liveStore?.load() {
				var loadedNotes: [PanelID: String] = [:]
				for note: PersistedNote in document.notes {
					loadedNotes[note.panelID] = note.text
				}
				let adapted = DesktopStageDisplayTopology.adapt(
					document.presentation,
					to: displays
				)
				return .init(
					presentation: adapted.presentation,
					notes: loadedNotes,
					store: liveStore,
					statusMessage: adapted.changed
						? "Display topology changed; Workspaces were fitted to connected monitors"
						: nil
				)
			}
		} catch {
			var presentation: WorkspacePresentation = ShowcasePreset.presentation(
				displayID: primaryDisplayID
			)
			presentation = DesktopStageDisplayTopology.adapt(
				presentation,
				to: displays
			).presentation
			return .init(
				presentation: presentation,
				notes: [ShowcasePreset.notesPanelID: defaultNotes],
				store: nil,
				statusMessage: "Saved layout could not be loaded: \(error.localizedDescription)"
			)
		}

		var presentation: WorkspacePresentation = ShowcasePreset.presentation(
			displayID: primaryDisplayID
		)
		presentation = DesktopStageDisplayTopology.adapt(
			presentation,
			to: displays
		).presentation
		return .init(
			presentation: presentation,
			notes: [ShowcasePreset.notesPanelID: defaultNotes],
			store: liveStore,
			statusMessage: "Drag any app window into a labeled Panel"
		)
	}

	private static func connectedDisplaysWithFallback() -> [DesktopStageDisplay] {
		let connected: [DesktopStageDisplay] = DesktopStageDisplayTopology.connectedDisplays()
		guard connected.isEmpty else { return connected }
		return [
			.init(
				id: ShowcasePreset.mainDisplayID,
				frame: .init(x: 0, y: 0, width: 1_600, height: 900)
			),
		]
	}

	private func connectedDisplaysWithFallback() -> [DesktopStageDisplay] {
		Self.connectedDisplaysWithFallback()
	}

	private func installSystemObservers() {
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(screenParametersDidChange(_:)),
			name: NSApplication.didChangeScreenParametersNotification,
			object: nil
		)
		NSWorkspace.shared.notificationCenter.addObserver(
			self,
			selector: #selector(activeSpaceDidChange(_:)),
			name: NSWorkspace.activeSpaceDidChangeNotification,
			object: nil
		)
	}

	private func removeSystemObservers() {
		NotificationCenter.default.removeObserver(self)
		NSWorkspace.shared.notificationCenter.removeObserver(self)
	}

	@objc
	private func screenParametersDidChange(_ notification: Notification) {
		displays = connectedDisplaysWithFallback()
		adaptPresentationToDisplays()
		if isStageActive { relayout(synchronously: true) }
	}

	@objc
	private func activeSpaceDidChange(_ notification: Notification) {
		guard isStageActive else { return }
		stopStage()
		setStatus("Layout stopped after switching Space. Open Teaser to start here.")
	}

	private func adaptPresentationToDisplays() {
		let adapted = DesktopStageDisplayTopology.adapt(presentation, to: displays)
		guard adapted.changed else { return }
		presentation = adapted.presentation
		scheduleSave()
	}

	private func startExternalObservation(promptForAccessibility: Bool) {
		guard ManagedExternalWindow.permissionStatus(prompt: promptForAccessibility)
			== .authorized
		else {
			statusMessage = "Grant Accessibility from the Teaser menu, then drag the window again"
			updateChrome()
			return
		}
		do {
			try dragObserver.start()
			try managedWindowFocusObserver.start()
			if statusMessage?.contains("Accessibility") == true {
				statusMessage = nil
			}
		} catch {
			setStatus(error.localizedDescription)
		}
		updateChrome()
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
			updateChrome()
		case .ended(let snapshot):
			draggingIdentity = nil
			dropHighlight = nil
			acceptDrop(snapshot)
		case .cancelled:
			draggingIdentity = nil
			dropHighlight = nil
			updateChrome()
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
				setStatus(DesktopStageControllerError.missingDropTarget.localizedDescription)
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
					throw DesktopStageControllerError.occupiedDropTarget
				}
				guard sourcePanelID != targetPanelID else {
					relayout(synchronously: true)
					setStatus("Window returned to its Panel")
					return
				}
				guard targetIsOccupied,
					let targetIdentity: ExternalWindowIdentity = panelAssignments[targetPanelID]
				else {
					throw DesktopStageControllerError.occupiedDropTarget
				}
				try performTransaction(label: "Panels swapped") {
					panelAssignments[sourcePanelID] = targetIdentity
					panelAssignments[targetPanelID] = identity
					try focusModel(on: targetPanelID)
				}
			case .leading, .trailing, .top, .bottom:
				guard let edge: LayoutEdge = layoutEdge(for: target.region) else {
					throw DesktopStageControllerError.missingDropTarget
				}
				let newPanelID: PanelID = makePanelID(prefix: "adopted")
				let newPanel: PanelDescriptor = descriptor(
					for: drag.selection.initialSnapshot,
					panelID: newPanelID
				)
				try performTransaction(label: "Panel split") {
					try ensureLease(for: drag.selection)
					guard let workspaceID: WorkspaceID = workspaceID(
						containing: targetPanelID
					) else {
						throw DesktopStageControllerError.panelUnavailable(targetPanelID)
					}
					try presentation.insertPanel(
						newPanel,
						in: workspaceID,
						at: edge,
						of: targetPanelID,
						splitID: makeSplitID(prefix: "drop"),
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
				showPanelTypeChooser(for: newPanelID)
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
					throw DesktopStageControllerError.unmanagedWindowUnavailable
				}
				detachedIdentities.insert(identity)
			}
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func ensureLease(for selection: ExternalWindowSelection) throws {
		let identity: ExternalWindowIdentity = selection.identity
		detachedIdentities.remove(identity)
		if let existing: ManagedExternalWindow = leases[identity] {
			if existing.identity == nil {
				_ = try existing.bind(selection: selection)
			}
			return
		}
		let lease: ManagedExternalWindow = makeLease(identity: identity)
		_ = try lease.bind(selection: selection)
		leases[identity] = lease
	}

	private func makeLease(identity: ExternalWindowIdentity) -> ManagedExternalWindow {
		.init(
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

	private func synchronizeVirtualFocus(with identity: ExternalWindowIdentity) {
		guard let panelID: PanelID = panelAssignments.first(where: {
			$0.value == identity
		})?.key,
			let workspaceID: WorkspaceID = workspaceID(containing: panelID)
		else { return }
		do {
			try presentation.setVirtualFocus(workspaceID: workspaceID, panelID: panelID)
			statusMessage = nil
			scheduleSave()
			updateChrome()
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func setVirtualFocus(_ focus: VirtualFocusState) {
		guard let workspaceID: WorkspaceID = focus.workspaceID else { return }
		do {
			try presentation.setVirtualFocus(
				workspaceID: workspaceID,
				panelID: focus.panelID
			)
			statusMessage = nil
			scheduleSave()
			updateChrome()
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func moveVirtualFocus(_ direction: DesktopStageFocusDirection) {
		guard let layout else {
			setStatus(DesktopStageControllerError.layoutUnavailable.localizedDescription)
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

	private func setVirtualPanel(_ panelID: PanelID) {
		guard let workspaceID: WorkspaceID = workspaceID(containing: panelID) else {
			return
		}
		do {
			try presentation.setVirtualFocus(workspaceID: workspaceID, panelID: panelID)
			scheduleSave()
			updateChrome()
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func focusModel(on panelID: PanelID) throws {
		guard let workspaceID: WorkspaceID = workspaceID(containing: panelID) else {
			throw DesktopStageControllerError.panelUnavailable(panelID)
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
			} else {
				updateChrome()
			}
			updateChrome()
			scheduleSave()
		} catch {
			presentation = before
			setStatus(error.localizedDescription)
		}
	}

	private func toggleWorkspaceFocus(workspaceID requestedID: WorkspaceID?) {
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
			setStatus(DesktopStageControllerError.layoutUnavailable.localizedDescription)
			return
		}
		let panelID: PanelID = makePanelID(prefix: "panel")
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
					splitID: makeSplitID(prefix: "command")
				)
				try presentation.setVirtualFocus(
					workspaceID: workspaceID,
					panelID: panelID
				)
			}
			showPanelTypeChooser(for: panelID)
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func handInputToVirtualPanel() {
		guard let panelID: PanelID = presentation.virtualFocus.panelID else { return }
		if let identity: ExternalWindowIdentity = panelAssignments[panelID],
			let lease: ManagedExternalWindow = leases[identity]
		{
			do {
				try lease.focusAndRaise()
				setStatus("Input handed to provider window")
			} catch {
				setStatus(error.localizedDescription)
			}
			return
		}
		if let notesWindow: NotesWindowController = notesWindows[panelID] {
			notesWindow.focus()
			setStatus("Input handed to Teaser Notes")
		}
	}

	private func setDividerRatio(
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
			scheduleSave()
			scheduleUndoCoalescingEnd()
			updateChrome()
		} catch {
			let operationError: String = error.localizedDescription
			do { try restore(before); setStatus(operationError) }
			catch { setStatus("\(operationError) Rollback failed: \(error.localizedDescription)") }
		}
	}

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
			scheduleSave()
			updateChrome()
		} catch {
			let operationError: any Error = error
			do { try restore(before) }
			catch {
				throw DesktopStageControllerError.rollbackFailed(
					operation: operationError.localizedDescription, rollback: error.localizedDescription
				)
			}
			throw operationError
		}
	}

	private func undoLastLayoutChange() {
		guard let undoSnapshot else { return }
		undoCoalescingKey = nil
		undoCoalescingTask?.cancel()
		undoCoalescingTask = nil
		do {
			try restore(undoSnapshot)
			self.undoSnapshot = nil
			statusMessage = "Last layout change undone"
			scheduleSave()
			updateChrome()
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
			guard let lease: ManagedExternalWindow = leases[identity] else { continue }
			guard lease.release(restoringOriginalFrame: true) else {
				throw DesktopStageControllerError.restorationFailed
			}
			leases.removeValue(forKey: identity)
		}
		for identity: ExternalWindowIdentity in desiredIdentities {
			let lease: ManagedExternalWindow
			if let existing: ManagedExternalWindow = leases[identity] {
				lease = existing
			} else {
				let created: ManagedExternalWindow = makeLease(identity: identity)
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
			guard let lease: ManagedExternalWindow = leases.removeValue(
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

	private func relayout(synchronously: Bool) {
		guard isStageActive else { return }
		do {
			try solveAndApply(synchronously: synchronously)
			updateChrome()
		} catch {
			setStatus(error.localizedDescription)
		}
	}

	private func solveAndApply(synchronously: Bool) throws {
		guard !displays.isEmpty else {
			throw DesktopStageControllerError.displayUnavailable
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
			updateNotesWindows(using: nextLayout)
			raiseFocusedWorkspaceIfNeeded()
		}
	}

	private func applySynchronously(_ nextLayout: PresentationLayout) throws {
		var applied: [(ManagedExternalWindow, ManagedExternalWindowSnapshot)] = []
		do {
			for panelID: PanelID in panelAssignments.keys.sorted(
				by: { $0.rawValue < $1.rawValue }
			) {
				guard let frame: LayoutRect = nextLayout.panelFrames[panelID],
					let identity: ExternalWindowIdentity = panelAssignments[panelID],
					let lease: ManagedExternalWindow = leases[identity]
				else { continue }
				let previous: ManagedExternalWindowSnapshot = try lease.snapshot()
				applied.append((lease, previous))
				_ = try lease.apply(appKitScreenFrame: nsRect(frame))
			}
		} catch {
			var rollbackErrors: [String] = []
			for (lease, previous): (ManagedExternalWindow, ManagedExternalWindowSnapshot)
				in applied.reversed()
			{
				do { _ = try lease.restore(snapshot: previous) }
				catch { rollbackErrors.append(error.localizedDescription) }
			}
			if !rollbackErrors.isEmpty {
				throw DesktopStageControllerError.rollbackFailed(
					operation: error.localizedDescription, rollback: rollbackErrors.joined(separator: "; ")
				)
			}
			throw error
		}
	}

	private func applyCoalesced(_ nextLayout: PresentationLayout) {
		for (panelID, identity): (PanelID, ExternalWindowIdentity) in panelAssignments {
			guard let frame: LayoutRect = nextLayout.panelFrames[panelID],
				let lease: ManagedExternalWindow = leases[identity]
			else { continue }
			lease.applyCoalesced(appKitScreenFrame: nsRect(frame))
		}
	}

	private func updateNotesWindows(using nextLayout: PresentationLayout) {
		let notePanels: [(WorkspaceID, PanelDescriptor)] = presentation.workspaces.values
			.flatMap { workspace in
				workspace.panels.values.compactMap { panel in
					panel.nativeContent == .notes ? (workspace.id, panel) : nil
				}
			}
		let validPanelIDs: Set<PanelID> = .init(notePanels.map { $0.1.id })
		for panelID: PanelID in notesWindows.keys where !validPanelIDs.contains(panelID) {
			notesWindows.removeValue(forKey: panelID)?.close()
		}
		for (workspaceID, panel): (WorkspaceID, PanelDescriptor) in notePanels {
			let controller: NotesWindowController
			if let existing: NotesWindowController = notesWindows[panel.id] {
				controller = existing
			} else {
				controller = .init(
					panelID: panel.id,
					title: panel.title,
					text: notes[panel.id] ?? Self.defaultNotes,
					onChange: { [weak self] text in
						self?.notes[panel.id] = text
						self?.scheduleSave()
					},
					onFocus: { [weak self] panelID in
						guard let self else { return }
						try? self.presentation.setVirtualFocus(
							workspaceID: workspaceID,
							panelID: panelID
						)
						self.updateChrome()
					}
				)
				notesWindows[panel.id] = controller
			}
			guard let frame: LayoutRect = nextLayout.panelFrames[panel.id] else {
				controller.close()
				continue
			}
			controller.update(frame: nsRect(frame), visible: true)
		}
	}

	private func raiseFocusedWorkspaceIfNeeded() {
		guard case .focused(let workspaceID) = presentation.mode,
			let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
		else { return }
		for panelID: PanelID in workspace.panelTree.leaves {
			if let identity: ExternalWindowIdentity = panelAssignments[panelID],
				let lease: ManagedExternalWindow = leases[identity]
			{
				try? lease.raise()
			} else if let notesWindow: NotesWindowController = notesWindows[panelID],
				let frame: LayoutRect = layout?.panelFrames[panelID]
			{
				notesWindow.update(frame: nsRect(frame), visible: true)
			}
		}
	}

	private func closeNotesWindows() {
		for controller: NotesWindowController in notesWindows.values {
			controller.close()
		}
		notesWindows.removeAll()
	}

	private func updateChrome() {
		guard isRunning else { return }
		let overlaySnapshots: [DesktopOverlaySnapshot]
		if !isStageActive {
			overlaySnapshots = []
		} else if let layout {
			overlaySnapshots = displays.enumerated().map { index, display in
				.init(
					displayID: display.id,
					screenFrame: display.frame,
					presentation: presentation,
					layout: layout,
					arrangeMode: arrangeModeEnabled,
					dragActive: draggingIdentity != nil,
					dropHighlight: dropHighlight,
					status: index == 0 ? statusMessage : nil
				)
			}
		} else {
			overlaySnapshots = displays.enumerated().map { index, display in
				.init(
					displayID: display.id,
					screenFrame: display.frame,
					workspaces: [],
					panels: [],
					dividers: [],
					virtualFocus: presentation.virtualFocus,
					arrangeMode: arrangeModeEnabled,
					status: index == 0 ? statusMessage : nil
				)
			}
		}
		overlayController.update(overlaySnapshots)
		let virtualPanelID: PanelID? = presentation.virtualFocus.panelID
		let canHandInput: Bool = virtualPanelID.map {
			panelAssignments[$0] != nil || notesWindows[$0] != nil
		} ?? false
		let accessibility: DesktopStageAccessibilityState =
			ManagedExternalWindow.permissionStatus(prompt: false) == .authorized
				? .authorized
				: .notAuthorized
		controlWindow.update(
			active: isStageActive,
			arranging: arrangeModeEnabled,
			authorized: accessibility == .authorized,
			message: statusMessage
		)
		statusController.update(
			.init(
				arrangeModeEnabled: arrangeModeEnabled,
				workspaceFocused: {
					if case .focused = presentation.mode { return true }
					return false
				}(),
				hasVirtualPanel: virtualPanelID != nil,
				canSplit: virtualPanelID.flatMap { layout?.panelFrames[$0] } != nil,
				canCycleWorkspaces: workspaceOrder().count > 1,
				canHandInputToPanel: canHandInput,
				canUndo: undoSnapshot != nil,
				accessibility: accessibility,
				statusMessage: statusMessage,
				stageActive: isStageActive
			)
		)
	}

	private func setStatus(_ message: String) {
		statusMessage = message
		NSLog("Teaser: %@", message)
		updateChrome()
	}

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
			label = draggingIdentity.map(panelAssignments.values.contains) == true
				? "Swap Panels"
				: "Occupied · use an edge"
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

	private func isPanelOccupied(_ panelID: PanelID) -> Bool {
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
		let application: NSRunningApplication? = .init(
			processIdentifier: snapshot.identity.processIdentifier
		)
		return .init(
			id: panelID,
			title: snapshot.title.isEmpty ? snapshot.applicationName : snapshot.title,
			kindID: .generic,
			providerHint: .init(
				displayName: snapshot.applicationName,
				bundleIdentifier: application?.bundleIdentifier,
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

	private func showPanelTypeChooser(for panelID: PanelID) {
		guard let frame: LayoutRect = layout?.panelFrames[panelID] else { return }
		panelTypeChooser.show(
			for: panelID,
			near: nsRect(frame),
			definitions: presentation.panelKinds.allDefinitions
		) {
			[weak self] panelID, kindID in
			self?.setPanelKind(kindID, panelID: panelID)
		}
	}

	private func setPanelKind(_ kindID: PanelKindID, panelID: PanelID) {
		do {
			try performTransaction(label: "Panel type changed") {
				guard let workspaceID: WorkspaceID = workspaceID(containing: panelID),
					var workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID],
					var panel: PanelDescriptor = workspace.panels[panelID]
				else {
					throw DesktopStageControllerError.panelUnavailable(panelID)
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

	private func presentPanelDefinitionEditor() {
		panelDefinitionEditor.present { [weak self] result in
			guard let self else { return }
			switch result {
			case .success(let definition):
				do {
					try self.performTransaction(label: "Panel type added") {
						try self.presentation.panelKinds.register(definition)
					}
				} catch {
					self.setStatus(error.localizedDescription)
				}
			case .failure(let error):
				self.setStatus(error.localizedDescription)
			}
		}
	}

	private func confirmResetShowcase() {
		let alert: NSAlert = .init()
		alert.messageText = "Reset the Teaser showcase?"
		alert.informativeText = "This restores the six-Workspace layout and releases every adopted provider window."
		alert.addButton(withTitle: "Reset")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		resetShowcase()
	}

	private func resetShowcase() {
		stopStage()
		controlWindow.show()
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
		notes = [ShowcasePreset.notesPanelID: Self.defaultNotes]
		panelAssignments.removeAll()
		closeNotesWindows()
		layout = nil
		scheduleSave()
		setStatus("Showcase reset. Click Start Layout when ready.")
	}

	private func workspaceOrder() -> [WorkspaceID] {
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

	private func workspaceID(containing panelID: PanelID) -> WorkspaceID? {
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

	private func makePanelID(prefix: String) -> PanelID {
		.init("\(prefix)-\(UUID().uuidString.lowercased())")
	}

	private func makeSplitID(prefix: String) -> LayoutSplitID {
		.init("\(prefix)-\(UUID().uuidString.lowercased())")
	}

	private func scheduleSave() {
		guard store != nil else { return }
		saveTask?.cancel()
		saveTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(180))
			} catch {
				return
			}
			self?.saveTask = nil
			self?.saveNow()
		}
	}

	private func saveNow() {
		guard let store else { return }
		let persistedNotes: [PersistedNote] = notes.map {
			.init(panelID: $0.key, text: $0.value)
		}.sorted { $0.panelID.rawValue < $1.panelID.rawValue }
		do {
			try store.save(
				.init(presentation: presentation, notes: persistedNotes)
			)
		} catch {
			statusMessage = "Layout could not be saved: \(error.localizedDescription)"
			NSLog("Teaser: %@", statusMessage ?? "Persistence failed")
		}
	}
}

@MainActor
private final class ManagedWindowFocusObserver {
	typealias Handler = @MainActor (ExternalWindowIdentity) -> Void

	private final class Relay: @unchecked Sendable {
		private weak var owner: ManagedWindowFocusObserver?

		init(owner: ManagedWindowFocusObserver) {
			self.owner = owner
		}

		func receive(_ point: CGPoint) {
			Task { @MainActor [weak owner] in
				owner?.receive(point)
			}
		}
	}

	private final class MonitorToken: @unchecked Sendable {
		let value: Any

		init(_ value: Any) {
			self.value = value
		}

		deinit {
			NSEvent.removeMonitor(value)
		}
	}

	private let handler: Handler
	private var relay: Relay?
	private var monitor: MonitorToken?

	init(handler: @escaping Handler) {
		self.handler = handler
	}

	func start() throws {
		guard monitor == nil else { return }
		let relay: Relay = .init(owner: self)
		guard let value: Any = NSEvent.addGlobalMonitorForEvents(
			matching: .leftMouseDown,
			handler: { _ in
				relay.receive(NSEvent.mouseLocation)
			}
		) else {
			throw ManagedExternalWindowError.globalMonitorUnavailable
		}
		self.relay = relay
		monitor = .init(value)
	}

	func stop() {
		monitor = nil
		relay = nil
	}

	private func receive(_ point: CGPoint) {
		guard let selection: ExternalWindowSelection = try? ManagedExternalWindow.selectWindow(
			atAppKitScreenPoint: point
		) else { return }
		handler(selection.identity)
	}
}

private func nsRect(_ rect: LayoutRect) -> CGRect {
	.init(
		x: rect.origin.x,
		y: rect.origin.y,
		width: rect.size.width,
		height: rect.size.height
	)
}
