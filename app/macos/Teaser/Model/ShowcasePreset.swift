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

	static func presentation(
		displayID: DisplayID = mainDisplayID
	) -> WorkspacePresentation {
		let workspaces: [WorkspaceID: WorkspaceDescriptor] = [
			teaserWorkspaceID: teaserWorkspace(displayID: displayID),
			researchWorkspaceID: researchWorkspace(displayID: displayID),
			fochWorkspaceID: fochWorkspace(displayID: displayID),
			arkSolverWorkspaceID: arkSolverWorkspace(displayID: displayID),
			paperWorkspaceID: paperWorkspace(displayID: displayID),
			sortAndPourWorkspaceID: sortAndPourWorkspace(displayID: displayID),
		]
		return .init(
			mode: .tiled,
			virtualFocus: .init(
				workspaceID: teaserWorkspaceID,
				panelID: zedPanelID
			),
			displayLayouts: [
				displayID: .init(
					displayID: displayID,
					workspaceTree: workspaceTree()
				),
			],
			workspaces: workspaces,
			panelKinds: try! .init()
		)
	}

	private static func workspaceTree() -> LayoutTree<WorkspaceID> {
		.split(
			id: .init("workspace-root"),
			axis: .horizontal,
			preference: .init(desiredRatio: 0.62),
			first: .split(
				id: .init("workspace-left-stack"),
				axis: .vertical,
				preference: .init(desiredRatio: 0.65),
				first: .leaf(teaserWorkspaceID),
				second: .leaf(researchWorkspaceID)
			),
			second: .split(
				id: .init("workspace-right-foch"),
				axis: .vertical,
				preference: .init(desiredRatio: 0.40),
				first: .leaf(fochWorkspaceID),
				second: .split(
					id: .init("workspace-right-ark"),
					axis: .vertical,
					preference: .init(desiredRatio: 0.35),
					first: .leaf(arkSolverWorkspaceID),
					second: .split(
						id: .init("workspace-right-bottom"),
						axis: .horizontal,
						preference: .init(desiredRatio: 0.37),
						first: .leaf(paperWorkspaceID),
						second: .leaf(sortAndPourWorkspaceID)
					)
				)
			)
		)
	}

	private static func teaserWorkspace(displayID: DisplayID) -> WorkspaceDescriptor {
		let zed: PanelDescriptor = externalPanel(
			id: zedPanelID,
			title: "Editor",
			kindID: .app,
			provider: "Zed",
			bundleIdentifier: "dev.zed.Zed",
			context: "Teaser"
		)
		let linear: PanelDescriptor = externalPanel(
			id: linearPanelID,
			title: "Tasks",
			kindID: .task,
			provider: "Linear",
			context: "Teaser"
		)
		let codex: PanelDescriptor = externalPanel(
			id: codexPanelID,
			title: "Implementation",
			kindID: .agent,
			provider: "Ghostty",
			context: "Codex · teaser"
		)
		return .init(
			id: teaserWorkspaceID,
			title: "Teaser",
			detail: "Spatial development environment",
			displayAffinity: displayID,
			panelTree: .split(
				id: .init("teaser-zed-column"),
				axis: .horizontal,
				preference: .init(desiredRatio: 0.56),
				first: .leaf(zedPanelID),
				second: .split(
					id: .init("teaser-tools-stack"),
					axis: .vertical,
					preference: .init(desiredRatio: 0.47),
					first: .leaf(linearPanelID),
					second: .leaf(codexPanelID)
				)
			),
			panels: dictionary([zed, linear, codex])
		)
	}

	private static func researchWorkspace(displayID: DisplayID) -> WorkspaceDescriptor {
		let notion: PanelDescriptor = externalPanel(
			id: notionPanelID,
			title: "Research",
			kindID: .task,
			provider: "Notion",
			context: "Research workspace"
		)
		let notes: PanelDescriptor = .init(
			id: notesPanelID,
			title: "Working notes",
			kindID: .notes,
			providerHint: .init(
				displayName: "Teaser",
				bundleIdentifier: nil,
				context: "Research workspace"
			),
			profileOverride: nil,
			nativeContent: .notes
		)
		return .init(
			id: researchWorkspaceID,
			title: "Research",
			detail: "Reading and notes",
			displayAffinity: displayID,
			panelTree: .split(
				id: .init("research-panels"),
				axis: .horizontal,
				preference: .init(desiredRatio: 0.54),
				first: .leaf(notionPanelID),
				second: .leaf(notesPanelID)
			),
			panels: dictionary([notion, notes])
		)
	}

	private static func fochWorkspace(displayID: DisplayID) -> WorkspaceDescriptor {
		let panel: PanelDescriptor = externalPanel(
			id: claudePanelID,
			title: "Review",
			kindID: .agent,
			provider: "Warp",
			context: "Claude Code · foch"
		)
		return singlePanelWorkspace(
			id: fochWorkspaceID,
			title: "Foch",
			detail: "Desktop client",
			displayID: displayID,
			panel: panel
		)
	}

	private static func arkSolverWorkspace(
		displayID: DisplayID
	) -> WorkspaceDescriptor {
		let panel: PanelDescriptor = externalPanel(
			id: sshPanelID,
			title: "Replay worker",
			kindID: .cli,
			provider: "Terminal",
			bundleIdentifier: "com.apple.Terminal",
			context: "SSH · solver-gpu"
		)
		return singlePanelWorkspace(
			id: arkSolverWorkspaceID,
			title: "Ark Solver",
			detail: "Search and replay",
			displayID: displayID,
			panel: panel
		)
	}

	private static func paperWorkspace(displayID: DisplayID) -> WorkspaceDescriptor {
		let panel: PanelDescriptor = externalPanel(
			id: previewPanelID,
			title: "Draft",
			kindID: .file,
			provider: "Preview",
			bundleIdentifier: "com.apple.Preview",
			context: "paper/draft.pdf"
		)
		return singlePanelWorkspace(
			id: paperWorkspaceID,
			title: "Paper",
			detail: "Writing workspace",
			displayID: displayID,
			panel: panel
		)
	}

	private static func sortAndPourWorkspace(
		displayID: DisplayID
	) -> WorkspaceDescriptor {
		let panel: PanelDescriptor = externalPanel(
			id: chromePanelID,
			title: "Playable",
			kindID: .app,
			provider: "Google Chrome",
			bundleIdentifier: "com.google.Chrome",
			context: "Sort & Pour"
		)
		return singlePanelWorkspace(
			id: sortAndPourWorkspaceID,
			title: "Sort & Pour",
			detail: "Playable release",
			displayID: displayID,
			panel: panel
		)
	}

	private static func externalPanel(
		id: PanelID,
		title: String,
		kindID: PanelKindID,
		provider: String,
		bundleIdentifier: String? = nil,
		context: String? = nil
	) -> PanelDescriptor {
		.init(
			id: id,
			title: title,
			kindID: kindID,
			providerHint: .init(
				displayName: provider,
				bundleIdentifier: bundleIdentifier,
				context: context
			),
			profileOverride: nil,
			nativeContent: .none
		)
	}

	private static func singlePanelWorkspace(
		id: WorkspaceID,
		title: String,
		detail: String,
		displayID: DisplayID,
		panel: PanelDescriptor
	) -> WorkspaceDescriptor {
		.init(
			id: id,
			title: title,
			detail: detail,
			displayAffinity: displayID,
			panelTree: .leaf(panel.id),
			panels: [panel.id: panel]
		)
	}

	private static func dictionary(
		_ panels: [PanelDescriptor]
	) -> [PanelID: PanelDescriptor] {
		Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
	}
}
