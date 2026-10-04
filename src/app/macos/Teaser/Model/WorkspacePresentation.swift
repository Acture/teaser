import Foundation

/// A group label. A Workspace owns no rectangle and no tree: membership lives on
/// `PanelDescriptor.workspaceID`, and placement is whichever canvas tree holds
/// the leaf. That separation is what lets one group span canvases, and lets two
/// of its Panels sit apart with another group's Panel between them.
struct WorkspaceDescriptor: Codable, Equatable, Sendable {
	let id: WorkspaceID
	var title: String
	var detail: String
}

/// One canvas's placement. `panelTree` is nil for a blank canvas: `LayoutTree`
/// has no empty case, and inventing a placeholder Panel made a blank canvas lie
/// about what it holds.
struct CanvasLayout: Codable, Equatable, Sendable {
	let displayID: DisplayID
	var panelTree: LayoutTree<PanelID>?
	/// The group this canvas is emphasising, and how far. Focus is per canvas:
	/// it never recalls a member from another canvas, and clearing it restores
	/// this canvas's tiled layout exactly, because nothing about the tree
	/// changes while it is set.
	var focus: CanvasFocus?

	init(
		displayID: DisplayID,
		panelTree: LayoutTree<PanelID>? = nil,
		focus: CanvasFocus? = nil
	) {
		self.displayID = displayID
		self.panelTree = panelTree
		self.focus = focus
	}

	/// Drops a leaf, leaving the canvas blank when it was the last one.
	/// `LayoutTree.remove` refuses that case, which is exactly what happens to a
	/// canvas holding its first Panel.
	mutating func removeLeaf(_ panelID: PanelID) throws {
		guard let tree: LayoutTree<PanelID> = panelTree else {
			throw WorkspacePresentationError.panelNotFound(panelID)
		}
		if case .leaf(let only) = tree {
			guard only == panelID else {
				throw WorkspacePresentationError.panelNotFound(panelID)
			}
			panelTree = nil
			return
		}
		var next: LayoutTree<PanelID> = tree
		try next.remove(panelID)
		panelTree = next
	}
}

/// Two stages, because Teaser cannot lower another application's window: the
/// Accessibility API offers raise and minimize, and nothing in between. The
/// first stage grows the group and raises it; the second gets the rest out of
/// the way the only way macOS allows.
enum CanvasFocus: Codable, Equatable, Sendable {
	/// Weighted larger and raised. Every other Panel stays framed and usable.
	case emphasised(WorkspaceID)
	/// The group takes the canvas, and the other Panels' adopted windows are
	/// minimized. Their Panels keep identity, bindings and tree position.
	case exclusive(WorkspaceID)

	var workspaceID: WorkspaceID {
		switch self {
		case .emphasised(let id), .exclusive(let id): return id
		}
	}

	var isExclusive: Bool {
		if case .exclusive = self { return true }
		return false
	}
}

struct VirtualFocusState: Codable, Equatable, Sendable {
	var panelID: PanelID?

	static let none: VirtualFocusState = .init(panelID: nil)
}

enum WorkspacePresentationError: Error, Equatable, LocalizedError, Sendable {
	case duplicatePanel(PanelID)
	case panelNotFound(PanelID)
	case canvasNotFound(DisplayID)
	case workspaceNotFound(WorkspaceID)

	var errorDescription: String? {
		switch self {
		case .duplicatePanel(let panelID):
			return "Panel \(panelID.rawValue) already exists in this presentation."
		case .panelNotFound(let panelID):
			return "Panel \(panelID.rawValue) is not placed on any canvas."
		case .canvasNotFound(let displayID):
			return "Canvas \(displayID.rawValue) is not open."
		case .workspaceNotFound(let workspaceID):
			return "Workspace \(workspaceID.rawValue) is not in this presentation."
		}
	}
}

/// One flat Panel tree per canvas. There is no Workspace level in the layout: a
/// Workspace is a label on its Panels, drawn as a contour around whichever of
/// them happen to be adjacent.
struct WorkspacePresentation: Codable, Equatable, Sendable {
	var virtualFocus: VirtualFocusState
	var canvases: [DisplayID: CanvasLayout]
	/// Group labels only. A group whose members all sit on closed canvases is
	/// legal and keeps its entry.
	var workspaces: [WorkspaceID: WorkspaceDescriptor]
	/// Every Panel once, independent of which canvas shows it.
	var panels: [PanelID: PanelDescriptor]
	var panelKinds: PanelKindRegistry

	init(
		virtualFocus: VirtualFocusState = .none,
		canvases: [DisplayID: CanvasLayout] = [:],
		workspaces: [WorkspaceID: WorkspaceDescriptor] = [:],
		panels: [PanelID: PanelDescriptor] = [:],
		panelKinds: PanelKindRegistry
	) {
		self.virtualFocus = virtualFocus
		self.canvases = canvases
		self.workspaces = workspaces
		self.panels = panels
		self.panelKinds = panelKinds
	}

	// MARK: - Queries

	func workspaceID(of panelID: PanelID) -> WorkspaceID? {
		panels[panelID]?.workspaceID
	}

	func canvasID(containing panelID: PanelID) -> DisplayID? {
		canvases.values
			.filter { $0.panelTree?.contains(panelID) == true }
			.map(\.displayID)
			.min { $0.rawValue < $1.rawValue }
	}

	/// In tree order, so a caller that walks Panels walks them the way they are
	/// laid out rather than in dictionary order.
	func panelIDs(onCanvas canvasID: DisplayID) -> [PanelID] {
		canvases[canvasID]?.panelTree?.leaves ?? []
	}

	/// The groups with at least one Panel on this canvas, first appearance
	/// first, so cycling through them follows the layout rather than an ID sort.
	func workspaceOrder(onCanvas canvasID: DisplayID) -> [WorkspaceID] {
		var seen: Set<WorkspaceID> = []
		var order: [WorkspaceID] = []
		for panelID: PanelID in panelIDs(onCanvas: canvasID) {
			guard let workspaceID: WorkspaceID = panels[panelID]?.workspaceID,
				seen.insert(workspaceID).inserted
			else { continue }
			order.append(workspaceID)
		}
		return order
	}

	/// Every placed Panel with its group, which is all the contour pass needs.
	func contourInputs(frames: [PanelID: LayoutRect]) -> [ContourInput] {
		canvases.keys
			.sorted { $0.rawValue < $1.rawValue }
			.flatMap { canvasID in
				panelIDs(onCanvas: canvasID).compactMap { panelID in
					guard let panel: PanelDescriptor = panels[panelID],
						let frame: LayoutRect = frames[panelID]
					else { return nil }
					return ContourInput(
						panelID: panelID,
						workspaceID: panel.workspaceID,
						displayID: canvasID,
						frame: frame
					)
				}
			}
	}

	// MARK: - Focus

	mutating func setVirtualFocus(_ panelID: PanelID?) throws {
		if let panelID, panels[panelID] == nil {
			throw WorkspacePresentationError.panelNotFound(panelID)
		}
		virtualFocus = .init(panelID: panelID)
	}

	/// Emphasises a group on one canvas. Returns false, changing nothing, when
	/// that canvas holds no member: a canvas can only focus what it already has,
	/// which is what stops focus from recalling members placed elsewhere.
	@discardableResult
	mutating func focusWorkspace(
		_ workspaceID: WorkspaceID,
		onCanvas canvasID: DisplayID,
		exclusive: Bool = false
	) -> Bool {
		guard var canvas: CanvasLayout = canvases[canvasID],
			panelIDs(onCanvas: canvasID).contains(where: {
				panels[$0]?.workspaceID == workspaceID
			})
		else { return false }
		canvas.focus = exclusive ? .exclusive(workspaceID) : .emphasised(workspaceID)
		canvases[canvasID] = canvas
		return true
	}

	mutating func clearFocus(onCanvas canvasID: DisplayID) {
		canvases[canvasID]?.focus = nil
	}

	/// Drops a canvas's focus once the group it emphasises has no Panel left
	/// there. An exclusive focus on an absent group prunes the solve to nothing
	/// and the canvas renders empty, so every edit that can move or remove the
	/// last member ends here.
	private mutating func clearFocusIfGroupAbsent(onCanvas canvasID: DisplayID) {
		guard let focus: CanvasFocus = canvases[canvasID]?.focus else { return }
		let stillHere: Bool = panelIDs(onCanvas: canvasID).contains {
			panels[$0]?.workspaceID == focus.workspaceID
		}
		if !stillHere { canvases[canvasID]?.focus = nil }
	}

	// MARK: - Edits

	/// The first Panel on a blank canvas. Splitting needs something to split.
	mutating func seedPanel(
		_ panel: PanelDescriptor,
		onCanvas canvasID: DisplayID
	) throws {
		guard var canvas: CanvasLayout = canvases[canvasID] else {
			throw WorkspacePresentationError.canvasNotFound(canvasID)
		}
		guard panels[panel.id] == nil, canvas.panelTree == nil else {
			throw WorkspacePresentationError.duplicatePanel(panel.id)
		}
		canvas.panelTree = .leaf(panel.id)
		canvases[canvasID] = canvas
		panels[panel.id] = panel
	}

	mutating func insertPanel(
		_ panel: PanelDescriptor,
		onCanvas canvasID: DisplayID,
		at edge: LayoutEdge,
		of targetPanelID: PanelID,
		splitID: LayoutSplitID,
		preference: SplitPreference = .derived
	) throws {
		guard var canvas: CanvasLayout = canvases[canvasID] else {
			throw WorkspacePresentationError.canvasNotFound(canvasID)
		}
		guard panels[panel.id] == nil else {
			throw WorkspacePresentationError.duplicatePanel(panel.id)
		}
		guard var tree: LayoutTree<PanelID> = canvas.panelTree,
			tree.contains(targetPanelID)
		else {
			throw WorkspacePresentationError.panelNotFound(targetPanelID)
		}
		try tree.insert(
			panel.id,
			at: edge,
			of: targetPanelID,
			splitID: splitID,
			preference: preference
		)
		canvas.panelTree = tree
		canvases[canvasID] = canvas
		panels[panel.id] = panel
	}

	mutating func splitPanel(
		_ targetPanelID: PanelID,
		with panel: PanelDescriptor,
		onCanvas canvasID: DisplayID,
		targetFrame: LayoutRect,
		forcedAxis: LayoutAxis? = nil,
		splitID: LayoutSplitID
	) throws {
		guard var canvas: CanvasLayout = canvases[canvasID] else {
			throw WorkspacePresentationError.canvasNotFound(canvasID)
		}
		guard panels[panel.id] == nil else {
			throw WorkspacePresentationError.duplicatePanel(panel.id)
		}
		guard var tree: LayoutTree<PanelID> = canvas.panelTree,
			tree.contains(targetPanelID)
		else {
			throw WorkspacePresentationError.panelNotFound(targetPanelID)
		}
		try tree.split(
			targetPanelID,
			with: panel.id,
			inside: targetFrame,
			forcedAxis: forcedAxis,
			splitID: splitID
		)
		canvas.panelTree = tree
		canvases[canvasID] = canvas
		panels[panel.id] = panel
	}

	/// Placement only. The Panel's `workspaceID` is untouched, so moving a Panel
	/// to another canvas is never a regroup — changing membership is a separate,
	/// explicit operation that goes to the server.
	mutating func movePanel(
		_ panelID: PanelID,
		toCanvas destinationID: DisplayID,
		at edge: LayoutEdge?,
		of targetPanelID: PanelID?,
		splitID: LayoutSplitID
	) throws {
		guard panels[panelID] != nil else {
			throw WorkspacePresentationError.panelNotFound(panelID)
		}
		guard canvases[destinationID] != nil else {
			throw WorkspacePresentationError.canvasNotFound(destinationID)
		}
		guard let sourceID: DisplayID = canvasID(containing: panelID) else {
			throw WorkspacePresentationError.panelNotFound(panelID)
		}
		var source: CanvasLayout = canvases[sourceID] ?? .init(displayID: sourceID)
		try source.removeLeaf(panelID)
		canvases[sourceID] = source

		// Re-read rather than reuse: source and destination can be the same
		// canvas, and the removal above has to be visible to the insert below.
		guard var destination: CanvasLayout = canvases[destinationID] else {
			throw WorkspacePresentationError.canvasNotFound(destinationID)
		}
		if var tree: LayoutTree<PanelID> = destination.panelTree {
			if let edge, let targetPanelID, tree.contains(targetPanelID) {
				try tree.insert(
					panelID,
					at: edge,
					of: targetPanelID,
					splitID: splitID
				)
				destination.panelTree = tree
			} else {
				// No aimed target: join at the root rather than refuse, which is
				// what dropping onto a canvas rather than onto a Panel means.
				destination.panelTree = .split(
					id: splitID,
					axis: .horizontal,
					preference: .derived,
					first: tree,
					second: .leaf(panelID)
				)
			}
		} else {
			destination.panelTree = .leaf(panelID)
		}
		canvases[destinationID] = destination
		// Both ends: the source may have lost its focused group's last member,
		// and a same-canvas move must be judged after the reinsertion.
		clearFocusIfGroupAbsent(onCanvas: sourceID)
		clearFocusIfGroupAbsent(onCanvas: destinationID)
	}

	/// Removes a Panel from the presentation entirely. One placed on no canvas
	/// is still dropped from `panels`, so a deletion cannot leave a ghost.
	mutating func removePanel(_ panelID: PanelID) throws {
		guard panels[panelID] != nil else {
			throw WorkspacePresentationError.panelNotFound(panelID)
		}
		if let canvasID: DisplayID = canvasID(containing: panelID) {
			var canvas: CanvasLayout = canvases[canvasID] ?? .init(displayID: canvasID)
			try canvas.removeLeaf(panelID)
			canvases[canvasID] = canvas
		}
		panels.removeValue(forKey: panelID)
		if virtualFocus.panelID == panelID { virtualFocus = .none }
		for canvasID: DisplayID in canvases.keys {
			clearFocusIfGroupAbsent(onCanvas: canvasID)
		}
	}

	mutating func setUserRatio(
		_ ratio: Double,
		for splitID: LayoutSplitID,
		onCanvas canvasID: DisplayID
	) throws {
		guard var canvas: CanvasLayout = canvases[canvasID],
			var tree: LayoutTree<PanelID> = canvas.panelTree
		else {
			throw WorkspacePresentationError.canvasNotFound(canvasID)
		}
		try tree.setUserRatio(ratio, for: splitID)
		canvas.panelTree = tree
		canvases[canvasID] = canvas
	}

	mutating func clearUserRatio(
		for splitID: LayoutSplitID,
		onCanvas canvasID: DisplayID
	) throws {
		guard var canvas: CanvasLayout = canvases[canvasID],
			var tree: LayoutTree<PanelID> = canvas.panelTree
		else {
			throw WorkspacePresentationError.canvasNotFound(canvasID)
		}
		try tree.clearUserRatio(for: splitID)
		canvas.panelTree = tree
		canvases[canvasID] = canvas
	}
}
