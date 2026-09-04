import Foundation

enum DemoWorkspaceID: String, CaseIterable, Hashable, Sendable {
	case teaser
	case arkSolver
	case foch
	case paper
	case infrastructure
	case sortAndPour
}

enum DemoPanelID: String, Hashable, Sendable {
	case teaserTasks
	case teaserAgent
	case arkTerminal
	case arkFile
	case fochEditor
	case fochAgent
	case paperNotes
	case paperFile
	case infrastructureTerminal
	case infrastructureTasks
	case sortTasks
	case sortBrowser
}

enum WorkspaceAccent: Equatable, Sendable {
	case teal
	case amber
	case blue
	case violet
	case graphite
	case green
}

enum DemoPanelKind: String, Equatable, Sendable {
	case task = "TaskPanel"
	case agent = "AgentPanel"
	case cli = "CliPanel"
	case app = "AppPanel"
	case file = "FilePanel"
	case notes = "NotesPanel"
}

struct DemoTaskItem: Equatable, Identifiable, Sendable {
	let id: String
	let title: String
	let state: String
}

struct DemoAgentEvent: Equatable, Identifiable, Sendable {
	let id: String
	let label: String
	let detail: String
}

struct DemoCliLine: Equatable, Identifiable, Sendable {
	let id: String
	let prefix: String
	let text: String
	let isSuccess: Bool
}

struct DemoAppFixture: Equatable, Sendable {
	let location: String
	let title: String
	let lines: [String]
}

struct DemoFileFixture: Equatable, Sendable {
	let language: String
	let lines: [String]
}

enum DemoPanelContent: Equatable, Sendable {
	case tasks([DemoTaskItem])
	case agent(summary: String, events: [DemoAgentEvent])
	case cli([DemoCliLine])
	case app(DemoAppFixture)
	case file(DemoFileFixture)
	case notes
}

struct DemoPanel: Equatable, Identifiable, Sendable {
	let id: DemoPanelID
	let title: String
	let kind: DemoPanelKind
	let provider: String
	let source: String
	let content: DemoPanelContent
}

struct DemoWorkspace: Equatable, Identifiable, Sendable {
	let id: DemoWorkspaceID
	let title: String
	let subtitle: String
	let symbolName: String
	let accent: WorkspaceAccent
	var panelTree: TileTree<DemoPanelID>
	var panels: [DemoPanelID: DemoPanel]
}

struct TileSplitID: Hashable, Sendable {
	let rawValue: String

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

enum TileAxis: Equatable, Sendable {
	case horizontal
	case vertical
}

indirect enum TileTree<Leaf>: Equatable, Sendable
where Leaf: Equatable & Sendable {
	case leaf(Leaf)
	case split(
		id: TileSplitID,
		axis: TileAxis,
		ratio: Double,
		first: TileTree<Leaf>,
		second: TileTree<Leaf>
	)

	mutating func setRatio(splitID: TileSplitID, ratio: Double) {
		switch self {
		case .leaf:
			return
		case .split(let id, let axis, let currentRatio, var first, var second):
			if id == splitID {
				self = .split(
					id: id,
					axis: axis,
					ratio: ratio.clamped(to: 0.18 ... 0.82),
					first: first,
					second: second
				)
				return
			}

			first.setRatio(splitID: splitID, ratio: ratio)
			second.setRatio(splitID: splitID, ratio: ratio)
			self = .split(
				id: id,
				axis: axis,
				ratio: currentRatio,
				first: first,
				second: second
			)
		}
	}

	mutating func swapLeaves(_ firstLeaf: Leaf, _ secondLeaf: Leaf) {
		switch self {
		case .leaf(let leaf):
			if leaf == firstLeaf {
				self = .leaf(secondLeaf)
			} else if leaf == secondLeaf {
				self = .leaf(firstLeaf)
			}
		case .split(let id, let axis, let ratio, var first, var second):
			first.swapLeaves(firstLeaf, secondLeaf)
			second.swapLeaves(firstLeaf, secondLeaf)
			self = .split(
				id: id,
				axis: axis,
				ratio: ratio,
				first: first,
				second: second
			)
		}
	}
}

enum PresentationMode: Equatable, Sendable {
	case tiled
	case focused(DemoWorkspaceID)
}

enum TileScope: Equatable, Sendable {
	case presentation
	case workspace(DemoWorkspaceID)
}

struct PresentationState: Equatable, Sendable {
	var mode: PresentationMode
	var workspaceTree: TileTree<DemoWorkspaceID>
	var workspaces: [DemoWorkspaceID: DemoWorkspace]
	var editablePanelText: [DemoPanelID: String]

	static func demoInitial() -> PresentationState {
		.init(
			mode: .tiled,
			workspaceTree: .split(
				id: .init("presentation-rows"),
				axis: .vertical,
				ratio: 0.52,
				first: .split(
					id: .init("presentation-top-leading"),
					axis: .horizontal,
					ratio: 0.36,
					first: .leaf(.teaser),
					second: .split(
						id: .init("presentation-top-trailing"),
						axis: .horizontal,
						ratio: 0.50,
						first: .leaf(.arkSolver),
						second: .leaf(.foch)
					)
				),
				second: .split(
					id: .init("presentation-bottom-leading"),
					axis: .horizontal,
					ratio: 0.28,
					first: .leaf(.paper),
					second: .split(
						id: .init("presentation-bottom-trailing"),
						axis: .horizontal,
						ratio: 0.53,
						first: .leaf(.infrastructure),
						second: .leaf(.sortAndPour)
					)
				)
			),
			workspaces: [
				.teaser: teaserWorkspace(),
				.arkSolver: arkWorkspace(),
				.foch: fochWorkspace(),
				.paper: paperWorkspace(),
				.infrastructure: infrastructureWorkspace(),
				.sortAndPour: sortAndPourWorkspace(),
			],
			editablePanelText: [
				.paperNotes: "Keep the six-workspace overview as the opening shot.\n\nFocus Paper, edit this note, then return to the tiled presentation.",
			]
		)
	}

	private static func teaserWorkspace() -> DemoWorkspace {
		.init(
			id: .teaser,
			title: "Teaser",
			subtitle: "Demo workspace",
			symbolName: "rectangle.3.group",
			accent: .teal,
			panelTree: panelSplit("teaser", .teaserTasks, .teaserAgent, ratio: 0.48),
			panels: [
				.teaserTasks: .init(
					id: .teaserTasks,
					title: "Demo cut",
					kind: .task,
					provider: "Linear",
					source: "TEA-24",
					content: .tasks([
						.init(id: "TEA-24", title: "Six-workspace presentation", state: "In progress"),
						.init(id: "TEA-26", title: "Panel fixture pass", state: "Ready"),
						.init(id: "TEA-31", title: "Record two-minute demo", state: "Later"),
					])
				),
				.teaserAgent: .init(
					id: .teaserAgent,
					title: "Implementation",
					kind: .agent,
					provider: "Codex",
					source: "Codex CLI · teaser",
					content: .agent(
						summary: "Refining the compact Panel renderer",
						events: [
							.init(id: "inspect", label: "Inspected", detail: "DemoView.swift"),
							.init(id: "edit", label: "Edited", detail: "fixture presentation"),
							.init(id: "check", label: "Next", detail: "Swift build gate"),
						]
					)
				),
			]
		)
	}

	private static func arkWorkspace() -> DemoWorkspace {
		.init(
			id: .arkSolver,
			title: "Ark Solver",
			subtitle: "Search and replay",
			symbolName: "cpu",
			accent: .amber,
			panelTree: panelSplit("ark", .arkTerminal, .arkFile, ratio: 0.46),
			panels: [
				.arkTerminal: .init(
					id: .arkTerminal,
					title: "Replay worker",
					kind: .cli,
					provider: "Ghostty",
					source: "SSH · solver-gpu",
					content: .cli([
						.init(id: "ssh", prefix: "❯", text: "ssh solver-gpu", isSuccess: false),
						.init(id: "run", prefix: "❯", text: "cargo run -p ark-replay -- JT8-3", isSuccess: false),
						.init(id: "done", prefix: "✓", text: "replay certified · 42.18", isSuccess: true),
					])
				),
				.arkFile: .init(
					id: .arkFile,
					title: "Search policy",
					kind: .file,
					provider: "Quick Look",
					source: "solver/search.rs",
					content: .file(.init(
						language: "Rust",
						lines: [
							"pub fn next_stage(state: &State) -> Stage {",
							"\tfrontier.best_candidate(state)",
							"\t\t.expect(\"validated frontier\")",
							"}",
						]
					))
				),
			]
		)
	}

	private static func fochWorkspace() -> DemoWorkspace {
		.init(
			id: .foch,
			title: "Foch",
			subtitle: "Desktop client",
			symbolName: "shippingbox",
			accent: .blue,
			panelTree: panelSplit("foch", .fochEditor, .fochAgent, ratio: 0.58),
			panels: [
				.fochEditor: .init(
					id: .fochEditor,
					title: "Editor",
					kind: .app,
					provider: "Zed",
					source: "foch · src/session",
					content: .app(.init(
						location: "src/session/merge.rs",
						title: "MergeSession",
						lines: [
							"impl MergeSession {",
							"\tpub async fn resume(&self) -> Result<()> {",
							"\t\tself.cache.restore().await?;",
							"\t}",
						]
					))
				),
				.fochAgent: .init(
					id: .fochAgent,
					title: "Review",
					kind: .agent,
					provider: "Claude Code",
					source: "foch · session-18",
					content: .agent(
						summary: "Checking the recovery boundary",
						events: [
							.init(id: "read", label: "Read", detail: "cache/session.rs"),
							.init(id: "found", label: "Found", detail: "one stale transition"),
							.init(id: "verify", label: "Next", detail: "targeted test"),
						]
					)
				),
			]
		)
	}

	private static func paperWorkspace() -> DemoWorkspace {
		.init(
			id: .paper,
			title: "Paper",
			subtitle: "Writing workspace",
			symbolName: "doc.text",
			accent: .violet,
			panelTree: panelSplit("paper", .paperNotes, .paperFile, ratio: 0.44),
			panels: [
				.paperNotes: .init(
					id: .paperNotes,
					title: "Working notes",
					kind: .notes,
					provider: "Teaser",
					source: "Paper workspace",
					content: .notes
				),
				.paperFile: .init(
					id: .paperFile,
					title: "Draft",
					kind: .file,
					provider: "Preview",
					source: "paper/draft.pdf",
					content: .file(.init(
						language: "PDF · page 3",
						lines: [
							"Method",
							"Project context remains visible as a spatial unit.",
							"Figure 2 · Workspace presentation layout",
						]
					))
				),
			]
		)
	}

	private static func infrastructureWorkspace() -> DemoWorkspace {
		.init(
			id: .infrastructure,
			title: "Infrastructure",
			subtitle: "Build and release",
			symbolName: "server.rack",
			accent: .graphite,
			panelTree: panelSplit(
				"infrastructure",
				.infrastructureTerminal,
				.infrastructureTasks,
				ratio: 0.46
			),
			panels: [
				.infrastructureTerminal: .init(
					id: .infrastructureTerminal,
					title: "Local build",
					kind: .cli,
					provider: "Ghostty",
					source: "fish · teaser / build",
					content: .cli([
						.init(id: "command", prefix: "❯", text: "fish scripts/check.fish", isSuccess: false),
						.init(id: "rust", prefix: "✓", text: "Rust workspace · passed", isSuccess: true),
						.init(id: "swift", prefix: "✓", text: "Swift attachment tests · passed", isSuccess: true),
					])
				),
				.infrastructureTasks: .init(
					id: .infrastructureTasks,
					title: "Release checklist",
					kind: .task,
					provider: "Notion",
					source: "Hackathon submission",
					content: .tasks([
						.init(id: "capture", title: "Capture fullscreen flow", state: "Ready"),
						.init(id: "voice", title: "Record concise narration", state: "Planned"),
						.init(id: "submit", title: "Submit video", state: "Later"),
					])
				),
			]
		)
	}

	private static func sortAndPourWorkspace() -> DemoWorkspace {
		.init(
			id: .sortAndPour,
			title: "Sort & Pour",
			subtitle: "Playable release",
			symbolName: "square.grid.3x3",
			accent: .green,
			panelTree: panelSplit("sort", .sortTasks, .sortBrowser, ratio: 0.46),
			panels: [
				.sortTasks: .init(
					id: .sortTasks,
					title: "Release queue",
					kind: .task,
					provider: "Linear",
					source: "sort-and-pour / release",
					content: .tasks([
						.init(id: "PLAY-17", title: "Verify level resume", state: "Passed"),
						.init(id: "PLAY-21", title: "Capture mobile flow", state: "Ready"),
						.init(id: "PLAY-24", title: "Prepare TestFlight build", state: "Queued"),
					])
				),
				.sortBrowser: .init(
					id: .sortBrowser,
					title: "Playable",
					kind: .app,
					provider: "Google Chrome",
					source: "localhost:5173",
					content: .app(.init(
						location: "localhost:5173/play",
						title: "Level 12 · Water Sort",
						lines: [
							"Moves 18 · Best 16",
							"Undo available · session saved",
							"Next level unlocked",
						]
					))
				),
			]
		)
	}

	private static func panelSplit(
		_ prefix: String,
		_ first: DemoPanelID,
		_ second: DemoPanelID,
		ratio: Double
	) -> TileTree<DemoPanelID> {
		.split(
			id: .init("\(prefix)-panels"),
			axis: .vertical,
			ratio: ratio,
			first: .leaf(first),
			second: .leaf(second)
		)
	}

}

enum DemoAction: Equatable, Sendable {
	case setSplitRatio(scope: TileScope, splitID: TileSplitID, ratio: Double)
	case focusWorkspace(DemoWorkspaceID)
	case showTiled
	case showPreviousWorkspace
	case showNextWorkspace
	case swapPanels(source: DemoPanelID, target: DemoPanelID)
	case updateEditablePanel(DemoPanelID, text: String)
	case reset
}

enum DemoReducer {
	static func reduce(state: inout PresentationState, action: DemoAction) {
		switch action {
		case .setSplitRatio(let scope, let splitID, let ratio):
			switch scope {
			case .presentation:
				state.workspaceTree.setRatio(splitID: splitID, ratio: ratio)
			case .workspace(let workspaceID):
				state.workspaces[workspaceID]?.panelTree.setRatio(
					splitID: splitID,
					ratio: ratio
				)
			}
		case .focusWorkspace(let workspaceID):
			guard state.workspaces[workspaceID] != nil else { return }
			state.mode = .focused(workspaceID)
		case .showTiled:
			state.mode = .tiled
		case .showPreviousWorkspace:
			state.focusWorkspace(offset: -1)
		case .showNextWorkspace:
			state.focusWorkspace(offset: 1)
		case .swapPanels(let source, let target):
			state.swapPanels(source: source, target: target)
		case .updateEditablePanel(let panelID, let text):
			state.editablePanelText[panelID] = text
		case .reset:
			state = .demoInitial()
		}
	}
}

private extension PresentationState {
	mutating func swapPanels(source: DemoPanelID, target: DemoPanelID) {
		guard source != target,
			let sourceWorkspaceID: DemoWorkspaceID = workspaces.first(where: {
				$0.value.panels[source] != nil
			})?.key,
			let targetWorkspaceID: DemoWorkspaceID = workspaces.first(where: {
				$0.value.panels[target] != nil
			})?.key
		else {
			return
		}

		if sourceWorkspaceID == targetWorkspaceID {
			workspaces[sourceWorkspaceID]?.panelTree.swapLeaves(source, target)
			return
		}

		guard var sourceWorkspace: DemoWorkspace = workspaces[sourceWorkspaceID],
			var targetWorkspace: DemoWorkspace = workspaces[targetWorkspaceID],
			let sourcePanel: DemoPanel = sourceWorkspace.panels[source],
			let targetPanel: DemoPanel = targetWorkspace.panels[target]
		else {
			return
		}

		sourceWorkspace.panelTree.swapLeaves(source, target)
		targetWorkspace.panelTree.swapLeaves(source, target)
		sourceWorkspace.panels.removeValue(forKey: source)
		sourceWorkspace.panels[target] = targetPanel
		targetWorkspace.panels.removeValue(forKey: target)
		targetWorkspace.panels[source] = sourcePanel

		workspaces[sourceWorkspaceID] = sourceWorkspace
		workspaces[targetWorkspaceID] = targetWorkspace
	}

	mutating func focusWorkspace(offset: Int) {
		guard case .focused(let currentID) = mode,
			let currentIndex: Int = DemoWorkspaceID.allCases.firstIndex(of: currentID)
		else {
			return
		}

		let count: Int = DemoWorkspaceID.allCases.count
		let nextIndex: Int = (currentIndex + offset + count) % count
		mode = .focused(DemoWorkspaceID.allCases[nextIndex])
	}
}

private extension Comparable {
	func clamped(to range: ClosedRange<Self>) -> Self {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
