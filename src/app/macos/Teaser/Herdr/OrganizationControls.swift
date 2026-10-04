import AppKit
import SwiftUI

@MainActor
final class OrganizationControlsModel: ObservableObject {
	let session: OrganizationSession
	@Published var change: UInt64 = 0
	let startStage: () -> Void
	let adoptWindow: () -> Void
	init(session: OrganizationSession, startStage: @escaping () -> Void, adoptWindow: @escaping () -> Void) {
		self.session = session; self.startStage = startStage; self.adoptWindow = adoptWindow
	}
	func refresh() { change &+= 1 }
	func apply(_ commands: [OrganizationCommand]) { session.client.apply(commands) }
	func newID() -> String { UUID().uuidString.lowercased() }
}

@MainActor
final class OrganizationControls {
	let model: OrganizationControlsModel
	private var window: NSWindow?
	init(model: OrganizationControlsModel) { self.model = model }
	func show() {
		if window == nil {
			let created: NSWindow = .init(contentRect: .init(x: 120, y: 120, width: 720, height: 780),
				styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
			created.title = "Teaser — Connection & Organization"
			created.isReleasedWhenClosed = false
			created.contentView = NSHostingView(rootView: OrganizationControlsView(model: model))
			window = created
		}
		window?.makeKeyAndOrderFront(nil)
	}
	func close() { window?.orderOut(nil) }
}

@MainActor
private struct OrganizationControlsView: View {
	@ObservedObject var model: OrganizationControlsModel
	@State private var endpoint: String = ""
	@State private var projectID: String = ""
	@State private var workspaceID: String = ""
	@State private var panelID: String = ""
	@State private var name: String = "New context"
	@State private var kind: String = "app"
	@State private var binding: OrganizationBinding.Kind = .unbound
	@State private var reference: String = ""
	private var snapshot: OrganizationSnapshot { model.session.client.snapshot ?? .empty }
	private var selectedPanel: OrganizationPanel? { snapshot.panels.first { $0.id == panelID } }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				Text("Connect to your explicitly selected Herdr JSON socket").font(.headline)
				TextField("Absolute Unix socket path", text: $endpoint)
				HStack {
					Button("Connect / Reconnect") { model.session.connect(path: endpoint) }
						.disabled(endpoint.isEmpty)
					Button("Disconnect") { model.session.disconnect() }
				}
				Text(status).textSelection(.enabled)
				if let error: String = model.session.client.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
				if let error: String = model.session.persistenceError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
				HStack {
					Button("Start / Stop Stage", action: model.startStage)
					Button("Adopt Window…", action: model.adoptWindow)
					Button("Stop / Release") { model.session.stopAndRelease() }
				}
				Text("Stage and Adopt are separate desktop gestures. Terminal bindings are metadata only; this client does not render terminals.")
					.font(.caption).foregroundStyle(.secondary)
				Divider()
				VStack(alignment: .leading, spacing: 10) {
					TextField("Name / title for create or rename", text: $name)
					Button("Create first context (Project + Workspace + Panel)") { createContext() }
					Picker("Project", selection: $projectID) {
						Text("Select Project").tag("")
						ForEach(snapshot.projects, id: \.id) { Text("\($0.name) · \($0.id)").tag($0.id) }
					}
					HStack {
						Button("New Project") { model.apply([.createProject(.init(id: model.newID(), name: name))]) }
						Button("Rename Project") { model.apply([.renameProject(projectID, name)]) }.disabled(projectID.isEmpty)
						Button("Delete Project") { model.apply([.deleteProject(projectID)]) }.disabled(projectID.isEmpty)
					}
					Picker("Workspace / regroup destination", selection: $workspaceID) {
						Text("Select Workspace").tag("")
						ForEach(snapshot.workspaces, id: \.id) { Text("\($0.name) · \($0.id)").tag($0.id) }
					}
					HStack {
						Button("New Workspace") { model.apply([.createWorkspace(.init(id: model.newID(), project_id: projectID, name: name))]) }.disabled(projectID.isEmpty)
						Button("Rename Workspace") { model.apply([.renameWorkspace(workspaceID, name)]) }.disabled(workspaceID.isEmpty)
						Button("Delete Workspace") { model.apply([.deleteWorkspace(workspaceID)]) }.disabled(workspaceID.isEmpty)
					}
					Picker("Panel", selection: $panelID) {
						Text("Select Panel").tag("")
						ForEach(snapshot.panels, id: \.id) { Text("\($0.title) · \($0.id)").tag($0.id) }
					}
					HStack {
						Button("New Panel") { model.apply([.createPanel(newPanel(workspace: workspaceID))]) }.disabled(workspaceID.isEmpty)
						Button("Rename Panel") { model.apply([.renamePanel(panelID, name)]) }.disabled(panelID.isEmpty)
						Button("Delete Panel") { model.apply([.deletePanel(panelID)]) }.disabled(panelID.isEmpty)
						Button("Regroup") { model.apply([.regroupPanel(panelID, workspaceID)]) }.disabled(panelID.isEmpty || workspaceID.isEmpty)
					}
					if let panel: OrganizationPanel = selectedPanel {
						Text("Workspace: \(panel.workspace_id) · Kind: \(panel.kind)\n\(panel.binding.description)").font(.caption).textSelection(.enabled)
					}
					HStack {
						TextField("Kind (cli, app, notes, or a custom kind)", text: $kind)
						Button("Set kind") { model.apply([.setPanelKind(panelID, kind)]) }.disabled(panelID.isEmpty)
					}
					Picker("Content binding", selection: $binding) {
						Text("Unbound").tag(OrganizationBinding.Kind.unbound)
						Text("App bundle ID").tag(OrganizationBinding.Kind.app)
						Text("Notes document ID (local text)").tag(OrganizationBinding.Kind.notes)
						Text("Existing terminal pane ID (metadata)").tag(OrganizationBinding.Kind.terminal)
					}
					TextField("Binding reference", text: $reference).disabled(binding == .unbound)
					Button("Rebind Panel") { model.apply([.rebindPanel(panelID, selectedBinding)]) }.disabled(panelID.isEmpty)
					Text("Delete parents after deleting their children. Create and rebind never start terminals or applications.").font(.caption)
				}.disabled(!model.session.client.canApply)
				Divider()
				Text("Notes text and layout preferences belong to this Mac and connection scope. Reconnecting creates a fresh scope, even at the same socket path. Older archives and legacy presentation.json remain recoverable.").font(.caption)
				if let scope: OrganizationLocalScope = model.session.scope {
					Text("Scope: \(scope.scope.uuidString)\nEndpoint: \(scope.endpoint)").font(.caption).textSelection(.enabled)
				}
				if let directory: URL = model.session.archiveDirectory {
					Text(directory.path).font(.caption).textSelection(.enabled)
					Button("Reveal local Notes / layout archives") { NSWorkspace.shared.open(directory) }
				}
			}.padding(20)
		}.frame(minWidth: 650, minHeight: 600)
	}
	private var status: String {
		switch model.session.client.state {
		case .disconnected: "Disconnected — organization edits disabled"
		case .subscribing: "Connecting and subscribing…"
		case .loading: "Refreshing organization…"
		case .ready: "Connected · revision \(snapshot.revision)"
		case .failed(let message): "Connection unavailable: \(message)"
		}
	}
	private var selectedBinding: OrganizationBinding {
		switch binding {
		case .unbound: .unbound
		case .app: .init(type: .app, bundle_id: reference)
		case .notes: .init(type: .notes, document_id: reference)
		case .terminal: .init(type: .terminal, pane_id: reference)
		}
	}
	private func newPanel(workspace: String) -> OrganizationPanel {
		.init(id: model.newID(), workspace_id: workspace, title: name, kind: kind,
			binding: selectedBinding, size_profile: .standard)
	}
	private func createContext() {
		let project: String = model.newID()
		let workspace: String = model.newID()
		model.apply([.createProject(.init(id: project, name: name)),
			.createWorkspace(.init(id: workspace, project_id: project, name: name)),
			.createPanel(newPanel(workspace: workspace))])
	}
}
