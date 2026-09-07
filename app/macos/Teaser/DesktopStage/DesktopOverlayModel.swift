import Foundation

// Immutable per-display overlay input. These values carry no window, view, or
// AppKit state, so the orchestration that produces them stays testable without a
// desktop.

struct DesktopOverlayWorkspace: Equatable, Identifiable, Sendable {
	let id: WorkspaceID
	let title: String
	let frame: LayoutRect
}

struct DesktopOverlayPanel: Equatable, Identifiable, Sendable {
	let id: PanelID
	let workspaceID: WorkspaceID
	let title: String
	let kindID: PanelKindID
	let frame: LayoutRect
}

struct DesktopOverlayDropHighlight: Equatable, Sendable {
	let workspaceID: WorkspaceID
	let panelID: PanelID
	let edge: LayoutEdge?
	let frame: LayoutRect
	let label: String?

	init(
		workspaceID: WorkspaceID,
		panelID: PanelID,
		edge: LayoutEdge? = nil,
		frame: LayoutRect,
		label: String? = nil
	) {
		self.workspaceID = workspaceID
		self.panelID = panelID
		self.edge = edge
		self.frame = frame
		self.label = label
	}
}

struct DesktopOverlaySnapshot: Equatable, Sendable {
	let displayID: DisplayID
	let screenFrame: LayoutRect
	let workspaces: [DesktopOverlayWorkspace]
	let panels: [DesktopOverlayPanel]
	let dividers: [LayoutDivider]
	let virtualFocus: VirtualFocusState
	let arrangeMode: Bool
	let dragActive: Bool
	let dropHighlight: DesktopOverlayDropHighlight?
	let status: String?

	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		workspaces: [DesktopOverlayWorkspace],
		panels: [DesktopOverlayPanel],
		dividers: [LayoutDivider],
		virtualFocus: VirtualFocusState,
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		self.displayID = displayID
		self.screenFrame = screenFrame
		self.workspaces = workspaces
		self.panels = panels
		self.dividers = dividers
		self.virtualFocus = virtualFocus
		self.arrangeMode = arrangeMode
		self.dragActive = dragActive
		self.dropHighlight = dropHighlight
		self.status = status
	}

	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		presentation: WorkspacePresentation,
		layout: PresentationLayout,
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		let displayWorkspaces: [WorkspaceDescriptor] = presentation.workspaces
			.values
			.filter {
				$0.displayAffinity == displayID
					&& layout.workspaceFrames[$0.id] != nil
			}
			.sorted { $0.id.rawValue < $1.id.rawValue }
		let workspaceIDs: Set<WorkspaceID> = .init(
			displayWorkspaces.map(\.id)
		)

		self.init(
			displayID: displayID,
			screenFrame: screenFrame,
			workspaces: displayWorkspaces.compactMap { workspace in
				guard let frame: LayoutRect = layout.workspaceFrames[workspace.id]
				else {
					return nil
				}
				return .init(
					id: workspace.id,
					title: workspace.title,
					frame: frame
				)
			},
			panels: displayWorkspaces.flatMap { workspace in
				workspace.panels.values
					.compactMap { panel in
						guard let frame: LayoutRect = layout.panelFrames[panel.id]
						else {
							return nil
						}
						return .init(
							id: panel.id,
							workspaceID: workspace.id,
							title: panel.providerHint.map { "\($0.displayName) · \(panel.title)" } ?? panel.title,
							kindID: panel.kindID,
							frame: frame
						)
					}
					.sorted { $0.id.rawValue < $1.id.rawValue }
			},
			dividers: layout.dividers.filter { divider in
				switch divider.scope {
				case .display(let dividerDisplayID):
					return dividerDisplayID == displayID
				case .workspace(let workspaceID):
					return workspaceIDs.contains(workspaceID)
				}
			},
			virtualFocus: presentation.virtualFocus,
			arrangeMode: arrangeMode,
			dragActive: dragActive,
			dropHighlight: dropHighlight,
			status: status
		)
	}
}
