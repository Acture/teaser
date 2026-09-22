import Foundation

enum ShowcasePreset {
	static let mainDisplayID: DisplayID = .init("main")

	static let teaserWorkspaceID: WorkspaceID = .init("teaser")
	static let researchWorkspaceID: WorkspaceID = .init("research")
	static let fochWorkspaceID: WorkspaceID = .init("foch")
	static let arkSolverWorkspaceID: WorkspaceID = .init("ark-solver")
	static let paperWorkspaceID: WorkspaceID = .init("paper")
	static let sortAndPourWorkspaceID: WorkspaceID = .init("sort-and-pour")

	static let zedPanelID: PanelID = .init("teaser-zed")
	static let linearPanelID: PanelID = .init("teaser-linear")
	static let codexPanelID: PanelID = .init("teaser-codex")
	static let notionPanelID: PanelID = .init("research-notion")
	static let notesPanelID: PanelID = .init("research-notes")
	static let claudePanelID: PanelID = .init("foch-claude")
	static let sshPanelID: PanelID = .init("ark-ssh")
	static let previewPanelID: PanelID = .init("paper-preview")
	static let chromePanelID: PanelID = .init("sort-and-pour-chrome")

	static let canvasWorkspaceID: WorkspaceID = .init("canvas")
	static let canvasPanelID: PanelID = .init("canvas-panel")

	/// The empty start: one empty Panel filling the canvas, which is the thing a
	/// window is dragged into. Every further region comes from splitting it,
	/// never from a preset, and nothing is placed until a window arrives.
	static func blankCanvas(
		displayID: DisplayID = mainDisplayID
	) -> WorkspacePresentation {
		let panel: PanelDescriptor = .init(
			id: canvasPanelID,
			title: "Empty",
			workspaceID: canvasWorkspaceID,
			kindID: .generic,
			providerHint: nil,
			profileOverride: nil,
			nativeContent: .none
		)
		return .init(
			virtualFocus: .init(panelID: canvasPanelID),
			canvases: [
				displayID: .init(
					displayID: displayID,
					panelTree: .leaf(canvasPanelID)
				),
			],
			workspaces: [
				canvasWorkspaceID: .init(
					id: canvasWorkspaceID,
					title: "Canvas",
					detail: ""
				),
			],
			panels: [canvasPanelID: panel],
			panelKinds: try! .init()
		)
	}

	/// Six groups on one canvas: a stress fixture for contours and unequal
	/// tiling, never a default the product ships with.
	static func presentation(
		displayID: DisplayID = mainDisplayID
	) -> WorkspacePresentation {
		.init(
			virtualFocus: .init(panelID: zedPanelID),
			canvases: [
				displayID: .init(displayID: displayID, panelTree: showcaseTree()),
			],
			workspaces: dictionary([
				.init(id: teaserWorkspaceID, title: "Teaser", detail: "Spatial development environment"),
				.init(id: researchWorkspaceID, title: "Research", detail: "Reading and notes"),
				.init(id: fochWorkspaceID, title: "Foch", detail: "Desktop client"),
				.init(id: arkSolverWorkspaceID, title: "Ark Solver", detail: "Search and replay"),
				.init(id: paperWorkspaceID, title: "Paper", detail: "Writing workspace"),
				.init(id: sortAndPourWorkspaceID, title: "Sort & Pour", detail: "Playable release"),
			]),
			panels: dictionary(showcasePanels()),
			panelKinds: try! .init()
		)
	}

	/// One flat tree. Each former Workspace leaf is replaced in place by that
	/// group's own Panel subtree, so every split ID and proportion is the one it
	/// always was — the groups are now expressed by the Panels' membership and
	/// drawn as contours, not by owning a rectangle.
	private static func showcaseTree() -> LayoutTree<PanelID> {
		.split(
			id: .init("workspace-root"),
			axis: .horizontal,
			preference: .user(0.62),
			first: .split(
				id: .init("workspace-left-stack"),
				axis: .vertical,
				preference: .user(0.65),
				first: .split(
					id: .init("teaser-zed-column"),
					axis: .horizontal,
					preference: .user(0.56),
					first: .leaf(zedPanelID),
					second: .split(
						id: .init("teaser-tools-stack"),
						axis: .vertical,
						preference: .user(0.47),
						first: .leaf(linearPanelID),
						second: .leaf(codexPanelID)
					)
				),
				second: .split(
					id: .init("research-panels"),
					axis: .horizontal,
					preference: .user(0.54),
					first: .leaf(notionPanelID),
					second: .leaf(notesPanelID)
				)
			),
			second: .split(
				id: .init("workspace-right-foch"),
				axis: .vertical,
				preference: .user(0.40),
				first: .leaf(claudePanelID),
				second: .split(
					id: .init("workspace-right-ark"),
					axis: .vertical,
					preference: .user(0.35),
					first: .leaf(sshPanelID),
					second: .split(
						id: .init("workspace-right-bottom"),
						axis: .horizontal,
						preference: .user(0.37),
						first: .leaf(previewPanelID),
						second: .leaf(chromePanelID)
					)
				)
			)
		)
	}

	private static func showcasePanels() -> [PanelDescriptor] {
		[
			externalPanel(
				id: zedPanelID, workspaceID: teaserWorkspaceID, title: "Editor",
				kindID: .app, provider: "Zed",
				bundleIdentifier: "dev.zed.Zed", context: "Teaser"
			),
			externalPanel(
				id: linearPanelID, workspaceID: teaserWorkspaceID, title: "Tasks",
				kindID: .task, provider: "Linear", context: "Teaser"
			),
			externalPanel(
				id: codexPanelID, workspaceID: teaserWorkspaceID,
				title: "Implementation", kindID: .agent, provider: "Ghostty",
				context: "Codex · teaser"
			),
			externalPanel(
				id: notionPanelID, workspaceID: researchWorkspaceID,
				title: "Research", kindID: .task, provider: "Notion",
				context: "Research workspace"
			),
			.init(
				id: notesPanelID,
				title: "Working notes",
				workspaceID: researchWorkspaceID,
				kindID: .notes,
				providerHint: .init(
					displayName: "Teaser",
					bundleIdentifier: nil,
					context: "Research workspace"
				),
				profileOverride: nil,
				nativeContent: .notes
			),
			externalPanel(
				id: claudePanelID, workspaceID: fochWorkspaceID, title: "Review",
				kindID: .agent, provider: "Warp", context: "Claude Code · foch"
			),
			externalPanel(
				id: sshPanelID, workspaceID: arkSolverWorkspaceID,
				title: "Replay worker", kindID: .cli, provider: "Terminal",
				bundleIdentifier: "com.apple.Terminal", context: "SSH · solver-gpu"
			),
			externalPanel(
				id: previewPanelID, workspaceID: paperWorkspaceID, title: "Draft",
				kindID: .file, provider: "Preview",
				bundleIdentifier: "com.apple.Preview", context: "paper/draft.pdf"
			),
			externalPanel(
				id: chromePanelID, workspaceID: sortAndPourWorkspaceID,
				title: "Playable", kindID: .app, provider: "Google Chrome",
				bundleIdentifier: "com.google.Chrome", context: "Sort & Pour"
			),
		]
	}

	private static func externalPanel(
		id: PanelID,
		workspaceID: WorkspaceID,
		title: String,
		kindID: PanelKindID,
		provider: String,
		bundleIdentifier: String? = nil,
		context: String? = nil
	) -> PanelDescriptor {
		let profile: LayoutProfile = PanelKindDefinition.builtIns
			.first { $0.id == kindID }!
			.defaultProfile
		return .init(
			id: id,
			title: title,
			workspaceID: workspaceID,
			kindID: kindID,
			providerHint: .init(
				displayName: provider,
				bundleIdentifier: bundleIdentifier,
				context: context
			),
			// Compact empty targets fit a laptop display. Provider geometry is
			// still checked on adoption; these are not promises about app minima.
			profileOverride: .init(
				minimumSize: .init(
					width: min(320, profile.minimumSize.width),
					height: 200
				),
				preferredAspectRatio: profile.preferredAspectRatio,
				growthWeight: profile.growthWeight
			),
			nativeContent: .none
		)
	}

	private static func dictionary(
		_ panels: [PanelDescriptor]
	) -> [PanelID: PanelDescriptor] {
		Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
	}

	private static func dictionary(
		_ workspaces: [WorkspaceDescriptor]
	) -> [WorkspaceID: WorkspaceDescriptor] {
		Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
	}
}
