import Foundation

// Immutable per-canvas overlay input. These values carry no window, view, or
// AppKit state, so the orchestration that produces them stays testable without a
// desktop.

/// What a Panel is bound to right now: the three states the canvas can tell
/// apart today. `CONTEXT.md`'s Panel binding also names a session and a
/// task/file reference, which nothing on `PanelDescriptor` records yet.
/// Neither a drawn outline nor a contour colour can say which of these it is,
/// so the canvas carries it as its own field rather than leaving it inferred.
enum PanelBindingState: Equatable, Sendable {
	/// Placed, with no content behind it. A canvas seeds one of these so there
	/// is something to drag a window into.
	case empty
	/// One exact provider window, held by a live lease. Read from the
	/// assignment, never guessed from geometry.
	case adoptedWindow
	/// Teaser-owned Notes, drawn inside the canvas.
	case teaserNotes
}

/// Where a canvas is, as far as anything reading the tree is concerned. A
/// group can continue on another canvas, and "fragment 1 of 2" is a dangling
/// reference unless the tree says where the other one is.
struct CanvasPlacement: Equatable, Sendable {
	let displayID: DisplayID
	/// The canvas window's own title, which is the string the Window menu
	/// lists, so the two surfaces name the same canvas the same way.
	let title: String
	/// Read live rather than from the Space recorded when the canvas opened: a
	/// canvas can be moved afterwards, and a stale answer would send someone
	/// looking on the wrong Space.
	let isOnActiveSpace: Bool
}

/// Which fragment of its group a Panel sits in. 1-based and group-wide across
/// every canvas, so a group split in two reads 1 of 2 here and 2 of 2 there.
struct WorkspaceFragmentPosition: Equatable, Sendable {
	let ordinal: Int
	let total: Int
	/// The other canvases this group continues on, in canvas order. Empty when
	/// every fragment is on this canvas — a group interrupted by another
	/// group's Panel is still two fragments, and both of them are here — and
	/// empty for a canvas whose placement nothing knows, which is said by
	/// omission rather than guessed at.
	let otherCanvases: [CanvasPlacement]
}

struct DesktopOverlayPanel: Equatable, Identifiable, Sendable {
	let id: PanelID
	/// Which group this Panel belongs to. It is carried per Panel rather than
	/// per rectangle because a Workspace has no rectangle: its outline is
	/// derived from whichever of its Panels happen to be adjacent.
	let workspaceID: WorkspaceID
	/// The group's label, carried beside its ID because a contour colour and a
	/// raw identifier are both unreadable aloud.
	let workspaceTitle: String
	let title: String
	let kindID: PanelKindID
	let frame: LayoutRect
	/// Nil when the group has a single fragment: "1 of 1" says nothing, and it
	/// would say it on every Panel of an ordinary canvas.
	let fragment: WorkspaceFragmentPosition?
	let binding: PanelBindingState
	/// The minimum this Panel asks for, when the canvas could not give it that
	/// much. It comes from the Panel's own profile override where it has one and
	/// from its kind otherwise, so it is not a kind-wide number. Mirrors
	/// `LayoutQuality.shortfalls`, which records the required minimum rather than
	/// the deficit; the deficit is this minus `frame.size`.
	let minimumSize: LayoutSize?

	init(
		id: PanelID,
		workspaceID: WorkspaceID,
		workspaceTitle: String? = nil,
		title: String,
		kindID: PanelKindID,
		frame: LayoutRect,
		fragment: WorkspaceFragmentPosition? = nil,
		binding: PanelBindingState = .empty,
		minimumSize: LayoutSize? = nil
	) {
		self.id = id
		self.workspaceID = workspaceID
		self.workspaceTitle = workspaceTitle ?? workspaceID.rawValue
		self.title = title
		self.kindID = kindID
		self.frame = frame
		self.fragment = fragment
		self.binding = binding
		self.minimumSize = minimumSize
	}
}

/// One fragment of one group on this canvas, with the colour that identifies
/// the group everywhere it appears.
struct DesktopOverlayContour: Equatable, Sendable {
	let workspaceID: WorkspaceID
	let color: WorkspaceContourColor
	let fragment: WorkspaceContourFragment
}

/// The group a canvas is emphasising and how far, carrying the group's label:
/// `CanvasFocus` holds an ID, and anything that reads the canvas aloud needs
/// the name.
struct DesktopOverlayCanvasFocus: Equatable, Sendable {
	let workspaceID: WorkspaceID
	let title: String
	let isExclusive: Bool
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
	let focus: DesktopOverlayCanvasFocus?
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
		focus: DesktopOverlayCanvasFocus? = nil,
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
		self.focus = focus
		self.arrangeMode = arrangeMode
		self.dragActive = dragActive
		self.dropHighlight = dropHighlight
		self.status = status
	}

	/// How many distinct groups have a Panel on this canvas.
	private static func groupCount(
		on displayID: DisplayID,
		in presentation: WorkspacePresentation
	) -> Int {
		Set(
			presentation.panelIDs(onCanvas: displayID)
				.compactMap { presentation.workspaceID(of: $0) }
		).count
	}

	/// Where each Panel sits in its group's run of fragments. Read from
	/// `PresentationLayout.contours`, which covers every canvas, rather than
	/// from `contours` below: that field drops a lone group's outline because
	/// there is nothing to tell it apart from, and a Panel's fragment is still
	/// worth naming when its group continues on another canvas.
	///
	/// Groups with one fragment are omitted rather than numbered 1 of 1, and a
	/// Panel the pass dropped — a degenerate rectangle never reaches the grid —
	/// simply has no entry.
	private static func fragmentPositions(
		in layout: PresentationLayout,
		on displayID: DisplayID,
		canvases: [DisplayID: CanvasPlacement]
	) -> [PanelID: WorkspaceFragmentPosition] {
		var positions: [PanelID: WorkspaceFragmentPosition] = [:]
		for contour: WorkspaceContour in layout.contours
			where contour.fragments.count > 1
		{
			// Fragments arrive in canvas order, so the first appearance of each
			// other canvas keeps that order. A fragment on this canvas is not
			// somewhere else, and a canvas with no placement is left unsaid.
			var elsewhere: [CanvasPlacement] = []
			for fragmentDisplayID: DisplayID in contour.fragments.map(\.displayID)
			where fragmentDisplayID != displayID {
				guard let placement: CanvasPlacement = canvases[fragmentDisplayID],
					!elsewhere.contains(where: { $0.displayID == fragmentDisplayID })
				else { continue }
				elsewhere.append(placement)
			}
			for fragment: WorkspaceContourFragment in contour.fragments {
				for panelID: PanelID in fragment.panelIDs {
					positions[panelID] = .init(
						ordinal: fragment.ordinal,
						total: contour.fragments.count,
						otherCanvases: elsewhere
					)
				}
			}
		}
		return positions
	}

	/// `adoptedPanelIDs` is the set of Panels holding a live window lease. It
	/// arrives from the orchestrator rather than from `layout`, because a lease
	/// is runtime state and `PresentationLayout` is pure geometry — and because
	/// adoption must never be inferred from a rectangle.
	init(
		displayID: DisplayID,
		screenFrame: LayoutRect,
		presentation: WorkspacePresentation,
		layout: PresentationLayout,
		adoptedPanelIDs: Set<PanelID> = [],
		canvases: [DisplayID: CanvasPlacement] = [:],
		arrangeMode: Bool,
		dragActive: Bool = false,
		dropHighlight: DesktopOverlayDropHighlight? = nil,
		status: String? = nil
	) {
		let fragments: [PanelID: WorkspaceFragmentPosition] = Self.fragmentPositions(
			in: layout,
			on: displayID,
			canvases: canvases
		)
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
					// A group can have members without ever having been given a
					// label, so the ID is the honest fallback.
					workspaceTitle: presentation.workspaces[panel.workspaceID]?.title,
					title: panel.providerHint.map { "\($0.displayName) · \(panel.title)" }
						?? panel.title,
					kindID: panel.kindID,
					frame: frame,
					fragment: fragments[panelID],
					binding: panel.nativeContent == .notes
						? .teaserNotes
						: (adoptedPanelIDs.contains(panelID) ? .adoptedWindow : .empty),
					minimumSize: layout.quality.shortfalls[panelID]
				)
			},
			// A contour exists to tell one group from another. On a canvas showing
			// a single group there is nothing to tell apart, so outlining
			// everything would be decoration that says nothing.
			contours: Self.groupCount(on: displayID, in: presentation) < 2
				? []
				: layout.contours.flatMap { contour in
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
			focus: presentation.canvases[displayID]?.focus.map { focus in
				.init(
					workspaceID: focus.workspaceID,
					title: presentation.workspaces[focus.workspaceID]?.title
						?? focus.workspaceID.rawValue,
					isExclusive: focus.isExclusive
				)
			},
			arrangeMode: arrangeMode,
			dragActive: dragActive,
			dropHighlight: dropHighlight,
			status: status
		)
	}
}
