import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DemoView: View {
	@ObservedObject private var state: DemoState
	@ObservedObject private var zedCoordinator: ZedCoordinator

	init(state: DemoState, zedCoordinator: ZedCoordinator) {
		self.state = state
		self.zedCoordinator = zedCoordinator
	}

	var body: some View {
		VStack(spacing: 0) {
			UtilityBar(state: state)
			Rectangle()
				.fill(DemoPalette.strongSeparator)
				.frame(height: 1)
			presentation
				.padding(5)
		}
		.background(DemoPalette.windowBackground)
		.foregroundStyle(DemoPalette.primaryText)
		.frame(
			minWidth: TeaserWindowMetrics.minimumSize.width,
			minHeight: TeaserWindowMetrics.minimumSize.height
		)
		.onExitCommand {
			state.send(.showTiled)
		}
		.onMoveCommand { direction in
			switch direction {
			case .left, .up:
				state.send(.showPreviousWorkspace)
			case .right, .down:
				state.send(.showNextWorkspace)
			@unknown default:
				break
			}
		}
		.animation(.easeInOut(duration: 0.14), value: state.presentation.mode)
	}

	@ViewBuilder
	private var presentation: some View {
		switch state.presentation.mode {
		case .tiled:
			TileTreeView(
				tree: state.presentation.workspaceTree,
				dividerThickness: 5,
				leafContent: { workspaceID in
					workspaceView(workspaceID: workspaceID, canFocus: true)
				},
				onRatioChange: { splitID, ratio in
					state.send(
						.setSplitRatio(
							scope: .presentation,
							splitID: splitID,
							ratio: ratio
						)
					)
				}
			)
		case .focused(let workspaceID):
			workspaceView(workspaceID: workspaceID, canFocus: false)
				.transition(.opacity)
		}
	}

	@ViewBuilder
	private func workspaceView(
		workspaceID: DemoWorkspaceID,
		canFocus: Bool
	) -> some View {
		if let workspace: DemoWorkspace = state.presentation.workspaces[workspaceID] {
				WorkspaceView(
					workspace: workspace,
					state: state,
					zedCoordinator: zedCoordinator,
					canFocus: canFocus,
					allowsRealZed: state.presentation.mode == .focused(workspaceID)
				)
		} else {
			Text("Workspace unavailable")
				.foregroundStyle(DemoPalette.secondaryText)
		}
	}
}

@MainActor
private struct UtilityBar: View {
	@ObservedObject var state: DemoState

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "rectangle.3.group")
				.foregroundStyle(DemoPalette.secondaryText)
			Text("Teaser")
				.font(.system(size: 12, weight: .semibold))
			Divider().frame(height: 15)
			Text(modeLabel)
				.font(.system(size: 11, weight: .medium))
			Text("Fixture data · real Zed when connected")
				.font(.system(size: 9.5))
				.foregroundStyle(DemoPalette.tertiaryText)

			Spacer(minLength: 8)

			if case .focused(let workspaceID) = state.presentation.mode {
				Button {
					state.send(.showTiled)
				} label: {
					Label("All Workspaces", systemImage: "rectangle.grid.3x2")
				}
				.keyboardShortcut(.escape, modifiers: [])

				Divider().frame(height: 15)

				Button {
					state.send(.showPreviousWorkspace)
				} label: {
					Image(systemName: "chevron.left")
				}
				.keyboardShortcut("[", modifiers: .command)
				.help("Previous Workspace")

				Text(workspaceTitle(workspaceID: workspaceID))
					.font(.system(size: 11, weight: .medium))
					.frame(minWidth: 82)

				Button {
					state.send(.showNextWorkspace)
				} label: {
					Image(systemName: "chevron.right")
				}
				.keyboardShortcut("]", modifiers: .command)
				.help("Next Workspace")

				Divider().frame(height: 15)
			}

			Button {
				state.send(.reset)
			} label: {
				Image(systemName: "arrow.counterclockwise")
			}
			.help("Reset fixture")
		}
		.buttonStyle(.borderless)
		.controlSize(.small)
		.padding(.horizontal, 10)
		.frame(height: 36)
		.background(.bar)
	}

	private var modeLabel: String {
		switch state.presentation.mode {
		case .tiled:
			return "Tiled · 6 Workspaces"
		case .focused:
			return "Focused"
		}
	}

	private func workspaceTitle(workspaceID: DemoWorkspaceID) -> String {
		state.presentation.workspaces[workspaceID]?.title ?? "Workspace"
	}
}

@MainActor
private struct WorkspaceView: View {
	let workspace: DemoWorkspace
	@ObservedObject var state: DemoState
	@ObservedObject var zedCoordinator: ZedCoordinator
	let canFocus: Bool
	let allowsRealZed: Bool

	private var projectColor: Color { workspace.accent.color }

	var body: some View {
		VStack(spacing: 0) {
			workspaceHeader
			Rectangle()
				.fill(DemoPalette.strongSeparator)
				.frame(height: 1)
			TileTreeView(
				tree: workspace.panelTree,
				dividerThickness: 5,
				leafContent: { panelID in
					panelView(panelID: panelID)
				},
				onRatioChange: { splitID, ratio in
					state.send(
						.setSplitRatio(
							scope: .workspace(workspace.id),
							splitID: splitID,
							ratio: ratio
						)
					)
				}
			)
		}
		.background(DemoPalette.workspaceBackground)
		.overlay(alignment: .leading) {
			Rectangle()
				.fill(projectColor)
				.frame(width: 2)
				.allowsHitTesting(false)
		}
		.overlay {
			RoundedRectangle(cornerRadius: 3, style: .continuous)
				.stroke(DemoPalette.strongSeparator, lineWidth: 1)
				.allowsHitTesting(false)
		}
		.clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
	}

	private var workspaceHeader: some View {
		HStack(spacing: 7) {
			Image(systemName: workspace.symbolName)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(projectColor)
			Text(workspace.title)
				.font(.system(size: 11.5, weight: .semibold))
			Text(workspace.subtitle)
				.font(.system(size: 9.5))
				.foregroundStyle(DemoPalette.tertiaryText)
				.lineLimit(1)
			Spacer(minLength: 5)
			if canFocus {
				Text("⌘\(workspace.id.shortcutLabel)")
					.font(.system(size: 8.5, design: .monospaced))
					.foregroundStyle(DemoPalette.tertiaryText)
				Button {
					state.send(.focusWorkspace(workspace.id))
				} label: {
					Image(systemName: "arrow.up.left.and.arrow.down.right")
				}
				.buttonStyle(.borderless)
				.controlSize(.mini)
				.keyboardShortcut(workspace.id.shortcutKey, modifiers: .command)
				.accessibilityLabel("Focus \(workspace.title) Workspace")
				.help("Focus this Workspace")
			}
		}
		.padding(.leading, 10)
		.padding(.trailing, 7)
		.frame(height: 31)
		.background(DemoPalette.headerBackground)
	}

	@ViewBuilder
	private func panelView(panelID: DemoPanelID) -> some View {
		if let panel: DemoPanel = workspace.panels[panelID] {
				PanelView(
					panel: panel,
					state: state,
					zedCoordinator: zedCoordinator,
					allowsRealZed: allowsRealZed
				)
		} else {
			Text("Panel unavailable")
				.foregroundStyle(DemoPalette.secondaryText)
		}
	}
}

@MainActor
private struct PanelView: View {
	let panel: DemoPanel
	@ObservedObject var state: DemoState
	@ObservedObject var zedCoordinator: ZedCoordinator
	let allowsRealZed: Bool
	@State private var isDropTarget: Bool = false

	var body: some View {
		VStack(spacing: 0) {
			panelHeader
			Rectangle()
				.fill(DemoPalette.separator)
				.frame(height: 1)
			panelContent
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		.background(DemoPalette.panelBackground)
		.overlay {
			Rectangle()
				.stroke(
					isDropTarget ? DemoPalette.selection : DemoPalette.separator,
					lineWidth: isDropTarget ? 2 : 1
				)
				.allowsHitTesting(false)
		}
		.dropDestination(for: PanelDragItem.self) { items, _ in
			guard let item: PanelDragItem = items.first,
				let sourceID: DemoPanelID = .init(rawValue: item.panelID),
				sourceID != panel.id
			else {
				return false
			}

			state.send(.swapPanels(source: sourceID, target: panel.id))
			return true
		} isTargeted: { isTargeted in
			isDropTarget = isTargeted
		}
		.animation(.easeOut(duration: 0.10), value: isDropTarget)
	}

	private var panelHeader: some View {
		HStack(spacing: 6) {
			Image(systemName: panel.kind.symbolName)
				.font(.system(size: 9, weight: .medium))
				.foregroundStyle(DemoPalette.secondaryText)
			Text(panel.title)
				.font(.system(size: 10, weight: .medium))
				.lineLimit(1)
			Spacer(minLength: 5)
			if isFocusedZedPanel {
				ZedConnectionHeader(coordinator: zedCoordinator)
			} else {
				ViewThatFits(in: .horizontal) {
					Text("\(panel.kind.rawValue) · \(panel.provider) · \(panel.source)")
					Text("\(panel.kind.rawValue) · \(panel.provider)")
					Text(panel.provider)
				}
					.font(.system(size: 8.5, design: .monospaced))
					.foregroundStyle(DemoPalette.tertiaryText)
					.lineLimit(1)
			}
		}
		.padding(.horizontal, 8)
		.frame(height: 25)
		.background(DemoPalette.panelHeaderBackground)
		.contentShape(Rectangle())
		.draggable(PanelDragItem(panelID: panel.id.rawValue)) {
			PanelDragPreview(panel: panel)
		}
		.help("Drag to swap this Panel")
	}

	@ViewBuilder
	private var panelContent: some View {
		switch panel.content {
		case .tasks(let items):
			if panel.provider == "Notion" {
				NotionChecklistView(items: items)
			} else {
				LinearIssueListView(items: items)
			}
		case .agent(let summary, let events):
			if panel.provider == "Claude Code" {
				ClaudeCodeSessionView(summary: summary, events: events)
			} else {
				CodexRunTimelineView(summary: summary, events: events)
			}
		case .cli(let lines):
			GhosttyTerminalView(source: panel.source, lines: lines)
		case .app(let fixture):
			if panel.provider == "Zed", allowsRealZed {
				ManagedZedSurface(fixture: fixture, coordinator: zedCoordinator)
			} else if panel.provider == "Zed" {
				ZedEditorView(fixture: fixture)
			} else {
				ChromeGameView(fixture: fixture)
			}
		case .file(let fixture):
			if panel.provider == "Preview" {
				PreviewPDFView(fixture: fixture)
			} else {
				QuickLookSourceView(fixture: fixture)
			}
		case .notes:
			TeaserNotesView(
				text: .init(
					get: {
						state.presentation.editablePanelText[panel.id] ?? ""
					},
					set: { value in
						state.send(.updateEditablePanel(panel.id, text: value))
					}
				)
			)
		}
	}

	private var isFocusedZedPanel: Bool {
		panel.provider == "Zed" && allowsRealZed
	}
}

private struct PanelDragItem: Codable, Transferable, Sendable {
	let panelID: String

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .teaserPanel)
	}
}

private extension UTType {
	static let teaserPanel: UTType = .init(exportedAs: "com.acture.teaser.panel-transfer")
}

@MainActor
private struct PanelDragPreview: View {
	let panel: DemoPanel

	var body: some View {
		HStack(spacing: 7) {
			Image(systemName: panel.kind.symbolName)
			Text(panel.title)
			Spacer(minLength: 8)
			Text(panel.provider)
				.foregroundStyle(DemoPalette.secondaryText)
		}
		.font(.system(size: 10, weight: .medium))
		.padding(.horizontal, 10)
		.frame(width: 220, height: 34)
		.background(DemoPalette.headerBackground)
		.overlay {
			RoundedRectangle(cornerRadius: 4)
				.stroke(DemoPalette.selection, lineWidth: 1)
		}
		.clipShape(RoundedRectangle(cornerRadius: 4))
	}
}

@MainActor
private struct LinearIssueListView: View {
	let items: [DemoTaskItem]

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Text("ID").frame(width: 52, alignment: .leading)
				Text("Issue")
				Spacer(minLength: 0)
				Text("Status")
			}
			.font(.system(size: 8.5, weight: .medium))
			.foregroundStyle(DemoPalette.tertiaryText)
			.padding(.horizontal, 8)
			.frame(height: 22)
			ForEach(items) { item in
				HStack(spacing: 8) {
					Image(systemName: issueSymbol(item.state))
						.font(.system(size: 8))
						.foregroundStyle(issueColor(item.state))
					Text(item.id)
						.font(.system(size: 8.5, design: .monospaced))
						.foregroundStyle(DemoPalette.secondaryText)
						.frame(width: 42, alignment: .leading)
					Text(item.title)
						.font(.system(size: 9.5))
						.lineLimit(1)
					Spacer(minLength: 4)
					Text(item.state)
						.font(.system(size: 8.5))
						.foregroundStyle(DemoPalette.secondaryText)
				}
				.padding(.horizontal, 8)
				.frame(height: 27)
				.overlay(alignment: .top) {
					Rectangle().fill(DemoPalette.separator).frame(height: 1)
				}
			}
			Spacer(minLength: 0)
		}
	}

	private func issueSymbol(_ state: String) -> String {
		state == "Passed" ? "checkmark.circle.fill" : state == "In progress" ? "circle.dotted" : "circle"
	}

	private func issueColor(_ state: String) -> Color {
		state == "Passed" ? DemoPalette.success : state == "In progress" ? DemoPalette.selection : DemoPalette.tertiaryText
	}
}

@MainActor
private struct NotionChecklistView: View {
	let items: [DemoTaskItem]

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "tablecells")
				Text("Submission checklist")
				Spacer(minLength: 0)
				Image(systemName: "line.3.horizontal.decrease")
				Image(systemName: "magnifyingglass")
			}
			.font(.system(size: 9, weight: .medium))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 25)
			.overlay(alignment: .bottom) {
				Rectangle().fill(DemoPalette.separator).frame(height: 1)
			}
			ForEach(items) { item in
				HStack(spacing: 8) {
					Image(systemName: item.state == "Ready" ? "checkmark.square" : "square")
						.font(.system(size: 9))
						.foregroundStyle(DemoPalette.secondaryText)
					Text(item.title)
						.font(.system(size: 9.5))
						.lineLimit(1)
					Spacer(minLength: 4)
					Text(item.state)
						.font(.system(size: 8.5))
						.foregroundStyle(DemoPalette.tertiaryText)
				}
				.padding(.horizontal, 8)
				.frame(height: 26)
				.overlay(alignment: .bottom) {
					Rectangle().fill(DemoPalette.separator).frame(height: 1)
				}
			}
			Spacer(minLength: 0)
		}
	}
}

@MainActor
private struct CodexRunTimelineView: View {
	let summary: String
	let events: [DemoAgentEvent]

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 6) {
				Circle().fill(DemoPalette.success).frame(width: 6, height: 6)
				Text("Run in progress")
				Spacer(minLength: 0)
				Text("\(events.count) steps")
			}
			.font(.system(size: 8.5, weight: .medium))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 22)
			Text(summary)
				.font(.system(size: 9.5, weight: .medium))
				.lineLimit(1)
				.padding(.horizontal, 8)
				.frame(height: 24)
			ForEach(events) { event in
				HStack(spacing: 8) {
					ZStack {
						Rectangle().fill(DemoPalette.separator).frame(width: 1)
						Circle().fill(DemoPalette.secondaryText).frame(width: 5, height: 5)
					}
					.frame(width: 8, height: 22)
					Text(event.label)
						.foregroundStyle(DemoPalette.secondaryText)
						.frame(width: 56, alignment: .leading)
					Text(event.detail).lineLimit(1)
					Spacer(minLength: 0)
				}
				.font(.system(size: 8.8, design: .monospaced))
				.padding(.horizontal, 8)
			}
			Spacer(minLength: 0)
		}
	}
}

@MainActor
private struct ClaudeCodeSessionView: View {
	let summary: String
	let events: [DemoAgentEvent]

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			Text("❯ claude --continue session-18")
				.foregroundStyle(DemoPalette.selection)
			Text("● \(summary)")
				.foregroundStyle(DemoPalette.primaryText)
			ForEach(events) { event in
				Text("  \(event.label.lowercased())  \(event.detail)")
					.foregroundStyle(DemoPalette.secondaryText)
					.lineLimit(1)
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 9, design: .monospaced))
		.padding(8)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(DemoPalette.terminalBackground)
	}
}

@MainActor
private struct GhosttyTerminalView: View {
	let source: String
	let lines: [DemoCliLine]

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 5) {
				ForEach(0 ..< 3, id: \.self) { _ in
					Circle().fill(DemoPalette.tertiaryText.opacity(0.65)).frame(width: 6, height: 6)
				}
				Text(source)
					.font(.system(size: 8.5, design: .monospaced))
					.foregroundStyle(DemoPalette.secondaryText)
					.lineLimit(1)
				Spacer(minLength: 0)
				Image(systemName: "plus")
					.font(.system(size: 8))
					.foregroundStyle(DemoPalette.tertiaryText)
			}
			.padding(.horizontal, 8)
			.frame(height: 22)
			.background(DemoPalette.terminalChrome)
			VStack(alignment: .leading, spacing: 5) {
				ForEach(lines) { line in
					HStack(spacing: 7) {
						Text(line.prefix)
							.foregroundStyle(line.isSuccess ? DemoPalette.success : DemoPalette.selection)
						Text(line.text).lineLimit(1)
					}
				}
				Spacer(minLength: 0)
			}
			.font(.system(size: 9, design: .monospaced))
			.padding(8)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.background(DemoPalette.terminalBackground)
		}
	}
}

@MainActor
private struct ZedConnectionHeader: View {
	@ObservedObject var coordinator: ZedCoordinator

	var body: some View {
		HStack(spacing: 6) {
			switch coordinator.state {
			case .disconnected:
				Text("External window")
				Button("Connect") {
					coordinator.connect()
				}
			case .permissionRequired:
				Image(systemName: "lock")
				Text("Accessibility required")
				Button("Enable Access") {
					coordinator.retryPermission()
				}
			case .launching:
				ProgressView().controlSize(.mini)
				Text("Opening Zed…")
			case .locating:
				ProgressView().controlSize(.mini)
				Text("Locating window…")
			case .attached:
				Circle().fill(DemoPalette.success).frame(width: 5, height: 5)
				Text("Real Zed · external window")
				Button("Focus") {
					coordinator.focus()
				}
				Button("Release") {
					coordinator.release()
				}
			case .releasePending:
				Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
				Text("Release pending")
				Button("Retry Release") {
					coordinator.release()
				}
			case .failed:
				Image(systemName: "exclamationmark.triangle")
				Text("Zed unavailable")
				Button("Retry") {
					coordinator.connect()
				}
			}
		}
		.font(.system(size: 8.5, design: .monospaced))
		.foregroundStyle(DemoPalette.tertiaryText)
		.buttonStyle(.borderless)
		.controlSize(.mini)
		.lineLimit(1)
	}
}

@MainActor
private struct ManagedZedSurface: View {
	let fixture: DemoAppFixture
	@ObservedObject var coordinator: ZedCoordinator

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			ZedEditorView(fixture: fixture)
			connectionAffordance
		}
		.background {
			ScreenFrameReporter { window in
				coordinator.updateHostWindow(window)
			}
		}
	}

	@ViewBuilder
	private var connectionAffordance: some View {
		switch coordinator.state {
		case .disconnected:
			ZedConnectionPrompt(
				message: "Tile the real Zed window beside this focused Workspace.",
				actionTitle: "Connect",
				action: coordinator.connect
			)
		case .permissionRequired:
			ZedConnectionPrompt(
				message: "Accessibility access is required to position Zed.",
				actionTitle: "Enable Access",
				action: coordinator.retryPermission
			)
		case .launching:
			ZedConnectionProgress(message: "Opening Zed…")
		case .locating:
			ZedConnectionProgress(message: "Locating a Zed window…")
		case .attached:
			ZedCompanionStatus()
		case .releasePending(let message):
			ZedConnectionPrompt(
				message: message,
				actionTitle: "Retry Release",
				action: coordinator.release
			)
		case .failed(let message):
			ZedConnectionPrompt(
				message: message,
				actionTitle: "Retry",
				action: coordinator.connect
			)
		}
	}
}

@MainActor
private struct ZedCompanionStatus: View {
	var body: some View {
		Label("Live Zed is tiled beside Teaser", systemImage: "rectangle.split.2x1")
			.font(.system(size: 9, weight: .medium))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(8)
			.background(DemoPalette.headerBackground.opacity(0.96))
			.overlay {
				RoundedRectangle(cornerRadius: 4)
					.stroke(DemoPalette.strongSeparator, lineWidth: 1)
			}
			.clipShape(RoundedRectangle(cornerRadius: 4))
			.padding(8)
	}
}

@MainActor
private struct ZedConnectionPrompt: View {
	let message: String
	let actionTitle: String
	let action: @MainActor () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Text(message)
				.font(.system(size: 9))
				.foregroundStyle(DemoPalette.secondaryText)
				.lineLimit(2)
			Button(actionTitle, action: action)
				.buttonStyle(.bordered)
				.controlSize(.small)
		}
		.padding(8)
		.background(DemoPalette.headerBackground.opacity(0.96))
		.overlay {
			RoundedRectangle(cornerRadius: 4)
				.stroke(DemoPalette.strongSeparator, lineWidth: 1)
		}
		.clipShape(RoundedRectangle(cornerRadius: 4))
		.padding(8)
	}
}

@MainActor
private struct ZedConnectionProgress: View {
	let message: String

	var body: some View {
		HStack(spacing: 7) {
			ProgressView().controlSize(.small)
			Text(message)
				.font(.system(size: 9))
				.foregroundStyle(DemoPalette.secondaryText)
		}
		.padding(8)
		.background(DemoPalette.headerBackground.opacity(0.96))
		.clipShape(RoundedRectangle(cornerRadius: 4))
		.padding(8)
	}
}

@MainActor
private struct ZedEditorView: View {
	let fixture: DemoAppFixture

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "sidebar.left")
				Text("foch")
				Spacer(minLength: 0)
				Text("main · clean")
			}
			.font(.system(size: 8.5, weight: .medium))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 21)
			.background(DemoPalette.editorChrome)
			HStack(spacing: 6) {
				Image(systemName: "chevron.left.forwardslash.chevron.right")
				Text(fixture.location).lineLimit(1)
				Spacer(minLength: 0)
				Circle().fill(DemoPalette.tertiaryText).frame(width: 4, height: 4)
			}
			.font(.system(size: 8.5, design: .monospaced))
			.padding(.horizontal, 8)
			.frame(height: 22)
			.overlay(alignment: .bottom) {
				Rectangle().fill(DemoPalette.separator).frame(height: 1)
			}
			VStack(alignment: .leading, spacing: 0) {
				ForEach(Array(fixture.lines.enumerated()), id: \.offset) { index, line in
					HStack(spacing: 8) {
						Text("\(index + 1)")
							.foregroundStyle(DemoPalette.tertiaryText)
							.frame(width: 16, alignment: .trailing)
						Text(line).lineLimit(1)
					}
					.frame(height: 19)
				}
				Spacer(minLength: 0)
			}
			.font(.system(size: 8.8, design: .monospaced))
			.padding(.horizontal, 7)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			HStack {
				Text("main")
				Spacer(minLength: 0)
				Text("Rust · Ln 12, Col 5")
			}
			.font(.system(size: 8, design: .monospaced))
			.foregroundStyle(DemoPalette.tertiaryText)
			.padding(.horizontal, 8)
			.frame(height: 18)
			.background(DemoPalette.editorChrome)
		}
	}
}

@MainActor
private struct QuickLookSourceView: View {
	let fixture: DemoFileFixture

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "eye")
				Text("\(fixture.language) source preview")
				Spacer(minLength: 0)
				Image(systemName: "square.and.arrow.up")
				Image(systemName: "ellipsis.circle")
			}
			.font(.system(size: 8.5, weight: .medium))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 23)
			.background(DemoPalette.previewChrome)
			VStack(alignment: .leading, spacing: 0) {
				ForEach(Array(fixture.lines.enumerated()), id: \.offset) { index, line in
					HStack(spacing: 8) {
						Text("\(index + 1)")
							.foregroundStyle(DemoPalette.tertiaryText)
							.frame(width: 17, alignment: .trailing)
						Text(line).lineLimit(1)
					}
					.frame(height: 20)
				}
				Spacer(minLength: 0)
			}
			.font(.system(size: 9, design: .monospaced))
			.padding(8)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}
}

@MainActor
private struct PreviewPDFView: View {
	let fixture: DemoFileFixture

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "sidebar.left")
				Image(systemName: "minus.magnifyingglass")
				Text("\(fixture.language)")
				Spacer(minLength: 0)
				Image(systemName: "plus.magnifyingglass")
				Image(systemName: "square.and.arrow.up")
			}
			.font(.system(size: 8.5))
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 23)
			.background(DemoPalette.previewChrome)
			GeometryReader { proxy in
				let pageWidth: CGFloat = min(250, max(120, proxy.size.width - 22))

				ScrollView(.vertical) {
					VStack(alignment: .leading, spacing: 4) {
						Text(fixture.lines.first ?? "Method")
							.font(.system(size: 10, weight: .semibold))
						ForEach(Array(fixture.lines.dropFirst().enumerated()), id: \.offset) { _, line in
							Text(line)
								.font(.system(size: 6.8))
								.lineLimit(2)
						}
						Spacer(minLength: 0)
						Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
						Text("3")
							.font(.system(size: 6))
							.frame(maxWidth: .infinity, alignment: .center)
					}
					.foregroundStyle(DemoPalette.paperText)
					.padding(9)
					.frame(width: pageWidth, height: pageWidth * 1.414)
					.background(DemoPalette.paper)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 7)
				}
			}
			.background(DemoPalette.previewCanvas)
		}
	}
}

@MainActor
private struct ChromeGameView: View {
	let fixture: DemoAppFixture

	private let vials: [[Color]] = [
		[DemoPalette.gameBlue, DemoPalette.gameAmber, DemoPalette.gameGreen],
		[DemoPalette.gameViolet, DemoPalette.gameBlue, DemoPalette.gameAmber],
		[DemoPalette.gameGreen, DemoPalette.gameViolet, DemoPalette.gameBlue],
		[],
	]

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 5) {
				ForEach(0 ..< 3, id: \.self) { _ in
					Circle().fill(DemoPalette.tertiaryText.opacity(0.65)).frame(width: 6, height: 6)
				}
				HStack(spacing: 5) {
					Image(systemName: "lock.fill").font(.system(size: 6))
					Text(fixture.location).lineLimit(1)
				}
				.font(.system(size: 8, design: .monospaced))
				.foregroundStyle(DemoPalette.secondaryText)
				.padding(.horizontal, 7)
				.frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
				.background(DemoPalette.chromeAddress)
				.clipShape(RoundedRectangle(cornerRadius: 5))
				Image(systemName: "ellipsis")
					.font(.system(size: 8))
			}
			.padding(.horizontal, 7)
			.frame(height: 25)
			.background(DemoPalette.chromeBar)
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 4) {
					Text(fixture.title)
						.font(.system(size: 10, weight: .semibold))
					Text(fixture.lines.first ?? "Moves 18")
						.font(.system(size: 8.5, design: .monospaced))
						.foregroundStyle(DemoPalette.secondaryText)
					Spacer(minLength: 0)
					HStack(spacing: 5) {
						Image(systemName: "arrow.uturn.backward")
						Text("Undo")
					}
					.font(.system(size: 8.5, weight: .medium))
					.foregroundStyle(DemoPalette.secondaryText)
				}
				ForEach(Array(vials.enumerated()), id: \.offset) { _, levels in
					GameVial(levels: levels)
				}
			}
			.padding(10)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.background(DemoPalette.gameBackground)
		}
	}
}

@MainActor
private struct GameVial: View {
	let levels: [Color]

	var body: some View {
		VStack(spacing: 1) {
			Spacer(minLength: 0)
			ForEach(Array(levels.enumerated()), id: \.offset) { _, color in
				Rectangle().fill(color).frame(height: 12)
			}
		}
		.padding(2)
		.frame(width: 30, height: 62)
		.overlay {
			UnevenRoundedRectangle(
				topLeadingRadius: 1,
				bottomLeadingRadius: 7,
				bottomTrailingRadius: 7,
				topTrailingRadius: 1
			)
			.stroke(DemoPalette.secondaryText, lineWidth: 1)
		}
	}
}

@MainActor
private struct TeaserNotesView: View {
	@Binding var text: String

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Text("Working notes")
					.font(.system(size: 9, weight: .medium))
				Spacer(minLength: 0)
				Image(systemName: "bold")
				Image(systemName: "italic")
				Image(systemName: "list.bullet")
			}
			.foregroundStyle(DemoPalette.secondaryText)
			.padding(.horizontal, 8)
			.frame(height: 23)
			.background(DemoPalette.notesChrome)
			TextEditor(text: $text)
				.font(.system(size: 9.5))
				.scrollContentBackground(.hidden)
				.padding(4)
				.background(DemoPalette.notesBackground)
				.overlay(alignment: .bottomTrailing) {
					Text("Saved locally")
						.font(.system(size: 8))
						.foregroundStyle(DemoPalette.tertiaryText)
						.padding(6)
						.allowsHitTesting(false)
				}
		}
	}
}

@MainActor
private struct TileTreeView<Leaf, LeafContent>: View
where Leaf: Equatable & Sendable, LeafContent: View {
	let tree: TileTree<Leaf>
	let dividerThickness: CGFloat
	let leafContent: (Leaf) -> LeafContent
	let onRatioChange: (TileSplitID, Double) -> Void

	init(
		tree: TileTree<Leaf>,
		dividerThickness: CGFloat,
		@ViewBuilder leafContent: @escaping (Leaf) -> LeafContent,
		onRatioChange: @escaping (TileSplitID, Double) -> Void
	) {
		self.tree = tree
		self.dividerThickness = dividerThickness
		self.leafContent = leafContent
		self.onRatioChange = onRatioChange
	}

	var body: some View {
		render(tree: tree)
	}

	private func render(tree: TileTree<Leaf>) -> AnyView {
		switch tree {
		case .leaf(let leaf):
			return AnyView(leafContent(leaf))
		case .split(let id, let axis, let ratio, let first, let second):
			return AnyView(
				GeometryReader { proxy in
					let fullLength: CGFloat = axis == .horizontal
						? proxy.size.width
						: proxy.size.height
					let availableLength: CGFloat = max(1, fullLength - dividerThickness)
					let firstLength: CGFloat = availableLength * CGFloat(ratio)
					let secondLength: CGFloat = availableLength - firstLength

					if axis == .horizontal {
						HStack(spacing: 0) {
							child(tree: first).frame(width: firstLength)
							SplitHandle(
								axis: axis,
								currentRatio: ratio,
								availableLength: availableLength,
								onRatioChange: { onRatioChange(id, $0) }
							)
							.frame(width: dividerThickness)
							child(tree: second).frame(width: secondLength)
						}
					} else {
						VStack(spacing: 0) {
							child(tree: first).frame(height: firstLength)
							SplitHandle(
								axis: axis,
								currentRatio: ratio,
								availableLength: availableLength,
								onRatioChange: { onRatioChange(id, $0) }
							)
							.frame(height: dividerThickness)
							child(tree: second).frame(height: secondLength)
						}
					}
				}
			)
		}
	}

	private func child(tree: TileTree<Leaf>) -> TileTreeView<Leaf, LeafContent> {
		.init(
			tree: tree,
			dividerThickness: dividerThickness,
			leafContent: leafContent,
			onRatioChange: onRatioChange
		)
	}
}

@MainActor
private struct SplitHandle: View {
	let axis: TileAxis
	let currentRatio: Double
	let availableLength: CGFloat
	let onRatioChange: (Double) -> Void

	@State private var dragStartRatio: Double?
	@State private var isHovered: Bool = false

	var body: some View {
		ZStack {
			Color.clear
			Rectangle()
				.fill(isHovered ? DemoPalette.selection : DemoPalette.separator)
				.frame(
					width: axis == .horizontal ? 1 : nil,
					height: axis == .vertical ? 1 : nil
				)
		}
		.contentShape(Rectangle())
		.onHover { isHovered = $0 }
		.gesture(
			DragGesture(minimumDistance: 0)
				.onChanged { value in
					let initialRatio: Double = dragStartRatio ?? currentRatio
					if dragStartRatio == nil {
						dragStartRatio = currentRatio
					}
					let translation: CGFloat = axis == .horizontal
						? value.translation.width
						: value.translation.height
					onRatioChange(initialRatio + Double(translation / max(availableLength, 1)))
				}
				.onEnded { _ in dragStartRatio = nil }
		)
	}
}

private enum DemoPalette {
	static let windowBackground: Color = .init(red: 0.095, green: 0.098, blue: 0.105)
	static let workspaceBackground: Color = .init(red: 0.125, green: 0.129, blue: 0.138)
	static let headerBackground: Color = .init(red: 0.145, green: 0.149, blue: 0.158)
	static let panelBackground: Color = .init(red: 0.108, green: 0.112, blue: 0.120)
	static let panelHeaderBackground: Color = .init(red: 0.136, green: 0.140, blue: 0.149)
	static let editorBackground: Color = .init(red: 0.082, green: 0.085, blue: 0.092)
	static let editorChrome: Color = .init(red: 0.118, green: 0.121, blue: 0.130)
	static let terminalBackground: Color = .init(red: 0.057, green: 0.061, blue: 0.067)
	static let terminalChrome: Color = .init(red: 0.092, green: 0.096, blue: 0.104)
	static let previewChrome: Color = .init(red: 0.167, green: 0.171, blue: 0.180)
	static let previewCanvas: Color = .init(red: 0.185, green: 0.189, blue: 0.198)
	static let paper: Color = .init(red: 0.92, green: 0.91, blue: 0.89)
	static let paperText: Color = .init(red: 0.13, green: 0.13, blue: 0.14)
	static let chromeBar: Color = .init(red: 0.155, green: 0.159, blue: 0.168)
	static let chromeAddress: Color = .init(red: 0.105, green: 0.109, blue: 0.117)
	static let gameBackground: Color = .init(red: 0.075, green: 0.092, blue: 0.112)
	static let notesChrome: Color = .init(red: 0.154, green: 0.148, blue: 0.133)
	static let notesBackground: Color = .init(red: 0.105, green: 0.102, blue: 0.094)
	static let primaryText: Color = .white.opacity(0.92)
	static let secondaryText: Color = .white.opacity(0.67)
	static let tertiaryText: Color = .white.opacity(0.48)
	static let separator: Color = .init(nsColor: .separatorColor)
	static let strongSeparator: Color = .init(nsColor: .gridColor)
	static let selection: Color = .init(nsColor: .controlAccentColor)
	static let success: Color = .init(red: 0.40, green: 0.64, blue: 0.52)
	static let teal: Color = .init(red: 0.37, green: 0.59, blue: 0.57)
	static let amber: Color = .init(red: 0.65, green: 0.53, blue: 0.34)
	static let blue: Color = .init(red: 0.40, green: 0.53, blue: 0.67)
	static let violet: Color = .init(red: 0.53, green: 0.47, blue: 0.64)
	static let graphite: Color = .init(red: 0.51, green: 0.53, blue: 0.56)
	static let green: Color = .init(red: 0.40, green: 0.58, blue: 0.43)
	static let gameBlue: Color = .init(red: 0.30, green: 0.56, blue: 0.72)
	static let gameAmber: Color = .init(red: 0.76, green: 0.55, blue: 0.27)
	static let gameGreen: Color = .init(red: 0.32, green: 0.65, blue: 0.47)
	static let gameViolet: Color = .init(red: 0.58, green: 0.44, blue: 0.72)
}

private extension DemoPanelKind {
	var symbolName: String {
		switch self {
		case .task: "checklist"
		case .agent: "gearshape.2"
		case .cli: "terminal"
		case .app: "macwindow"
		case .file: "doc.text"
		case .notes: "square.and.pencil"
		}
	}
}

private extension WorkspaceAccent {
	var color: Color {
		switch self {
		case .teal: DemoPalette.teal
		case .amber: DemoPalette.amber
		case .blue: DemoPalette.blue
		case .violet: DemoPalette.violet
		case .graphite: DemoPalette.graphite
		case .green: DemoPalette.green
		}
	}
}

private extension DemoWorkspaceID {
	var shortcutKey: KeyEquivalent {
		switch self {
		case .teaser: "1"
		case .arkSolver: "2"
		case .foch: "3"
		case .paper: "4"
		case .infrastructure: "5"
		case .sortAndPour: "6"
		}
	}

	var shortcutLabel: String {
		String(shortcutKey.character)
	}
}
