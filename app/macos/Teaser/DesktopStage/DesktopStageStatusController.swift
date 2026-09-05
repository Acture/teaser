import AppKit

enum DesktopStageAccessibilityState: Equatable, Sendable {
	case authorized
	case notAuthorized
	case unavailable(reason: String)
}

struct DesktopStageStatusState: Equatable, Sendable {
	let arrangeModeEnabled: Bool
	let workspaceFocused: Bool
	let hasVirtualPanel: Bool
	let canSplit: Bool
	let canCycleWorkspaces: Bool
	let canHandInputToPanel: Bool
	let canUndo: Bool
	let accessibility: DesktopStageAccessibilityState
	let statusMessage: String?
	let stageActive: Bool

	init(
		arrangeModeEnabled: Bool = false,
		workspaceFocused: Bool = false,
		hasVirtualPanel: Bool = false,
		canSplit: Bool = false,
		canCycleWorkspaces: Bool = true,
		canHandInputToPanel: Bool = false,
		canUndo: Bool = false,
		accessibility: DesktopStageAccessibilityState = .notAuthorized,
		statusMessage: String? = nil,
		stageActive: Bool = false
	) {
		self.arrangeModeEnabled = arrangeModeEnabled
		self.workspaceFocused = workspaceFocused
		self.hasVirtualPanel = hasVirtualPanel
		self.canSplit = canSplit
		self.canCycleWorkspaces = canCycleWorkspaces
		self.canHandInputToPanel = canHandInputToPanel
		self.canUndo = canUndo
		self.accessibility = accessibility
		self.statusMessage = statusMessage
		self.stageActive = stageActive
	}
}

@MainActor
struct DesktopStageStatusCallbacks {
	let onCommand: @MainActor (DesktopStageCommand) -> Void
	let onAddPanelKind: @MainActor () -> Void
	let onResetShowcase: @MainActor () -> Void
	let onRequestAccessibility: @MainActor () -> Void
	let onQuit: @MainActor () -> Void
	let onShowControls: @MainActor () -> Void
	let onToggleStage: @MainActor () -> Void

	init(
		onCommand: @escaping @MainActor (DesktopStageCommand) -> Void,
		onAddPanelKind: @escaping @MainActor () -> Void,
		onResetShowcase: @escaping @MainActor () -> Void,
		onRequestAccessibility: @escaping @MainActor () -> Void,
		onQuit: @escaping @MainActor () -> Void,
		onShowControls: @escaping @MainActor () -> Void,
		onToggleStage: @escaping @MainActor () -> Void
	) {
		self.onCommand = onCommand
		self.onAddPanelKind = onAddPanelKind
		self.onResetShowcase = onResetShowcase
		self.onRequestAccessibility = onRequestAccessibility
		self.onQuit = onQuit
		self.onShowControls = onShowControls
		self.onToggleStage = onToggleStage
	}
}

/// Owns Teaser's status item and renders a menu from immutable coordinator state.
/// The controller does not mutate the presentation model itself.
@MainActor
final class DesktopStageStatusController: NSObject {
	private enum Action: Int {
		case showControls
		case toggleStage
		case toggleArrange
		case splitPanel
		case toggleWorkspaceFocus
		case previousWorkspace
		case nextWorkspace
		case handInputToPanel
		case undo
		case addPanelKind
		case resetShowcase
		case requestAccessibility
		case quit
	}

	private let callbacks: DesktopStageStatusCallbacks
	private let statusBar: NSStatusBar
	private let statusItem: NSStatusItem
	private var state: DesktopStageStatusState
	private var isClosed: Bool = false

	init(
		initialState: DesktopStageStatusState = .init(),
		callbacks: DesktopStageStatusCallbacks,
		statusBar: NSStatusBar = .system
	) {
		self.callbacks = callbacks
		self.statusBar = statusBar
		self.statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
		self.state = initialState
		super.init()
		configureButton()
		rebuildMenu()
	}

	func update(_ state: DesktopStageStatusState) {
		guard !isClosed else { return }
		self.state = state
		rebuildMenu()
	}

	func close() {
		guard !isClosed else { return }
		isClosed = true
		statusItem.menu = nil
		statusBar.removeStatusItem(statusItem)
	}

	private func configureButton() {
		guard let button: NSStatusBarButton = statusItem.button else { return }
		button.toolTip = "Teaser Desktop Stage"
		button.image = NSImage(
			systemSymbolName: "rectangle.3.group",
			accessibilityDescription: "Teaser"
		)
		if button.image == nil {
			button.title = "T"
		}
	}

	private func rebuildMenu() {
		let menu: NSMenu = .init(title: "Teaser")
		menu.autoenablesItems = false
		menu.addItem(item(title: "Open Teaser", action: .showControls))
		menu.addItem(item(title: state.stageActive ? "Stop Layout" : "Start Layout", action: .toggleStage))
		menu.addItem(item(title: "Quit Teaser", action: .quit))
		menu.addItem(.separator())

		menu.addItem(
			item(
				title: "Arrange Mode",
				action: .toggleArrange,
				enabled: state.stageActive,
				state: state.arrangeModeEnabled ? .on : .off
			)
		)
		menu.addItem(
			item(
				title: "Split Panel",
				action: .splitPanel,
				enabled: state.stageActive && state.hasVirtualPanel && state.canSplit
			)
		)
		menu.addItem(
			item(
				title: state.workspaceFocused
					? "Restore Workspace Tiling"
					: "Focus Workspace",
				action: .toggleWorkspaceFocus,
				enabled: state.stageActive && state.hasVirtualPanel
			)
		)

		menu.addItem(.separator())
		menu.addItem(
			item(
				title: "Previous Workspace",
				action: .previousWorkspace,
				enabled: state.stageActive && state.canCycleWorkspaces
			)
		)
		menu.addItem(
			item(
				title: "Next Workspace",
				action: .nextWorkspace,
				enabled: state.stageActive && state.canCycleWorkspaces
			)
		)
		menu.addItem(
			item(
				title: "Hand Input to Panel",
				action: .handInputToPanel,
				enabled: state.stageActive && state.hasVirtualPanel && state.canHandInputToPanel
			)
		)
		menu.addItem(
			item(
				title: "Undo Last Layout Change (⌃⌥Z in Arrange)",
				action: .undo,
				enabled: state.stageActive && state.canUndo
			)
		)

		menu.addItem(.separator())
		menu.addItem(
			item(title: "Add Panel Type…", action: .addPanelKind)
		)
		menu.addItem(
			item(title: "Reset Showcase", action: .resetShowcase)
		)

		menu.addItem(.separator())
		menu.addItem(accessibilityItem())
		if let statusMessage: String = state.statusMessage,
			!statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{
			let statusItem: NSMenuItem = .init(title: statusMessage, action: nil, keyEquivalent: "")
			statusItem.isEnabled = false
			menu.addItem(statusItem)
		}

		statusItem.menu = menu
	}

	private func accessibilityItem() -> NSMenuItem {
		switch state.accessibility {
		case .authorized:
			return item(
				title: "Accessibility: Allowed",
				action: .requestAccessibility,
				enabled: false
			)
		case .notAuthorized:
			return item(
				title: "Grant Accessibility Access…",
				action: .requestAccessibility
			)
		case .unavailable(let reason):
			let menuItem: NSMenuItem = item(
				title: "Accessibility: Unavailable",
				action: .requestAccessibility,
				enabled: false
			)
			menuItem.toolTip = reason
			return menuItem
		}
	}

	private func item(
		title: String,
		action: Action,
		enabled: Bool = true,
		state: NSControl.StateValue = .off
	) -> NSMenuItem {
		let menuItem: NSMenuItem = .init(
			title: title,
			action: #selector(performAction(_:)),
			keyEquivalent: ""
		)
		menuItem.target = self
		menuItem.tag = action.rawValue
		menuItem.isEnabled = enabled
		menuItem.state = state
		return menuItem
	}

	@objc
	private func performAction(_ sender: NSMenuItem) {
		guard let action: Action = .init(rawValue: sender.tag) else { return }
		switch action {
		case .showControls:
			callbacks.onShowControls()
		case .toggleStage:
			callbacks.onToggleStage()
		case .toggleArrange:
			callbacks.onCommand(.toggleArrange)
		case .splitPanel:
			callbacks.onCommand(.splitPanel)
		case .toggleWorkspaceFocus:
			callbacks.onCommand(.toggleWorkspaceFocus)
		case .previousWorkspace:
			callbacks.onCommand(.previousWorkspace)
		case .nextWorkspace:
			callbacks.onCommand(.nextWorkspace)
		case .handInputToPanel:
			callbacks.onCommand(.handInputToPanel)
		case .undo:
			callbacks.onCommand(.undo)
		case .addPanelKind:
			callbacks.onAddPanelKind()
		case .resetShowcase:
			callbacks.onResetShowcase()
		case .requestAccessibility:
			callbacks.onRequestAccessibility()
		case .quit:
			callbacks.onQuit()
		}
	}
}
