import AppKit
import CoreGraphics
import Foundation

/// The AppKit shell around `DesktopStageOrchestrator`. It owns every window
/// Teaser creates, Accessibility permission UX, Space awareness, and local
/// persistence; the orchestration it drives contains no window creation and runs
/// unchanged under a substituted external-window environment.
///
/// Teaser has several canvases. Each open canvas window is one display to the
/// orchestrator, so Workspaces, dividers and drop targets are scoped to the
/// canvas that shows them, while leases, the drag observer and the one-lease-per
/// window rule stay app-wide. Closing a canvas releases only its own windows.
@MainActor
final class DesktopStageController: NSObject, DesktopStageOrchestratorHost {
	private struct InitialState {
		let presentation: WorkspacePresentation
		let notes: [PanelID: String]
		let store: PresentationStore?
		let statusMessage: String?
	}

	/// What reopening needs: the identity the Workspaces are still placed on,
	/// and where the window was. Restoring across launches belongs to P-563.
	private struct ClosedCanvas {
		let id: CanvasID
		let frame: LayoutRect?
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
	private let canvasesMenu: NSMenu
	private let lifecycle: CanvasLifecycle = .init()
	private let spaces: SpaceDirectory = .init()
	private lazy var organization: OrganizationSession = .init(orchestrator: orchestrator,
		archiveDirectory: store?.documentURL.deletingLastPathComponent().appendingPathComponent("connection-scopes", isDirectory: true))
	private lazy var organizationControls: OrganizationControls = .init(model: .init(session: organization,
		startStage: { [weak self] in self?.toggleStage() },
		adoptWindow: { [weak self] in self?.showWindowPicker() }))

	private var canvases: [CanvasID: DesktopCanvasWindow] = [:]
	private var closedCanvases: [ClosedCanvas] = []
	private var canvasSequence: Int = 0
	/// New Workspaces land on the canvas the person used last, not on whichever
	/// canvas happens to be first.
	private var lastKeyCanvasID: CanvasID?
	private var notesPanels: [PanelID: NotesPanelController] = [:]
	private var saveTask: Task<Void, Never>?
	private var isRunning: Bool = false
	private var permissionTask: Task<Void, Never>?
	private var newSpaceTask: Task<Void, Never>?
	private var lastPermissionStatus: ExternalWindowPermissionStatus?
	private var lastLoggedStatusMessage: String?

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
		},
		onStartStage: { [weak self] in self?.toggleStage() }
	)
	private lazy var windowPickerWindow: DesktopStageWindowPickerWindow = .init(
		model: windowPickerModel
	)

	private lazy var overlayCallbacks: DesktopOverlayCallbacks = .init(
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
			onShowControls: { [weak self] in
				self?.reopenFromDock()
				self?.organizationControls.show()
			},
			onToggleStage: { [weak self] in self?.toggleStage() },
			onAdoptWindow: { [weak self] in self?.showWindowPicker() },
			onEditLayout: { [weak self] in self?.layoutEditorWindow.show() }
		)
	)

	init(canvasesMenu: NSMenu) {
		let initialState: InitialState = Self.loadInitialState()
		self.canvasesMenu = canvasesMenu
		self.store = initialState.store
		self.lastLoggedStatusMessage = initialState.statusMessage
		self.orchestrator = .init(
			presentation: initialState.presentation,
			notes: initialState.notes,
			statusMessage: initialState.statusMessage
		)
		super.init()
		orchestrator.host = self
		// A drop belongs to the canvas under the pointer. Without this, Panels of
		// a canvas on another Space, or of an overlapping canvas, match the same
		// point and the dragged window is detached instead of adopted.
		orchestrator.canvasDisplayAtScreenPoint = { [weak self] point in
			self?.canvasDisplay(atScreenPoint: point)
		}
		organization.onChange = { [weak self] in
			guard let self else { return }
			self.organizationControls.model.refresh()
			self.updateNoteContent()
		}
		organization.onProjection = { [weak self] in
			guard let self else { return }
			if let layout: PresentationLayout = self.orchestrator.layout {
				self.updateNotesPanels(using: layout)
			} else {
				self.removeAllNotesPanels()
			}
		}
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		installSystemObservers()
		// Launch opens one canvas filling its screen. Filling keeps it on this
		// Space, which is the only state where adopted windows can sit inside it.
		openCanvas(fill: .fillScreen)
		organizationControls.show()
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

	private static let accessibilityRequest: String =
		"Allow Teaser in System Settings › Privacy & Security › Accessibility. "
		+ "Then explicitly Start Stage or Adopt Window."

	// MARK: - Canvases

	func openCanvas(inNewSpace newSpace: Bool) {
		guard newSpace else {
			openCanvas(fill: .free)
			return
		}
		openCanvasInNewSpace()
	}

	private func openCanvas(fill: CanvasFillMode, restoring closed: ClosedCanvas? = nil) {
		canvasSequence += 1
		let id: CanvasID = closed?.id ?? .init("canvas-\(canvasSequence)")
		let canvas: DesktopCanvasWindow = makeCanvas(id: id, index: canvases.count + 1)
		canvases[id] = canvas
		if let frame: LayoutRect = closed?.frame {
			canvas.setFrame(frame)
		}
		canvas.show(space: currentSpace())
		lastKeyCanvasID = id
		organization.setTargetDisplay(.init(canvas: id))
		if fill == .fillScreen {
			setFill(.fillScreen, on: canvas)
		}
		canvasesDidChange()
	}

	private func makeCanvas(id: CanvasID, index: Int) -> DesktopCanvasWindow {
		let canvas: DesktopCanvasWindow = .init(
			id: id,
			snapshot: .init(
				displayID: .init(canvas: id),
				screenFrame: .init(x: 0, y: 0, width: 1_200, height: 800),
				workspaces: [],
				panels: [],
				dividers: [],
				virtualFocus: orchestrator.presentation.virtualFocus,
				arrangeMode: false
			),
			callbacks: overlayCallbacks,
			onEvent: { [weak self] event in self?.handle(event) },
			onContentClick: { [weak self] panelID in
				self?.orchestrator.setVirtualPanel(panelID)
			}
		)
		canvas.window.title = "Teaser — Canvas \(index)"
		return canvas
	}

	/// Mission Control's own controls add the desktop and switch to it; Teaser
	/// creates no Space itself and synthesizes no input. Every step is bounded
	/// and reports what it could not do.
	private func openCanvasInNewSpace() {
		guard newSpaceTask == nil else { return }
		newSpaceTask = Task { @MainActor [weak self] in
			defer { self?.newSpaceTask = nil }
			guard let self else { return }
			do {
				let before: SpaceSnapshot = try self.spaces.snapshot()
				NSWorkspace.shared.open(URL(fileURLWithPath: Self.missionControlPath))
				try await Task.sleep(for: .milliseconds(1_200))
				guard try self.spaces.addDesktop() else {
					self.orchestrator.setStatus(
						"Mission Control is not offering its add-desktop button. Add a desktop there, then use New Canvas."
					)
					return
				}
				try await Task.sleep(for: .milliseconds(800))
				let after: SpaceSnapshot = try self.spaces.snapshot()
				guard let added: SpaceIdentity = Self.addedSpace(before: before, after: after),
					let index: Int = after.index(of: added)
				else {
					self.orchestrator.setStatus("The new desktop did not appear in Mission Control; no canvas was opened.")
					return
				}
				try self.spaces.activateSpace(atSpacesBarIndex: index)
				try await Task.sleep(for: .milliseconds(600))
				self.openCanvas(fill: .fillScreen)
			} catch {
				self.orchestrator.setStatus(
					"A new Space could not be prepared: \(error.localizedDescription). Add a desktop in Mission Control, then use New Canvas."
				)
			}
		}
	}

	private static let missionControlPath: String = "/System/Applications/Mission Control.app"

	private static func addedSpace(before: SpaceSnapshot, after: SpaceSnapshot) -> SpaceIdentity? {
		let known: Set<Int> = .init(before.monitors.flatMap { $0.spaces.map(\.managedID) })
		return after.monitors
			.flatMap(\.spaces)
			.first { !$0.isFullScreen && !known.contains($0.managedID) }
	}

	func reopenMostRecentlyClosedCanvas() {
		guard let closed: ClosedCanvas = closedCanvases.popLast() else {
			orchestrator.setStatus("No closed canvas to reopen.")
			updateChrome()
			return
		}
		openCanvas(fill: .free, restoring: closed)
	}

	/// Clicking the Dock icon with every canvas closed opens one again; with a
	/// canvas open it brings the last one forward, switching Space if it lives
	/// on another one.
	func reopenFromDock() {
		guard let canvas: DesktopCanvasWindow = keyCanvas() else {
			openCanvas(fill: .fillScreen)
			return
		}
		canvas.bringForward()
	}

	func goToCanvas(at index: Int) {
		let ordered: [CanvasID] = lifecycle.openCanvases
		guard ordered.indices.contains(index) else { return }
		canvases[ordered[index]]?.bringForward()
	}

	func toggleFillScreenOnKeyCanvas() {
		guard let canvas: DesktopCanvasWindow = keyCanvas(),
			let state: CanvasState = lifecycle.state(of: canvas.id)
		else { return }
		setFill(state.fill == .fillScreen ? .free : .fillScreen, on: canvas)
	}

	/// The mode is the lifecycle's, the rectangle is the host's: only AppKit
	/// knows the screen this canvas is on.
	private func setFill(_ fill: CanvasFillMode, on canvas: DesktopCanvasWindow) {
		apply(lifecycle.handle(.fillModeRequested(canvas.id, fill)))
		guard lifecycle.state(of: canvas.id)?.phase.isFullScreen != true else { return }
		switch fill {
		case .fillScreen:
			guard let frame: LayoutRect = canvas.screenFillFrame else { return }
			canvas.setFrame(frame)
		case .free:
			guard let visible: NSRect = (canvas.window.screen ?? NSScreen.main)?.visibleFrame else { return }
			canvas.setFrame(
				.init(
					x: Double(visible.minX) + 60,
					y: Double(visible.minY) + 60,
					width: Double(visible.width) - 120,
					height: Double(visible.height) - 120
				)
			)
		}
	}

	private func handle(_ event: CanvasEvent) {
		if case .opened(let id, _, _) = event { lastKeyCanvasID = id }
		apply(lifecycle.handle(event))
		guard case .windowClosed(let id) = event else { return }
		// The window is gone, so the canvas stops being a display. Its adopted
		// windows were already released by the preceding `releaseCanvas` effect;
		// re-projecting now is what stops showing its Workspaces, and it must
		// happen after the release, which finds Panels through their placement.
		canvases.removeValue(forKey: id)
		if lastKeyCanvasID == id { lastKeyCanvasID = lifecycle.openCanvases.last }
		if let target: CanvasID = lastKeyCanvasID {
			organization.setTargetDisplay(.init(canvas: target))
		}
		canvasesDidChange()
	}

	private func apply(_ effects: [CanvasEffect]) {
		var displaysChanged: Bool = false
		for effect: CanvasEffect in effects {
			switch effect {
			case .enterFullScreen(let id), .exitFullScreen(let id):
				// macOS ignores a toggle issued from inside a fullscreen callback,
				// so the transition starts on the next run-loop turn.
				let canvas: DesktopCanvasWindow? = canvases[id]
				Task { @MainActor in canvas?.toggleFullScreen() }
			case .setOpaque(let id, let opaque):
				canvases[id]?.setOpaque(opaque)
			case .setBackdropLevel(let id, let backdrop):
				canvases[id]?.setBackdropLevel(backdrop)
			case .setFrame(let id, let frame):
				canvases[id]?.setFrame(frame)
			case .releaseCanvas(let id):
				releaseCanvas(id)
			case .closeWindow(let id):
				canvases[id]?.closeWindow()
			case .displayFrame:
				displaysChanged = true
			}
		}
		if displaysChanged {
			orchestrator.screenParametersDidChange(displays: canvasDisplays())
			updateChrome()
		}
	}

	/// Everything this canvas holds, and nothing else: its adopted windows go
	/// back where they came from and its Teaser-owned content is torn down,
	/// while other canvases keep their leases and layouts.
	private func releaseCanvas(_ id: CanvasID) {
		let displayID: DisplayID = .init(canvas: id)
		let released: Bool = orchestrator.releaseWindows(onDisplay: displayID)
		if !released {
			orchestrator.setStatus(
				"Some windows of this canvas could not be restored; their leases are kept for a retry."
			)
		}
		if let canvas: DesktopCanvasWindow = canvases[id] {
			for panelID: PanelID in canvas.contentPanelIDs { canvas.removeContent(for: panelID) }
			closedCanvases.append(.init(id: id, frame: canvas.canvasFrame))
		}
	}

	private func canvasesDidChange() {
		// setDisplays does not solve, so the projection can drop a closed
		// canvas's Workspaces before anything tries to lay them out.
		orchestrator.setDisplays(canvasDisplays())
		do {
			try organization.canvasesDidChange()
		} catch {
			orchestrator.setStatus("Canvas placement could not be applied: \(error.localizedDescription)")
		}
		orchestrator.relayout(synchronously: orchestrator.isStageActive)
		updateCanvasesMenu()
		updateChrome()
	}

	private func canvasDisplays() -> [DesktopStageDisplay] {
		lifecycle.openCanvases.compactMap { id in
			guard let frame: LayoutRect = lifecycle.state(of: id)?.settledFrame else { return nil }
			return .init(id: .init(canvas: id), frame: frame)
		}
	}

	private func keyCanvas() -> DesktopCanvasWindow? {
		if let id: CanvasID = lastKeyCanvasID, let canvas: DesktopCanvasWindow = canvases[id] {
			return canvas
		}
		return lifecycle.openCanvases.compactMap { canvases[$0] }.last
	}

	/// The frontmost canvas that can actually receive the drop: one that is
	/// visible on the Space the pointer is on.
	private func canvasDisplay(atScreenPoint point: CGPoint) -> DisplayID? {
		for window: NSWindow in NSApplication.shared.orderedWindows {
			guard let canvasWindow: CanvasNSWindow = window as? CanvasNSWindow,
				canvasWindow.isVisible,
				canvasWindow.isOnActiveSpace,
				canvasWindow.frame.contains(point),
				let canvas: DesktopCanvasWindow = canvases.values.first(where: { $0.window === canvasWindow })
			else { continue }
			return .init(canvas: canvas.id)
		}
		return nil
	}

	private func currentSpace() -> SpaceIdentity? {
		try? spaces.currentSpace(ofDisplayIdentifier: "Main")
	}

	private func updateCanvasesMenu() {
		TeaserMainMenu.fill(
			canvasesMenu,
			with: lifecycle.openCanvases.compactMap { id in
				guard let canvas: DesktopCanvasWindow = canvases[id] else { return nil }
				return (id: id, title: canvas.window.title)
			}
		)
	}

	/// The Accessibility walk runs here, when a person asks to see the list, and
	/// never from the chrome refresh path.
	func showWindowPicker() {
		if !orchestrator.isStageActive { toggleStage() }
		guard orchestrator.isStageActive else { return }
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
		organization.disconnect()
		orchestrator.stopStage()
		isRunning = false
		permissionTask?.cancel()
		permissionTask = nil
		newSpaceTask?.cancel()
		newSpaceTask = nil
		saveTask?.cancel()
		saveTask = nil
		saveNow()
		removeSystemObservers()
		orchestrator.shutdown()
		managedWindowFocusObserver.stop()
		shortcutMonitor.stop()
		panelTypeChooser.close()
		statusController.close()
		layoutEditorWindow.close()
		windowPickerWindow.close()
		organizationControls.close()
		removeAllNotesPanels()
		// Quitting is the one global teardown: every canvas goes, in one pass.
		for canvas: DesktopCanvasWindow in canvases.values { canvas.closeWindow() }
		canvases.removeAll()
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
		updateNotesPanels(using: layout)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		raiseContentIn panelID: PanelID
	) {
		guard let layout: PresentationLayout = orchestrator.layout else { return }
		updateNotesPanels(using: layout)
	}

	func orchestrator(
		_ orchestrator: DesktopStageOrchestrator,
		handInputToContentIn panelID: PanelID
	) -> Bool {
		guard let controller: NotesPanelController = notesPanels[panelID] else {
			return false
		}
		controller.focus()
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
		removeAllNotesPanels()
	}

	// MARK: - Stage lifecycle

	private func toggleStage() {
		if orchestrator.isStageActive { orchestrator.stopStage(); return }
		guard organization.client.state == .ready else {
			orchestrator.setStatus("Connect to Herdr before starting the stage. Stop/Release remains available offline."); return
		}
		guard orchestrator.permissionStatus(prompt: false) == .authorized else {
			requestAccessibility()
			return
		}
		orchestrator.setDisplays(canvasDisplays())
		do {
			try orchestrator.startStage()
			try managedWindowFocusObserver.start()
			shortcutMonitor.start()
			orchestrator.setStatus("Drag a window onto a canvas to adopt it")
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
			orchestrator.setStatus(Self.accessibilityRequest)
		} else if orchestrator.isStageActive {
			orchestrator.setStatus("Accessibility allowed. Drag a window onto a canvas.")
			startExternalObservation(promptForAccessibility: false)
		} else {
			orchestrator.setStatus("Accessibility allowed. Use Start Stage to begin adoption.")
		}
		updateChrome()
	}

	// MARK: - System notifications

	private func installSystemObservers() {
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(screenParametersDidChange(_:)),
			name: NSApplication.didChangeScreenParametersNotification,
			object: nil
		)
	}

	private func removeSystemObservers() {
		NotificationCenter.default.removeObserver(self)
	}

	/// A display change moves canvases, and the canvases are the displays the
	/// solver works in. Physical screens are never fed to the orchestrator: that
	/// would lay Panels out on the desktop instead of inside a canvas.
	@objc
	private func screenParametersDidChange(_ notification: Notification) {
		for canvas: DesktopCanvasWindow in canvases.values {
			handle(.geometryChanged(canvas.id, frame: canvas.canvasFrame))
		}
	}

	// MARK: - Teaser-owned chrome

	private func updateChrome() {
		guard isRunning else { return }
		let presentation: WorkspacePresentation = orchestrator.presentation
		let layout: PresentationLayout? = orchestrator.layout
		layoutEditorModel.update(from: orchestrator)
		windowPickerModel.update(from: orchestrator)
		for (id, canvas): (CanvasID, DesktopCanvasWindow) in canvases {
			let displayID: DisplayID = .init(canvas: id)
			let canvasFrame: LayoutRect = lifecycle.state(of: id)?.settledFrame ?? canvas.canvasFrame
			// Status is not drawn into the canvas: drawn text cannot be copied, so
			// the canvas shows it in a selectable label instead.
			if let layout {
				canvas.update(.init(
					displayID: displayID,
					screenFrame: canvasFrame,
					presentation: presentation,
					layout: layout,
					arrangeMode: orchestrator.isArrangeModeEnabled,
					dragActive: orchestrator.isDragging,
					dropHighlight: dropHighlight(on: displayID),
					status: nil
				))
			} else {
				canvas.update(.init(
					displayID: displayID,
					screenFrame: canvasFrame,
					workspaces: [],
					panels: [],
					dividers: [],
					virtualFocus: presentation.virtualFocus,
					arrangeMode: orchestrator.isArrangeModeEnabled,
					status: nil
				))
			}
			canvas.setStatus(status(for: id))
		}
		let virtualPanelID: PanelID? = presentation.virtualFocus.panelID
		let canHandInput: Bool = virtualPanelID.map {
			orchestrator.panelAssignments[$0] != nil || notesPanels[$0] != nil
		} ?? false
		let accessibility: DesktopStageAccessibilityState =
			orchestrator.permissionStatus(prompt: false) == .authorized
				? .authorized
				: .notAuthorized
		statusController.update(
			.init(
				arrangeModeEnabled: orchestrator.isArrangeModeEnabled,
				workspaceFocused: {
					if case .focused = presentation.mode { return true }
					return false
				}(),
				hasVirtualPanel: virtualPanelID != nil,
				canSplit: organization.client.canApply && virtualPanelID.flatMap { layout?.panelFrames[$0] } != nil,
				canCycleWorkspaces: orchestrator.workspaceOrder().count > 1,
				canHandInputToPanel: canHandInput,
				canUndo: orchestrator.canUndo,
				accessibility: accessibility,
				statusMessage: orchestrator.statusMessage,
				stageActive: orchestrator.isStageActive
			)
		)
	}

	/// A highlight belongs to the canvas whose Workspace it points at, so a drag
	/// never lights up a Panel outline on a canvas it cannot land on.
	private func dropHighlight(on displayID: DisplayID) -> DesktopOverlayDropHighlight? {
		guard let highlight: DesktopOverlayDropHighlight = orchestrator.dropHighlight,
			orchestrator.presentation.workspaces[highlight.workspaceID]?.displayAffinity == displayID
		else { return nil }
		return highlight
	}

	private func status(for id: CanvasID) -> String? {
		var lines: [String] = []
		if let message: String = orchestrator.statusMessage { lines.append(message) }
		if lifecycle.state(of: id)?.phase.isFullScreen == true,
			!panelIDs(onDisplay: .init(canvas: id)).isDisjoint(with: orchestrator.panelAssignments.keys)
		{
			// Being explicit beats a canvas that silently shows outlines with no
			// windows in them: macOS admits no other app's window to this Space.
			lines.append("Adopted windows stay on the desktop Space while this canvas is full screen.")
		}
		return lines.isEmpty ? nil : lines.joined(separator: "\n")
	}

	private func panelIDs(onDisplay displayID: DisplayID) -> Set<PanelID> {
		var result: Set<PanelID> = []
		for workspace: WorkspaceDescriptor in orchestrator.presentation.workspaces.values
		where workspace.displayAffinity == displayID {
			result.formUnion(workspace.panels.keys)
		}
		return result
	}

	// MARK: - Teaser-owned Panel content

	/// Notes live inside the canvas that shows their Panel, so they follow it
	/// into fullscreen and never strand themselves on another Space.
	private func updateNotesPanels(using layout: PresentationLayout) {
		let presentation: WorkspacePresentation = orchestrator.presentation
		var hosted: [CanvasID: Set<PanelID>] = [:]
		for workspace: WorkspaceDescriptor in presentation.workspaces.values {
			guard let canvasID: CanvasID = canvasID(forDisplay: workspace.displayAffinity),
				let canvas: DesktopCanvasWindow = canvases[canvasID]
			else { continue }
			for panel: PanelDescriptor in workspace.panels.values
			where panel.nativeContent == .notes {
				guard let frame: LayoutRect = layout.panelFrames[panel.id] else { continue }
				let controller: NotesPanelController = notesPanels[panel.id] ?? makeNotesPanel(for: panel)
				notesPanels[panel.id] = controller
				canvas.setContent(controller.view, for: panel.id, frame: frame)
				hosted[canvasID, default: []].insert(panel.id)
			}
		}
		for (id, canvas): (CanvasID, DesktopCanvasWindow) in canvases {
			for panelID: PanelID in canvas.contentPanelIDs.subtracting(hosted[id] ?? []) {
				canvas.removeContent(for: panelID)
			}
		}
		let live: Set<PanelID> = .init(hosted.values.flatMap { $0 })
		for panelID: PanelID in notesPanels.keys where !live.contains(panelID) {
			notesPanels.removeValue(forKey: panelID)
		}
	}

	private func makeNotesPanel(for panel: PanelDescriptor) -> NotesPanelController {
		.init(
			panelID: panel.id,
			title: panel.title,
			text: orchestrator.notes[panel.id] ?? Self.defaultNotes,
			onChange: { [weak self] text in
				self?.organization.setNote(text, panelID: panel.id)
			}
		)
	}

	private func removeAllNotesPanels() {
		for canvas: DesktopCanvasWindow in canvases.values { canvas.removeAllContent() }
		notesPanels.removeAll()
	}

	private func updateNoteContent() {
		for (panelID, controller): (PanelID, NotesPanelController) in notesPanels {
			controller.updateText(orchestrator.notes[panelID] ?? "")
		}
	}

	private func canvasID(forDisplay displayID: DisplayID) -> CanvasID? {
		canvases.keys.first { DisplayID(canvas: $0) == displayID }
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
		organizationControls.show()
		orchestrator.setStatus("Set a custom kind in Organization controls; size profiles remain server-owned.")
	}

	private func confirmResetShowcase() {
		organizationControls.show()
		orchestrator.setStatus("Delete Panels and empty parents explicitly in Organization controls.")
	}

	// MARK: - Persistence

	private static func loadInitialState() -> InitialState {
		// The legacy file remains untouched. It is never imported into the server
		// graph or overwritten with an empty shared projection.
		let presentation: WorkspacePresentation = .init(mode: .tiled, virtualFocus: .none,
			displayLayouts: [:], workspaces: [:], panelKinds: try! .init())
		do {
			return .init(presentation: presentation, notes: [:], store: try PresentationStore.live(),
				statusMessage: "Connect to an explicit Herdr socket in Connection & Organization.")
		} catch {
			return .init(presentation: presentation, notes: [:], store: nil,
				statusMessage: "Local archive unavailable: \(error.localizedDescription)")
		}
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
		_ = organization.save()
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
