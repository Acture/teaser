import Foundation

/// Where the client shows Panels. The server model carries no canvas, so the
/// projection is told which canvases are open and which one receives a Panel
/// that has never been placed. Which canvas already holds a Panel is read from
/// the previous presentation, closed canvases included.
struct WorkspacePlacement: Equatable, Sendable {
	/// The open canvases, in host order. A Panel seated on any other canvas is
	/// hidden rather than moved, which is what keeps closing one canvas from
	/// redistributing its Panels onto another.
	var openDisplays: [DisplayID]
	/// The canvas the person last used, or nil while none is open: then a Panel
	/// with no seat stays unplaced until a canvas opens.
	var targetDisplay: DisplayID?

	init(openDisplays: [DisplayID], targetDisplay: DisplayID?) {
		self.openDisplays = openDisplays
		self.targetDisplay = targetDisplay
	}
}

enum OrganizationProjection {
	/// Projects the server organization onto the open canvases. Placement is
	/// client-owned: the server is never told where a Panel is shown, and
	/// nothing here mutates the snapshot. Membership comes from the server and
	/// is copied onto each Panel; it is never inferred from where a Panel sits.
	static func project(
		_ snapshot: OrganizationSnapshot,
		previous: WorkspacePresentation?,
		placement: WorkspacePlacement
	) throws -> WorkspacePresentation {
		try snapshot.validate()
		let open: Set<DisplayID> = .init(placement.openDisplays)
		guard open.count == placement.openDisplays.count else {
			throw HerdrError.invalid("The same canvas was offered twice as a display")
		}
		if let target: DisplayID = placement.targetDisplay, !open.contains(target) {
			throw HerdrError.invalid("New Panels target a canvas that is not open")
		}

		var registry: PanelKindRegistry = try .init()
		var workspaces: [WorkspaceID: WorkspaceDescriptor] = [:]
		for source: OrganizationWorkspace in snapshot.workspaces {
			workspaces[.init(source.id)] = .init(
				id: .init(source.id),
				title: source.name,
				detail: source.task.map { "\($0.provider):\($0.id)" } ?? ""
			)
		}

		var panels: [PanelID: PanelDescriptor] = [:]
		for panel: OrganizationPanel in snapshot.panels {
			let kindID: PanelKindID = .init(panel.kind)
			let profile: LayoutProfile = try panel.size_profile.native()
			if registry.definition(for: kindID) == nil {
				try registry.register(
					.init(id: kindID, displayName: panel.kind, defaultProfile: profile)
				)
			}
			panels[.init(panel.id)] = .init(
				id: .init(panel.id),
				title: panel.title,
				workspaceID: .init(panel.workspace_id),
				kindID: kindID,
				providerHint: .init(
					displayName: panel.binding.description,
					bundleIdentifier: panel.binding.bundle_id,
					context: nil
				),
				profileOverride: profile,
				nativeContent: panel.binding.type == .notes ? .notes : .none
			)
		}

		// Which canvas already holds each Panel. `previous` carries closed
		// canvases too, so a Panel whose canvas is shut keeps its seat there and
		// is deliberately absent from every open canvas rather than migrating.
		var seat: [PanelID: DisplayID] = [:]
		for displayID: DisplayID in (previous?.canvases.keys).map(Array.init)?
			.sorted(by: { $0.rawValue < $1.rawValue }) ?? []
		{
			for leaf: PanelID in previous?.canvases[displayID]?.panelTree?.leaves ?? []
			where panels[leaf] != nil && seat[leaf] == nil {
				seat[leaf] = displayID
			}
		}

		// Each canvas reconciles against its own previous tree alone, so opening,
		// closing or regrouping on one canvas never disturbs another's layout.
		let order: [PanelID] = snapshot.panels.map { PanelID($0.id) }
		var canvases: [DisplayID: CanvasLayout] = [:]
		for displayID: DisplayID in placement.openDisplays {
			let leaves: [PanelID] = order.filter { panelID in
				seat[panelID] == displayID
					|| (seat[panelID] == nil && placement.targetDisplay == displayID)
			}
			let previousCanvas: CanvasLayout? = previous?.canvases[displayID]
			let tree: LayoutTree<PanelID>? = reconcile(
				previousCanvas?.panelTree,
				leaves: leaves,
				panels: panels
			)
			// A focused group with no member left on this canvas stops being
			// focused: focus can only ever emphasise what the canvas holds.
			let focus: CanvasFocus? = previousCanvas?.focus.flatMap { focus in
				(tree?.leaves ?? []).contains {
					panels[$0]?.workspaceID == focus.workspaceID
				} ? focus : nil
			}
			canvases[displayID] = .init(
				displayID: displayID,
				panelTree: tree,
				focus: focus
			)
		}

		var focus: VirtualFocusState = previous?.virtualFocus ?? .none
		if let panelID: PanelID = focus.panelID,
			!canvases.values.contains(where: { $0.panelTree?.contains(panelID) == true })
		{
			focus = .none
		}

		return .init(
			virtualFocus: focus,
			canvases: canvases,
			workspaces: workspaces,
			panels: panels,
			panelKinds: registry
		)
	}

	/// Where a Panel that has never been placed should land. Next to a member of
	/// its own group when this canvas already shows one, so a group arrives
	/// together instead of being scattered by arrival order.
	///
	/// A preference, not a rule: it only ever applies to a Panel with no seat at
	/// all. Nothing here reads "these members are not adjacent" and rearranges,
	/// so a layout the person scattered on purpose survives every reprojection.
	private static func seat(
		_ panelID: PanelID,
		beside tree: LayoutTree<PanelID>,
		panels: [PanelID: PanelDescriptor],
		splitID: LayoutSplitID
	) -> LayoutTree<PanelID> {
		var next: LayoutTree<PanelID> = tree
		if let workspaceID: WorkspaceID = panels[panelID]?.workspaceID,
			let sibling: PanelID = tree.leaves.last(where: {
				panels[$0]?.workspaceID == workspaceID
			}),
			(try? next.insert(
				panelID,
				at: .trailing,
				of: sibling,
				splitID: splitID
			)) != nil
		{
			return next
		}
		// A group with no member here yet joins at the root.
		return .split(
			id: splitID,
			axis: .horizontal,
			preference: .derived,
			first: tree,
			second: .leaf(panelID)
		)
	}

	private static func reconcile(
		_ old: LayoutTree<PanelID>?,
		leaves: [PanelID],
		panels: [PanelID: PanelDescriptor]
	) -> LayoutTree<PanelID>? {
		let allowed: Set<PanelID> = .init(leaves)
		func prune(_ tree: LayoutTree<PanelID>) -> LayoutTree<PanelID>? {
			switch tree {
			case .leaf(let id): return allowed.contains(id) ? tree : nil
			case .split(let id, let axis, let preference, let first, let second):
				let left: LayoutTree<PanelID>? = prune(first)
				let right: LayoutTree<PanelID>? = prune(second)
				if let left, let right {
					return .split(
						id: id,
						axis: axis,
						preference: preference,
						first: left,
						second: right
					)
				}
				return left ?? right
			}
		}
		var result: LayoutTree<PanelID>? = old.flatMap(prune)
		for leaf: PanelID in leaves where result?.contains(leaf) != true {
			if let existing: LayoutTree<PanelID> = result {
				result = seat(
					leaf,
					beside: existing,
					panels: panels,
					splitID: .init("local-\(UUID().uuidString)")
				)
			} else {
				result = .leaf(leaf)
			}
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
		for canvas: CanvasLayout in presentation.canvases.values {
			if let tree: LayoutTree<PanelID> = canvas.panelTree { collect(tree) }
		}
	}
	func save(in directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let encoder: JSONEncoder = .init(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let url: URL = directory.appendingPathComponent("\(scope.uuidString).json")
		try encoder.encode(self).write(to: url, options: .atomic)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
	}
}
