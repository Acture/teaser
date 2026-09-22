import Foundation

// Immutable per-canvas overlay input. These values carry no window, view, or
// AppKit state, so the orchestration that produces them stays testable without a
// desktop.

struct DesktopOverlayPanel: Equatable, Identifiable, Sendable {
	let id: PanelID
	/// Which group this Panel belongs to. It is carried per Panel rather than
	/// per rectangle because a Workspace has no rectangle: its outline is
	/// derived from whichever of its Panels happen to be adjacent.
	let workspaceID: WorkspaceID
	let title: String
	let kindID: PanelKindID
	let frame: LayoutRect
}

/// One fragment of one group on this canvas, with the colour that identifies
/// the group everywhere it appears.
struct DesktopOverlayContour: Equatable, Sendable {
	let workspaceID: WorkspaceID
	let color: WorkspaceContourColor
	let fragment: WorkspaceContourFragment
}

struct DesktopOverlayDropHighlight: Equatable, Sendable {
	let panelID: PanelID
	let edge: LayoutEdge?
	let frame: LayoutRect
	let label: String?

	init(
		panelID: PanelID,
		edge: LayoutEdge? = nil,
		frame: LayoutRect,
		label: String? = nil
	) {
		self.panelID = panelID
		self.edge = edge
		self.frame = frame
		self.label = label
	}
}

struct DesktopOverlaySnapshot: Equatable, Sendable {
	let displayID: DisplayID
	let screenFrame: LayoutRect
	let panels: [DesktopOverlayPanel]
	let contours: [DesktopOverlayContour]
	let dividers: [LayoutDivider]
	let virtualFocus: VirtualFocusState
	let arrangeMode: Bool
	let dragActive: Bool
	let dropHighlight: DesktopOverlayDropHighlight?
	let status: String?

	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		panels: [DesktopOverlayPanel],
		contours: [DesktopOverlayContour] = [],
		dividers: [LayoutDivider],
		virtualFocus: VirtualFocusState,
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		self.displayID = displayID
		self.screenFrame = screenFrame
		self.panels = panels
		self.contours = contours
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
		self.init(
			displayID: displayID,
			screenFrame: screenFrame,
			// This canvas's Panels only. Another canvas's Panels are solved into
			// that canvas's rectangle and must never be drawn here.
			panels: presentation.panelIDs(onCanvas: displayID).compactMap { panelID in
				guard let panel: PanelDescriptor = presentation.panels[panelID],
					let frame: LayoutRect = layout.panelFrames[panelID]
				else { return nil }
				return .init(
					id: panelID,
					workspaceID: panel.workspaceID,
					title: panel.providerHint.map { "\($0.displayName) · \(panel.title)" }
						?? panel.title,
					kindID: panel.kindID,
					frame: frame
				)
			},
			contours: layout.contours.flatMap { contour in
				contour.fragments
					.filter { $0.displayID == displayID }
					.map {
						DesktopOverlayContour(
							workspaceID: contour.workspaceID,
							color: layout.contourColors[contour.workspaceID]
								?? WorkspaceContourPalette.colors[0],
							fragment: $0
						)
					}
			},
			dividers: layout.dividers.filter { $0.displayID == displayID },
			virtualFocus: presentation.virtualFocus,
			arrangeMode: arrangeMode,
			dragActive: dragActive,
			dropHighlight: dropHighlight,
			status: status
		)
	}
}
