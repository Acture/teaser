import Foundation

enum OrganizationProjection {
	static func project(_ snapshot: OrganizationSnapshot, previous: WorkspacePresentation?, displayID: DisplayID) throws -> WorkspacePresentation {
		try snapshot.validate()
		var registry: PanelKindRegistry = try .init()
		var workspaces: [WorkspaceID: WorkspaceDescriptor] = [:]
		for source: OrganizationWorkspace in snapshot.workspaces {
			let workspaceID: WorkspaceID = .init(source.id)
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
			// The existing tiler requires nonempty trees; empty Workspaces remain in
			// the server model and organization editor, without invented Panels.
			guard let tree: LayoutTree<PanelID> = reconcile(previous?.workspaces[workspaceID]?.panelTree,
				leaves: members.map { PanelID($0.id) }) else { continue }
			workspaces[workspaceID] = .init(id: workspaceID, title: source.name,
				detail: source.task.map { "\($0.provider):\($0.id)" } ?? "",
				displayAffinity: displayID, panelTree: tree, panels: panels)
		}
		let order: [WorkspaceID] = snapshot.workspaces.map { WorkspaceID($0.id) }.filter { workspaces[$0] != nil }
		let tree: LayoutTree<WorkspaceID>? = reconcile(previous?.displayLayouts[displayID]?.workspaceTree, leaves: order)
		var focus: VirtualFocusState = previous?.virtualFocus ?? .none
		if let panelID: PanelID = focus.panelID {
			focus.workspaceID = workspaces.values.first { $0.panels[panelID] != nil }?.id
			if focus.workspaceID == nil { focus = .none }
		} else if let workspaceID: WorkspaceID = focus.workspaceID, workspaces[workspaceID] == nil { focus = .none }
		var mode: WorkspacePresentationMode = previous?.mode ?? .tiled
		if case .focused(let id) = mode, workspaces[id] == nil { mode = .tiled }
		return .init(mode: mode, virtualFocus: focus,
			displayLayouts: tree.map { [displayID: .init(displayID: displayID, workspaceTree: $0)] } ?? [:],
			workspaces: workspaces, panelKinds: registry)
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
					preference: .init(desiredRatio: 0.5), first: existing, second: .leaf(leaf))
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
				dividerRatios[id.rawValue] = preference.desiredRatio
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
