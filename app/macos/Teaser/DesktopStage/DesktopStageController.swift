import AppKit
import CoreGraphics
import Foundation

/// The AppKit shell around `DesktopStageOrchestrator`. It owns every window
/// Teaser creates, Accessibility permission UX, display topology, and local
/// persistence; the orchestration it drives contains no window creation and runs
/// unchanged under a substituted external-window environment.
@MainActor
final class DesktopStageController: NSObject, DesktopStageOrchestratorHost {
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

	private let orchestrator: DesktopStageOrchestrator
	private let store: PresentationStore?
	private let panelTypeChooser: PanelTypeChooserController = .init()
	private let panelDefinitionEditor: PanelDefinitionEditorController = .init()

	private var notesWindows: [PanelID: NotesWindowController] = [:]
	private var saveTask: Task<Void, Never>?
	private var isRunning: Bool = false
	private var permissionTask: Task<Void, Never>?
	private var lastPermissionStatus: ExternalWindowPermissionStatus?
	private var lastLoggedStatusMessage: String?

	private lazy var controlWindow: DesktopStageControlWindow = .init(
		onToggleStage: { [weak self] in self?.toggleStage() },
		onArrange: { [weak self] in self?.perform(.toggleArrange) },
		onRequestPermission: { [weak self] in self?.requestAccessibility() },
		onEditLayout: { [weak self] in self?.layoutEditorWindow.show() },
		onAdoptWindow: { [weak self] in self?.showWindowPicker() }
	)

	private lazy var layoutEditorModel: DesktopStageLayoutEditorModel = .init(
		presentation: orchestrator.presentation,
		onResize: { [weak self] reference, ratio in
			self?.orchestrator.setDividerRatio(ratio, scope: reference.scope, splitID: reference.splitID)
		},
		onUndo: { [weak self] in self?.orchestrator.undoLastLayoutChange() }
	)
	private lazy var layoutEditorWindow: DesktopStageLayoutEditorWindow = .init(model: layoutEditorModel)

	private lazy var windowPickerModel: DesktopStageWindowPickerModel = .init(
		onList: { [weak self] in self?.orchestrator.adoptableWindows() ?? [] },
		onAdopt: { [weak self] identity, panelID in
			self?.orchestrator.adoptWindow(identity: identity, into: panelID) ?? false
		}
	)
	private lazy var windowPickerWindow: DesktopStageWindowPickerWindow = .init(
		model: windowPickerModel
	)

	private lazy var overlayController: DesktopOverlayController = .init(
		callbacks: .init(
			onVirtualFocusChange: { [weak self] focus in
				self?.orchestrator.setVirtualFocus(focus)
			},
			onWorkspaceFocusRequest: { [weak self] workspaceID in
				self?.orchestrator.toggleWorkspaceFocus(workspaceID: workspaceID)
			},
			onPanelInputFocusRequest: { [weak self] panelID in
				self?.orchestrator.setVirtualPanel(panelID)
				self?.orchestrator.handInputToVirtualPanel()
			},
			onUndoRequest: { [weak self] in
				self?.orchestrator.undoLastLayoutChange()
			},
			onDividerRatioChange: { [weak self] scope, splitID, ratio in
				self?.orchestrator.setDividerRatio(ratio, scope: scope, splitID: splitID)
			}
		)
	)

	private lazy var managedWindowFocusObserver: ManagedWindowFocusObserver = .init {
		[weak self] identity in
		self?.orchestrator.synchronizeVirtualFocus(with: identity)
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
			onToggleStage: { [weak self] in self?.toggleStage() },
			onAdoptWindow: { [weak self] in self?.showWindowPicker() }
		)
	)

	override init() {
		let initialState: InitialState = Self.loadInitialState()
		self.store = initialState.store
		self.lastLoggedStatusMessage = initialState.statusMessage
		self.orchestrator = .init(
			presentation: initialState.presentation,
			notes: initialState.notes,
			statusMessage: initialState.statusMessage
		)
		super.init()
		orchestrator.host = self
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		installSystemObservers()
		orchestrator.setDisplays(connectedDisplaysWithFallback())
		controlWindow.show()
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

	/// The Accessibility walk runs here, when a person asks to see the list, and
	/// never from the chrome refresh path.
	func showWindowPicker() {
		windowPickerModel.update(from: orchestrator)
		windowPickerModel.refresh()
		windowPickerWindow.show()
	}

	func applicationDidBecomeActive() {
		guard isRunning else { return }
		refreshPermission()
		if orchestrator.isStageActive,
			orchestrator.permissionStatus(prompt: false) == .authorized
		{
			startExternalObservation(promptForAccessibility: false)
		}
		updateChrome()
	}

	func stop() {
		guard isRunning else { return }
		orchestrator.stopStage()
		isRunning = false
		permissionTask?.cancel()
		permissionTask = nil
		saveTask?.cancel()
		saveTask = nil
		saveNow()
		removeSystemObservers()
		orchestrator.shutdown()
		managedWindowFocusObserver.stop()
		shortcutMonitor.stop()
		panelTypeChooser.close()
		overlayController.close()
		statusController.close()
		controlWindow.close()
		layoutEditorWindow.close()
		windowPickerWindow.close()
		closeNotesWindows()
	}

	func perform(_ command: DesktopStageCommand) {
		orchestrator.perform(command)
	}

	func requestAccessibility() {
		_ = orchestrator.permissionStatus(prompt: true)
		refreshPermission()
		if orchestrator.permissionStatus(prompt: false) != .authorized {
			orchestrator.setStatus("Allow Teaser in System Settings, then drag the window again")
		}
	}

	// MARK: - DesktopStageOrchestratorHost

	func orchestratorDidChangeState(_ orchestrator: DesktopStageOrchestrator) {
		if let message: String = orchestrator.statusMessage,
			message != lastLoggedStatusMessage
		{
			ExternalWindowDiagnostics.logger.notice("status \(message, privacy: .public)")
		}
		lastLoggedStatusMessage = orchestrator.statusMessage
		shortcutMonitor.setArrangeModeEnabled(orchestrator.isArrangeModeEnabled)
		updateChrome()
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didSolve layout: PresentationLayout
	) {
		updateNotesWindows(using: layout)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		raiseContentIn panelID: PanelID
	) {
		guard let notesWindow: NotesWindowController = notesWindows[panelID],
			let frame: LayoutRect = orchestrator.layout?.panelFrames[panelID]
		else { return }
		notesWindow.update(frame: nsRect(frame), visible: true)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		handInputToContentIn panelID: PanelID
	) -> Bool {
		guard let notesWindow: NotesWindowController = notesWindows[panelID] else {
			return false
		}
		notesWindow.focus()
		return true
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		didCreatePanel panelID: PanelID
	) {
		showPanelTypeChooser(for: panelID)
	}

	func orchestratorDidRequestSave(_ orchestrator: DesktopStageOrchestrator) {
		scheduleSave()
	}

	func orchestratorWillStopStage(_ orchestrator: DesktopStageOrchestrator) {
		shortcutMonitor.stop()
		shortcutMonitor.setArrangeModeEnabled(false)
		managedWindowFocusObserver.stop()
		panelTypeChooser.close()
		overlayController.close()
		closeNotesWindows()
	}

	// MARK: - Stage lifecycle

	private func toggleStage() {
		if orchestrator.isStageActive { orchestrator.stopStage(); return }
		guard orchestrator.permissionStatus(prompt: false) == .authorized else {
			requestAccessibility()
			return
		}
		orchestrator.setDisplays(connectedDisplaysWithFallback())
		do {
			try orchestrator.startStage()
			try managedWindowFocusObserver.start()
			shortcutMonitor.start()
			controlWindow.close()
			orchestrator.setStatus("Drag a window by its title bar into a Panel")
		} catch {
			orchestrator.stopStage()
			orchestrator.setStatus(error.localizedDescription)
		}
	}

	private func startExternalObservation(promptForAccessibility: Bool) {
		guard orchestrator.permissionStatus(prompt: promptForAccessibility) == .authorized
		else {
			orchestrator.setStatus("Grant Accessibility from the Teaser menu, then drag the window again")
			return
		}
		do {
			try orchestrator.startDragObservation(promptForAccessibility: false)
			try managedWindowFocusObserver.start()
			if orchestrator.statusMessage?.contains("Accessibility") == true {
				orchestrator.setStatus(nil)
			}
		} catch {
			orchestrator.setStatus(error.localizedDescription)
		}
		updateChrome()
	}

	private func refreshPermission() {
		let permission: ExternalWindowPermissionStatus = orchestrator.permissionStatus(
			prompt: false
		)
		guard permission != lastPermissionStatus else { return }
		lastPermissionStatus = permission
		ExternalWindowDiagnostics.logger.notice(
			"accessibility \(permission == .authorized ? "authorized" : "not authorized", privacy: .public)"
		)
		if permission == .notAuthorized {
			if orchestrator.isStageActive { orchestrator.stopStage() }
			orchestrator.setStatus("Allow Accessibility, then click Start Layout")
		} else if orchestrator.isStageActive {
			orchestrator.setStatus("Accessibility allowed. Ready to start.")
			startExternalObservation(promptForAccessibility: false)
		} else {
			orchestrator.setStatus(
				orchestrator.releaseRetainedLeases()
					? "Accessibility allowed. Ready to start."
					: "Accessibility allowed; some window restorations still need retry."
			)
		}
		updateChrome()
	}

	// MARK: - Display topology and system notifications

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
		orchestrator.screenParametersDidChange(displays: connectedDisplaysWithFallback())
	}

	@objc
	private func activeSpaceDidChange(_ notification: Notification) {
		guard orchestrator.isStageActive else { return }
		orchestrator.stopStage()
		orchestrator.setStatus("Layout stopped after switching Space. Open Teaser to start here.")
	}

	// MARK: - Teaser-owned chrome

	private func updateChrome() {
		guard isRunning else { return }
		let presentation: WorkspacePresentation = orchestrator.presentation
		let layout: PresentationLayout? = orchestrator.layout
		layoutEditorModel.update(from: orchestrator)
		windowPickerModel.update(from: orchestrator)
		let overlaySnapshots: [DesktopOverlaySnapshot]
		if !orchestrator.isStageActive {
			overlaySnapshots = []
		} else if let layout {
			overlaySnapshots = orchestrator.displays.enumerated().map { index, display in
				.init(
					displayID: display.id,
					screenFrame: display.frame,
					presentation: presentation,
					layout: layout,
					arrangeMode: orchestrator.isArrangeModeEnabled,
					dragActive: orchestrator.isDragging,
					dropHighlight: orchestrator.dropHighlight,
					status: index == 0 ? orchestrator.statusMessage : nil
				)
			}
		} else {
			overlaySnapshots = orchestrator.displays.enumerated().map { index, display in
				.init(
					displayID: display.id,
					screenFrame: display.frame,
					workspaces: [],
					panels: [],
					dividers: [],
					virtualFocus: presentation.virtualFocus,
					arrangeMode: orchestrator.isArrangeModeEnabled,
					status: index == 0 ? orchestrator.statusMessage : nil
				)
			}
		}
		overlayController.update(overlaySnapshots)
		let virtualPanelID: PanelID? = presentation.virtualFocus.panelID
		let canHandInput: Bool = virtualPanelID.map {
			orchestrator.panelAssignments[$0] != nil || notesWindows[$0] != nil
		} ?? false
		let accessibility: DesktopStageAccessibilityState =
			orchestrator.permissionStatus(prompt: false) == .authorized
				? .authorized
				: .notAuthorized
		controlWindow.update(
			active: orchestrator.isStageActive,
			arranging: orchestrator.isArrangeModeEnabled,
			authorized: accessibility == .authorized,
			message: orchestrator.statusMessage
		)
		statusController.update(
			.init(
				arrangeModeEnabled: orchestrator.isArrangeModeEnabled,
				workspaceFocused: {
					if case .focused = presentation.mode { return true }
					return false
				}(),
				hasVirtualPanel: virtualPanelID != nil,
				canSplit: virtualPanelID.flatMap { layout?.panelFrames[$0] } != nil,
				canCycleWorkspaces: orchestrator.workspaceOrder().count > 1,
				canHandInputToPanel: canHandInput,
				canUndo: orchestrator.canUndo,
				accessibility: accessibility,
				statusMessage: orchestrator.statusMessage,
				stageActive: orchestrator.isStageActive
			)
		)
	}

	private func updateNotesWindows(using nextLayout: PresentationLayout) {
		let presentation: WorkspacePresentation = orchestrator.presentation
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
		for (_, panel): (WorkspaceID, PanelDescriptor) in notePanels {
			let controller: NotesWindowController
			if let existing: NotesWindowController = notesWindows[panel.id] {
				controller = existing
			} else {
				controller = .init(
					panelID: panel.id,
					title: panel.title,
					text: orchestrator.notes[panel.id] ?? Self.defaultNotes,
					onChange: { [weak self] text in
						self?.orchestrator.setNote(text, for: panel.id)
					},
					onFocus: { [weak self] panelID in
						self?.orchestrator.setVirtualPanel(panelID)
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

	private func closeNotesWindows() {
		for controller: NotesWindowController in notesWindows.values {
			controller.close()
		}
		notesWindows.removeAll()
	}

	private func showPanelTypeChooser(for panelID: PanelID) {
		guard let frame: LayoutRect = orchestrator.layout?.panelFrames[panelID] else {
			return
		}
		panelTypeChooser.show(
			for: panelID,
			near: nsRect(frame),
			definitions: orchestrator.presentation.panelKinds.allDefinitions
		) {
			[weak self] panelID, kindID in
			self?.orchestrator.setPanelKind(kindID, panelID: panelID)
		}
	}

	private func presentPanelDefinitionEditor() {
		panelDefinitionEditor.present { [weak self] result in
			guard let self else { return }
			switch result {
			case .success(let definition):
				self.orchestrator.registerPanelKind(definition)
			case .failure(let error):
				self.orchestrator.setStatus(error.localizedDescription)
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
		orchestrator.stopStage()
		controlWindow.show()
		orchestrator.resetShowcase(defaultNotes: Self.defaultNotes)
		closeNotesWindows()
	}

	// MARK: - Persistence

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
		let persistedNotes: [PersistedNote] = orchestrator.notes.map {
			.init(panelID: $0.key, text: $0.value)
		}.sorted { $0.panelID.rawValue < $1.panelID.rawValue }
		do {
			try store.save(
				.init(presentation: orchestrator.presentation, notes: persistedNotes)
			)
		} catch {
			orchestrator.setStatus("Layout could not be saved: \(error.localizedDescription)")
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
		guard let selection: any ExternalWindowHandle = try? ManagedExternalWindow.selectWindow(
			atAppKitScreenPoint: point
		) else { return }
		handler(selection.identity)
	}
}
