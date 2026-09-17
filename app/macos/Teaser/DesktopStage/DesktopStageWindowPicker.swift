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

	init(
		onList: @escaping @MainActor () -> [ExternalWindowCandidate],
		onAdopt: @escaping @MainActor (ExternalWindowIdentity, PanelID) -> Bool
	) {
		self.onList = onList
		self.onAdopt = onAdopt
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
		let adopted: Bool = onAdopt(identity, panelID)
		// The orchestrator owns the reason; repeating it here would be a second
		// copy that drifts, so the picker points at the status it already set.
		message = adopted ? nil : state.statusMessage
		revision &+= 1
		return adopted
	}
}
