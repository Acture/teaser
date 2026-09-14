import AppKit
import SplitView
import SwiftUI

/// SplitView's primary vertical child is top; Teaser's first child is bottom.
enum LayoutEditorCoordinates {
	static func primaryFraction(firstRatio: Double, axis: LayoutAxis) -> CGFloat {
		CGFloat(axis == .horizontal ? firstRatio : 1 - firstRatio)
	}

	static func firstRatio(primaryFraction: CGFloat, axis: LayoutAxis) -> Double? {
		guard primaryFraction.isFinite, primaryFraction > 0, primaryFraction < 1 else { return nil }
		return Double(axis == .horizontal ? primaryFraction : 1 - primaryFraction)
	}
}

/// A projection of the orchestrator, never a separate layout/persistence owner.
@MainActor
final class DesktopStageLayoutEditorModel: ObservableObject {
	struct ScopeChoice: Identifiable {
		let id: LayoutScope
		let title: String
	}

	private(set) var presentation: WorkspacePresentation
	private(set) var active: Bool = false
	private(set) var assignedPanels: Set<PanelID> = []
	@Published private(set) var revision: UInt = 0
	private let onResize: @MainActor (LayoutSplitReference, Double) -> Void
	let onUndo: @MainActor () -> Void
	var canEdit: Bool { active || assignedPanels.isEmpty }

	init(
		presentation: WorkspacePresentation,
		onResize: @escaping @MainActor (LayoutSplitReference, Double) -> Void,
		onUndo: @escaping @MainActor () -> Void
	) {
		self.presentation = presentation
		self.onResize = onResize
		self.onUndo = onUndo
	}

	var scopes: [ScopeChoice] {
		presentation.displayLayouts.keys.sorted { $0.rawValue < $1.rawValue }.enumerated().map {
			.init(id: .display($0.element), title: "Display \($0.offset + 1)")
		} + presentation.workspaces.values.sorted { $0.id.rawValue < $1.id.rawValue }.map {
			.init(id: .workspace($0.id), title: $0.title)
		}
	}

	func update(presentation: WorkspacePresentation, active: Bool, assignedPanels: Set<PanelID>) {
		guard self.presentation != presentation || self.active != active
			|| self.assignedPanels != assignedPanels else { return }
		self.presentation = presentation
		self.active = active
		self.assignedPanels = assignedPanels
		revision &+= 1
	}

	func fractionHolder(
		for reference: LayoutSplitReference, axis: LayoutAxis, preference: SplitPreference
	) -> FractionHolder {
		let generation: UInt = revision
		return .init(LayoutEditorCoordinates.primaryFraction(firstRatio: preference.renderedRatio, axis: axis), setter: {
			[weak self] fraction in
			guard let self, self.revision == generation, self.canEdit else { return }
			if let ratio: Double = LayoutEditorCoordinates.firstRatio(primaryFraction: fraction, axis: axis) {
				// Upstream writes the holder at drag end: one actual solve/apply, not
				// an AX request for every mouse movement. The host refreshes our state.
				self.onResize(reference, ratio)
			}
			// Recreate upstream gesture state from the committed model even when
			// the transaction was rejected or clamped to exactly the previous ratio.
			self.revision &+= 1
		})
	}
}

@MainActor
private struct LayoutEditorTree<Leaf, Content: View>: View where Leaf: Codable & Hashable & Sendable {
	let tree: LayoutTree<Leaf>
	let scope: LayoutScope
	let model: DesktopStageLayoutEditorModel
	let content: (Leaf) -> Content

	var body: some View { render(tree) }

	// Recursive layout trees require type erasure at this boundary.
	private func render(_ node: LayoutTree<Leaf>) -> AnyView {
		switch node {
		case .leaf(let leaf):
			AnyView(content(leaf))
		case .split(let id, let axis, let preference, let first, let second):
			AnyView(
				Split {
					render(axis == .horizontal ? first : second)
				} secondary: {
					render(axis == .horizontal ? second : first)
				}
				.layout(LayoutHolder(axis == .horizontal ? .horizontal : .vertical))
				.fraction(model.fractionHolder(for: .init(scope: scope, splitID: id),
					axis: axis, preference: preference))
				// These are editor handle limits, not provider-window size claims.
				.constraints(minPFraction: 0.05, minSFraction: 0.05)
				.styling(color: .secondary.opacity(0.35), visibleThickness: 6, invisibleThickness: 10)
			)
		}
	}
}

@MainActor
private struct DesktopStageLayoutEditorView: View {
	@ObservedObject var model: DesktopStageLayoutEditorModel
	@State private var selection: LayoutScope?

	var body: some View {
		let selected: LayoutScope? = model.scopes.first { $0.id == selection }?.id ?? model.scopes.first?.id
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Picker("Layout", selection: Binding(get: { selected }, set: { selection = $0 })) {
					ForEach(model.scopes) { scope in Text(scope.title).tag(Optional(scope.id)) }
				}
				.frame(maxWidth: 340)
				Spacer()
				Button("Undo Layout Change", action: model.onUndo)
			}
			Text(!model.canEdit ? "Some windows could not be released. Close Teaser to retry release before editing."
				: model.active
				? "Drag a divider; releasing it resizes the connected windows."
				: "Layout stopped. Edit saved proportions without moving any windows.")
				.font(.callout).foregroundStyle(.secondary)
			Group {
				switch selected {
				case .display(let id):
					if case .focused(let workspaceID) = model.presentation.mode,
						model.presentation.workspaces[workspaceID]?.displayAffinity == id
					{
						workspace(workspaceID)
					} else if case .focused = model.presentation.mode {
						Text("No workspace on this display in Focus mode.")
					} else if let tree: LayoutTree<WorkspaceID> = model.presentation.displayLayouts[id]?.workspaceTree {
						LayoutEditorTree(tree: tree, scope: .display(id), model: model, content: workspace)
					}
				case .workspace(let id): workspace(id)
				case nil: Text("No layout available")
				}
			}
			.id(model.revision)
			.disabled(!model.canEdit)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Text("Layout map · labels show panel assignments, not embedded app contents.")
				.font(.caption).foregroundStyle(.secondary)
		}
		.padding(16)
	}

	@ViewBuilder private func workspace(_ id: WorkspaceID) -> some View {
		if let workspace: WorkspaceDescriptor = model.presentation.workspaces[id] {
			VStack(alignment: .leading, spacing: 4) {
				Text(workspace.title).font(.headline).lineLimit(1)
				LayoutEditorTree(tree: workspace.panelTree, scope: .workspace(id), model: model) { panelID in
					VStack(alignment: .leading, spacing: 4) {
						Text(workspace.panels[panelID]?.title ?? panelID.rawValue)
							.font(.callout).lineLimit(2)
						Text(panelStatus(panelID, workspace: workspace))
							.font(.caption).foregroundStyle(.secondary).lineLimit(1)
					}
					.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
					.background(Color(nsColor: .textBackgroundColor)).clipped()
				}
			}
			.padding(6).background(Color(nsColor: .controlBackgroundColor)).clipped()
		}
	}

	private func panelStatus(_ id: PanelID, workspace: WorkspaceDescriptor) -> String {
		if model.assignedPanels.contains(id) { return "Connected window" }
		if workspace.panels[id]?.nativeContent == .notes { return "Teaser Notes" }
		return "Empty panel"
	}
}

/// Ordinary, opt-in window; never an overlay or an input shield on the desktop.
@MainActor
final class DesktopStageLayoutEditorWindow {
	let window: NSWindow

	init(model: DesktopStageLayoutEditorModel) {
		window = .init(contentRect: .init(x: 0, y: 0, width: 900, height: 600),
			styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
		window.title = "Teaser — Layout Editor"
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.tabbingMode = .disallowed
		window.minSize = .init(width: 640, height: 420)
		window.contentView = NSHostingView(rootView: DesktopStageLayoutEditorView(model: model))
		window.center()
	}

	func show() {
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	func close() { window.orderOut(nil) }
}
