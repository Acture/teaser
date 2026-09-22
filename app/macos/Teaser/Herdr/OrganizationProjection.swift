import Foundation

/// Where the client shows Workspaces. The server model carries no canvas, so the
/// projection is told which canvases are open, which canvas each Workspace
/// already has, and which canvas receives a Workspace that has none yet.
struct WorkspacePlacement: Equatable, Sendable {
	/// The open canvases, in host order. A Workspace placed on any other canvas
	/// is hidden rather than moved, which is what keeps closing one canvas from
	/// redistributing its Workspaces onto another.
	var openDisplays: [DisplayID]
	/// Every Workspace the server still has that the client has placed, including
	/// those on canvases that are closed right now.
	var assignments: [WorkspaceID: DisplayID]
	/// The canvas the person last used, or nil while no canvas is open: then a
	/// Workspace with no placement stays unplaced until a canvas opens.
	var targetDisplay: DisplayID?

	init(openDisplays: [DisplayID], assignments: [WorkspaceID: DisplayID] = [:], targetDisplay: DisplayID?) {
		self.openDisplays = openDisplays
		self.assignments = assignments
		self.targetDisplay = targetDisplay
	}
}

enum OrganizationProjection {
	/// Projects the server organization onto the open canvases and returns the
	/// placement to remember. Placement is client-owned: the server is never told
	/// where a Workspace is shown, and nothing here mutates the snapshot.
	static func project(_ snapshot: OrganizationSnapshot, previous: WorkspacePresentation?,
		placement: WorkspacePlacement) throws -> (presentation: WorkspacePresentation, assignments: [WorkspaceID: DisplayID]) {
		try snapshot.validate()
		let open: Set<DisplayID> = .init(placement.openDisplays)
		guard open.count == placement.openDisplays.count else {
			throw HerdrError.invalid("The same canvas was offered twice as a display")
		}
		if let target: DisplayID = placement.targetDisplay, !open.contains(target) {
			throw HerdrError.invalid("New Workspaces target a canvas that is not open")
		}
		var registry: PanelKindRegistry = try .init()
		// Only Workspaces the server still has keep a placement, so a deleted
		// Workspace cannot reclaim a canvas if its ID ever returns.
		var assignments: [WorkspaceID: DisplayID] = [:]
		var workspaces: [WorkspaceID: WorkspaceDescriptor] = [:]
		for source: OrganizationWorkspace in snapshot.workspaces {
			let workspaceID: WorkspaceID = .init(source.id)
			// A Workspace keeps the canvas it already has; only one that was never
			// placed follows the target. Keeping the entry while its canvas is shut
			// is what lets Reopen Canvas restore exactly what that canvas held.
			let displayID: DisplayID? = placement.assignments[workspaceID] ?? placement.targetDisplay
			if let displayID { assignments[workspaceID] = displayID }
			let members: [OrganizationPanel] = snapshot.panels.filter { $0.workspace_id == source.id }
			var panels: [PanelID: PanelDescriptor] = [:]
			for panel: OrganizationPanel in members {
				let kindID: PanelKindID = .init(panel.kind)
				let profile: LayoutProfile = try panel.size_profile.native()
				if registry.definition(for: kindID) == nil {
					try registry.register(.init(id: kindID, displayName: panel.kind, defaultProfile: profile))
				}
				panels[.init(panel.id)] = .init(id: .init(panel.id), title: panel.title, kindID: kindID,
					providerHint: .init(displayName: panel.binding.description, bundleIdentifier: panel.binding.bundle_id, context: nil),
					profileOverride: profile, nativeContent: panel.binding.type == .notes ? .notes : .none)
			}
			// A Workspace whose canvas is shut leaves the presentation the way an
			// empty one does, so the solver never sees an unplaced Workspace. The
			// existing tiler requires nonempty trees; empty Workspaces remain in the
			// server model and organization editor, without invented Panels.
			guard let displayID, open.contains(displayID),
				let tree: LayoutTree<PanelID> = reconcile(previous?.workspaces[workspaceID]?.panelTree,
					leaves: members.map { PanelID($0.id) }) else { continue }
			workspaces[workspaceID] = .init(id: workspaceID, title: source.name,
				detail: source.task.map { "\($0.provider):\($0.id)" } ?? "",
				displayAffinity: displayID, panelTree: tree, panels: panels)
		}
		// Each canvas reconciles against its own previous tree alone, so opening,
		// closing or regrouping on one canvas never disturbs another's layout.
		var displayLayouts: [DisplayID: DisplayWorkspaceLayout] = [:]
		for displayID: DisplayID in placement.openDisplays {
			let order: [WorkspaceID] = snapshot.workspaces.map { WorkspaceID($0.id) }
				.filter { workspaces[$0]?.displayAffinity == displayID }
			guard let tree: LayoutTree<WorkspaceID> = reconcile(previous?.displayLayouts[displayID]?.workspaceTree,
				leaves: order) else { continue }
			displayLayouts[displayID] = .init(displayID: displayID, workspaceTree: tree)
		}
		var focus: VirtualFocusState = previous?.virtualFocus ?? .none
		if let panelID: PanelID = focus.panelID {
			focus.workspaceID = workspaces.values.first { $0.panels[panelID] != nil }?.id
			if focus.workspaceID == nil { focus = .none }
		} else if let workspaceID: WorkspaceID = focus.workspaceID, workspaces[workspaceID] == nil { focus = .none }
		var mode: WorkspacePresentationMode = previous?.mode ?? .tiled
		if case .focused(let id) = mode, workspaces[id] == nil { mode = .tiled }
		return (.init(mode: mode, virtualFocus: focus, displayLayouts: displayLayouts,
			workspaces: workspaces, panelKinds: registry), assignments)
	}
	private static func reconcile<Leaf>(_ old: LayoutTree<Leaf>?, leaves: [Leaf]) -> LayoutTree<Leaf>?
	where Leaf: Codable & Hashable & Sendable {
		let allowed: Set<Leaf> = Set(leaves)
		func prune(_ tree: LayoutTree<Leaf>) -> LayoutTree<Leaf>? {
			switch tree {
			case .leaf(let id): return allowed.contains(id) ? tree : nil
			case .split(let id, let axis, let preference, let first, let second):
				let left: LayoutTree<Leaf>? = prune(first)
				let right: LayoutTree<Leaf>? = prune(second)
				if let left, let right { return .split(id: id, axis: axis, preference: preference, first: left, second: right) }
				return left ?? right
			}
		}
		var result: LayoutTree<Leaf>? = old.flatMap(prune)
		for leaf: Leaf in leaves where result?.contains(leaf) != true {
			if let existing: LayoutTree<Leaf> = result {
				result = .split(id: .init("local-\(UUID().uuidString)"), axis: .horizontal,
					preference: .derived, first: existing, second: .leaf(leaf))
			} else { result = .leaf(leaf) }
		}
		return result
	}
}

/// No organization objects are persisted here. Documents survive deletion and
/// rebinding, and are never assigned to a different connection automatically.
struct OrganizationLocalScope: Codable {
	let scope: UUID
	let endpoint: String
	var documents: OrganizationNotes = .init()
	var dividerRatios: [String: Double] = [:]
	var focusedPanel: String?
	var panelFrames: [String: LayoutRect] = [:]

	mutating func capture(presentation: WorkspacePresentation, layout: PresentationLayout?) {
		focusedPanel = presentation.virtualFocus.panelID?.rawValue
		panelFrames = Dictionary(uniqueKeysWithValues: (layout?.panelFrames ?? [:]).map { ($0.key.rawValue, $0.value) })
		func collect<Leaf>(_ tree: LayoutTree<Leaf>) where Leaf: Codable & Hashable & Sendable {
			if case .split(let id, _, let preference, let first, let second) = tree {
				if let userRatio: Double = preference.userRatio { dividerRatios[id.rawValue] = userRatio }
				collect(first); collect(second)
			}
		}
		for workspace: WorkspaceDescriptor in presentation.workspaces.values { collect(workspace.panelTree) }
		for display: DisplayWorkspaceLayout in presentation.displayLayouts.values { collect(display.workspaceTree) }
	}
	func save(in directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let encoder: JSONEncoder = .init(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let url: URL = directory.appendingPathComponent("\(scope.uuidString).json")
		try encoder.encode(self).write(to: url, options: .atomic)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
	}
}
