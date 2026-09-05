import Foundation

struct WorkspaceDescriptor: Codable, Equatable, Sendable {
	let id: WorkspaceID
	var title: String
	var detail: String
	var displayAffinity: DisplayID
	var panelTree: LayoutTree<PanelID>
	var panels: [PanelID: PanelDescriptor]
}

struct DisplayWorkspaceLayout: Codable, Equatable, Sendable {
	let displayID: DisplayID
	var workspaceTree: LayoutTree<WorkspaceID>
}

enum WorkspacePresentationMode: Codable, Equatable, Sendable {
	case tiled
	case focused(WorkspaceID)
}

struct VirtualFocusState: Codable, Equatable, Sendable {
	var workspaceID: WorkspaceID?
	var panelID: PanelID?

	static let none: VirtualFocusState = .init(
		workspaceID: nil,
		panelID: nil
	)
}

enum LayoutScope: Codable, Equatable, Hashable, Sendable {
	case display(DisplayID)
	case workspace(WorkspaceID)
}

enum WorkspacePresentationError: Error, Equatable, Sendable {
	case duplicatePanel(PanelID)
	case panelNotFound(PanelID)
	case workspaceNotFound(WorkspaceID)
	case displayNotFound(DisplayID)
	case focusPanelOutsideWorkspace
}

struct WorkspacePresentation: Codable, Equatable, Sendable {
	var mode: WorkspacePresentationMode
	var virtualFocus: VirtualFocusState
	var displayLayouts: [DisplayID: DisplayWorkspaceLayout]
	var workspaces: [WorkspaceID: WorkspaceDescriptor]
	var panelKinds: PanelKindRegistry

	mutating func setVirtualFocus(
		workspaceID: WorkspaceID,
		panelID: PanelID?
	) throws {
		guard let workspace: WorkspaceDescriptor = workspaces[workspaceID] else {
			throw WorkspacePresentationError.workspaceNotFound(workspaceID)
		}
		if let panelID, workspace.panels[panelID] == nil {
			throw WorkspacePresentationError.focusPanelOutsideWorkspace
		}
		virtualFocus = .init(workspaceID: workspaceID, panelID: panelID)
	}

	mutating func focusWorkspace(_ workspaceID: WorkspaceID) throws {
		guard workspaces[workspaceID] != nil else {
			throw WorkspacePresentationError.workspaceNotFound(workspaceID)
		}
		mode = .focused(workspaceID)
	}

	mutating func showTiled() {
		mode = .tiled
	}

	mutating func insertPanel(
		_ panel: PanelDescriptor,
		in workspaceID: WorkspaceID,
		at edge: LayoutEdge,
		of targetPanelID: PanelID,
		splitID: LayoutSplitID,
		desiredRatio: Double = 0.5
	) throws {
		guard !workspaces.values.contains(where: { $0.panels[panel.id] != nil }) else {
			throw WorkspacePresentationError.duplicatePanel(panel.id)
		}
		guard var workspace: WorkspaceDescriptor = workspaces[workspaceID] else {
			throw WorkspacePresentationError.workspaceNotFound(workspaceID)
		}
		guard workspace.panels[targetPanelID] != nil else {
			throw WorkspacePresentationError.panelNotFound(targetPanelID)
		}
		try workspace.panelTree.insert(
			panel.id,
			at: edge,
			of: targetPanelID,
			splitID: splitID,
			desiredRatio: desiredRatio
		)
		workspace.panels[panel.id] = panel
		workspaces[workspaceID] = workspace
	}

	mutating func splitPanel(
		_ targetPanelID: PanelID,
		with panel: PanelDescriptor,
		in workspaceID: WorkspaceID,
		targetFrame: LayoutRect,
		forcedAxis: LayoutAxis? = nil,
		splitID: LayoutSplitID
	) throws {
		guard !workspaces.values.contains(where: { $0.panels[panel.id] != nil }) else {
			throw WorkspacePresentationError.duplicatePanel(panel.id)
		}
		guard var workspace: WorkspaceDescriptor = workspaces[workspaceID] else {
			throw WorkspacePresentationError.workspaceNotFound(workspaceID)
		}
		guard workspace.panels[targetPanelID] != nil else {
			throw WorkspacePresentationError.panelNotFound(targetPanelID)
		}
		try workspace.panelTree.split(
			targetPanelID,
			with: panel.id,
			inside: targetFrame,
			forcedAxis: forcedAxis,
			splitID: splitID
		)
		workspace.panels[panel.id] = panel
		workspaces[workspaceID] = workspace
	}

	mutating func setDesiredRatio(
		_ ratio: Double,
		for splitID: LayoutSplitID,
		in scope: LayoutScope
	) throws {
		switch scope {
		case .display(let displayID):
			guard var layout: DisplayWorkspaceLayout = displayLayouts[displayID] else {
				throw WorkspacePresentationError.displayNotFound(displayID)
			}
			try layout.workspaceTree.setDesiredRatio(ratio, for: splitID)
			displayLayouts[displayID] = layout
		case .workspace(let workspaceID):
			guard var workspace: WorkspaceDescriptor = workspaces[workspaceID] else {
				throw WorkspacePresentationError.workspaceNotFound(workspaceID)
			}
			try workspace.panelTree.setDesiredRatio(ratio, for: splitID)
			workspaces[workspaceID] = workspace
		}
	}

	mutating func applyEffectiveRatios(
		_ ratios: [LayoutSplitReference: Double]
	) {
		for (reference, ratio): (LayoutSplitReference, Double) in ratios {
			switch reference.scope {
			case .display(let displayID):
				displayLayouts[displayID]?.workspaceTree.applyEffectiveRatios([
					reference.splitID: ratio,
				])
			case .workspace(let workspaceID):
				workspaces[workspaceID]?.panelTree.applyEffectiveRatios([
					reference.splitID: ratio,
				])
			}
		}
	}
}
