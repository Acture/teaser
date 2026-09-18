import SwiftUI

/// A projection of the orchestrator for choosing a window to adopt. Dragging
/// needs a window the user can see; Stage Manager and other Spaces hide windows
/// without destroying them, so the picker is the entry those windows still have.
///
/// Two paths, kept apart because one of them is expensive. `update(from:)` is the
/// cheap projection the host calls on every state change and reads only layout
/// state. `refresh()` performs the Accessibility walk and runs only when the user
/// opens the picker or asks for it.
@MainActor
final class DesktopStageWindowPickerModel: ObservableObject {
	struct PanelChoice: Identifiable, Equatable {
		let id: PanelID
		let title: String
		let workspaceTitle: String
	}

	struct State: Equatable {
		var authorized: Bool = false
		var stageActive: Bool = false
		/// Only unoccupied Panels: the picker never replaces Panel content, the
		/// same rule `adoptWindow` enforces.
		var targets: [PanelChoice] = []
		var occupiedPanelTitles: [PanelID: String] = [:]
		var assignments: [PanelID: ExternalWindowIdentity] = [:]
		var statusMessage: String?
	}

	private(set) var state: State = .init()
	private(set) var candidates: [ExternalWindowCandidate] = []
	private(set) var selectedPanelID: PanelID?
	private(set) var message: String?
	@Published private(set) var revision: UInt = 0
	@Published var query: String = ""

	private let onList: @MainActor () -> [ExternalWindowCandidate]
	private let onAdopt: @MainActor (ExternalWindowIdentity, PanelID) -> Bool
	private let onStartStage: @MainActor () -> Void

	init(
		onList: @escaping @MainActor () -> [ExternalWindowCandidate],
		onAdopt: @escaping @MainActor (ExternalWindowIdentity, PanelID) -> Bool,
		onStartStage: @escaping @MainActor () -> Void = {}
	) {
		self.onList = onList
		self.onAdopt = onAdopt
		self.onStartStage = onStartStage
	}

	/// The picker is where a person finds out the layout is not running, so it is
	/// also where they can start it, instead of being sent back to another window.
	func startStage() {
		guard !state.stageActive else { return }
		onStartStage()
	}

	/// Why adopting the given window would fail right now, or nil when it would
	/// succeed. A disabled control that explains nothing is a dead end.
	func adoptionBlocker(for identity: ExternalWindowIdentity?) -> String? {
		guard let identity else { return "Choose a window from the list." }
		if !state.stageActive { return "Start the layout before adopting a window." }
		if selectedPanelID == nil { return "Choose the Panel to put this window in." }
		if let reason: String = candidates.first(where: {
			$0.identity == identity
		})?.rejectionReason {
			return reason
		}
		return nil
	}

	var rows: [ExternalWindowPickerRow] {
		externalWindowPickerRows(candidates: candidates, query: query)
	}

	var canAdopt: Bool { state.stageActive && selectedPanelID != nil }

	/// The Panel already holding a window, so a listed window Teaser manages reads
	/// as what it is instead of looking like a fresh candidate.
	func panelTitle(holding identity: ExternalWindowIdentity) -> String? {
		guard let panelID: PanelID = state.assignments.first(where: {
			$0.value == identity
		})?.key else { return nil }
		return state.occupiedPanelTitles[panelID] ?? panelID.rawValue
	}

	func update(from orchestrator: DesktopStageOrchestrator) {
		var targets: [PanelChoice] = []
		var occupiedPanelTitles: [PanelID: String] = [:]
		let workspaces: [WorkspaceDescriptor] = orchestrator.presentation.workspaces.values
			.sorted { $0.id.rawValue < $1.id.rawValue }
		for workspace: WorkspaceDescriptor in workspaces {
			for descriptor: PanelDescriptor in workspace.panels.values
				.sorted(by: { $0.id.rawValue < $1.id.rawValue })
			{
				if orchestrator.isPanelOccupied(descriptor.id) {
					occupiedPanelTitles[descriptor.id] = descriptor.title
				} else {
					targets.append(.init(
						id: descriptor.id,
						title: descriptor.title,
						workspaceTitle: workspace.title
					))
				}
			}
		}
		let next: State = .init(
			authorized: orchestrator.permissionStatus(prompt: false) == .authorized,
			stageActive: orchestrator.isStageActive,
			targets: targets,
			occupiedPanelTitles: occupiedPanelTitles,
			assignments: orchestrator.panelAssignments,
			statusMessage: orchestrator.statusMessage
		)
		guard next != state else { return }
		state = next
		if let selectedPanelID, !targets.contains(where: { $0.id == selectedPanelID }) {
			self.selectedPanelID = nil
		}
		revision &+= 1
	}

	/// The Accessibility walk. Never called from `update(from:)`, so opening a
	/// Panel or moving a divider never pays for it.
	func refresh() {
		candidates = onList()
		message = candidates.isEmpty ? "No window is available to adopt." : nil
		revision &+= 1
	}

	func select(panelID: PanelID?) {
		guard panelID == nil || state.targets.contains(where: { $0.id == panelID }) else {
			return
		}
		selectedPanelID = panelID
		revision &+= 1
	}

	@discardableResult
	func adopt(_ identity: ExternalWindowIdentity) -> Bool {
		guard state.stageActive else {
			message = "Start the layout before adopting a window."
			revision &+= 1
			return false
		}
		guard let panelID: PanelID = selectedPanelID else {
			message = "Choose the Panel to put this window in."
			revision &+= 1
			return false
		}
		if let reason: String = candidates.first(where: {
			$0.identity == identity
		})?.rejectionReason {
			message = reason
			revision &+= 1
			return false
		}
		let adopted: Bool = onAdopt(identity, panelID)
		// The orchestrator owns the reason; repeating it here would be a second
		// copy that drifts, so the picker points at the status it already set.
		message = adopted ? nil : state.statusMessage
		revision &+= 1
		return adopted
	}
}

@MainActor
struct DesktopStageWindowPickerView: View {
	@ObservedObject var model: DesktopStageWindowPickerModel
	@State private var selectedIdentity: ExternalWindowIdentity?

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			header
			TextField("Search windows", text: $model.query)
				.textFieldStyle(.roundedBorder)
			windowList
			targetRow
			footer
		}
		.padding(16)
		.frame(minWidth: 520, minHeight: 420)
	}

	@ViewBuilder private var header: some View {
		Text("Adopt a window")
			.font(.headline)
		Text(
			"Windows hidden by Stage Manager or sitting on another Space cannot be "
				+ "dragged. Choose one here, pick the Panel it should fill, then adopt it."
		)
		.font(.caption)
		.foregroundStyle(.secondary)
		.fixedSize(horizontal: false, vertical: true)
		if !model.state.authorized {
			Text("Accessibility access is required before Teaser can adopt a window.")
				.font(.caption)
				.foregroundStyle(.orange)
		}
	}

	private var windowList: some View {
		List(model.rows, id: \.candidate.identity, selection: $selectedIdentity) { row in
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(row.primaryText).lineLimit(1)
					if let panel: String = model.panelTitle(holding: row.candidate.identity) {
						Text("In \(panel)")
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
				Text(row.secondaryText)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if let reason: String = row.candidate.rejectionReason {
					Text(reason)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
						.lineLimit(3)
				}
			}
			.opacity(row.isAdoptable ? 1 : 0.55)
			.tag(row.candidate.identity)
		}
		.frame(minHeight: 200)
	}

	private var targetRow: some View {
		HStack(spacing: 8) {
			Picker("Panel", selection: panelSelection) {
				Text("Choose a Panel").tag(PanelID?.none)
				ForEach(model.state.targets) { target in
					Text("\(target.workspaceTitle) · \(target.title)")
						.tag(PanelID?.some(target.id))
				}
			}
			.disabled(model.state.targets.isEmpty)
			Button("Refresh") { model.refresh() }
			if !model.state.stageActive {
				Button("Start Layout") { model.startStage() }
			}
		}
	}

	@ViewBuilder private var footer: some View {
		// The reason is shown before the click, not only after it: a person should
		// not have to press a control to learn why it would refuse.
		if let blocker: String = model.adoptionBlocker(for: selectedIdentity) {
			Text(blocker)
				.font(.caption)
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
		}
		HStack {
			if let message: String = model.message {
				Text(message)
					.font(.caption)
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.lineLimit(3)
			}
			Spacer()
			// Enabled whenever a window is chosen: pressing it reports the reason
			// rather than doing nothing.
			Button("Adopt Window") {
				if let selectedIdentity { model.adopt(selectedIdentity) }
			}
			.keyboardShortcut(.defaultAction)
			.disabled(selectedIdentity == nil)
		}
	}

	private var panelSelection: Binding<PanelID?> {
		.init(
			get: { model.selectedPanelID },
			set: { model.select(panelID: $0) }
		)
	}
}

/// Ordinary, opt-in window, exactly like the layout editor: never an overlay and
/// never an input shield on the desktop.
@MainActor
final class DesktopStageWindowPickerWindow {
	let window: NSWindow

	init(model: DesktopStageWindowPickerModel) {
		window = .init(
			contentRect: .init(x: 0, y: 0, width: 560, height: 520),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "Teaser — Adopt Window"
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.tabbingMode = .disallowed
		window.minSize = .init(width: 520, height: 420)
		window.contentView = NSHostingView(
			rootView: DesktopStageWindowPickerView(model: model)
		)
		window.center()
	}

	func show() {
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	func close() { window.orderOut(nil) }
}
