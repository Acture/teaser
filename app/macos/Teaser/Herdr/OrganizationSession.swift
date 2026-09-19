import Foundation

@MainActor
final class OrganizationSession {
	private struct NativeIntent {
		let generation: UUID
		let panelID: String
		let workspaceID: String
		let binding: OrganizationBinding
		let split: DesktopStageSplitIntent?
		let targetBinding: OrganizationBinding?
		let handle: (any ExternalWindowHandle)?
	}
	let client: OrganizationClient
	let orchestrator: DesktopStageOrchestrator
	let archiveDirectory: URL?
	private(set) var scope: OrganizationLocalScope?
	private(set) var projected: OrganizationSnapshot?
	private(set) var persistenceError: String?
	private var nativeIntent: NativeIntent?
	var onChange: (() -> Void)?
	var onProjection: (() -> Void)?

	init(orchestrator: DesktopStageOrchestrator, client: OrganizationClient = .init(), archiveDirectory: URL?) {
		self.orchestrator = orchestrator; self.client = client; self.archiveDirectory = archiveDirectory
		orchestrator.useSharedOrganization()
		orchestrator.onSharedKindChange = { [weak client] panelID, kindID in
			client?.apply([.setPanelKind(panelID.rawValue, kindID.rawValue)])
		}
		orchestrator.onSharedSplit = { [weak self] intent in self?.split(intent) }
		orchestrator.onSharedAdoption = { [weak self] panelID, handle, bundleID in
			self?.adopt(panelID: panelID, handle: handle, bundleID: bundleID) ?? false
		}
		orchestrator.onSharedSwapAllowed = { [weak self] source, target in
			guard let self,
				let sourcePanel: OrganizationPanel = self.projected?.panels.first(where: { $0.id == source.rawValue }),
				let targetPanel: OrganizationPanel = self.projected?.panels.first(where: { $0.id == target.rawValue })
			else { return false }
			return sourcePanel.binding == targetPanel.binding
		}
		orchestrator.onStageStopped = { [weak self] in self?.nativeIntent = nil }
		client.onChange = { [weak self] in
			guard let self else { return }
			if self.client.state != .ready || self.client.canApply || self.client.errorMessage != nil {
				self.nativeIntent = nil
			}
			self.onChange?()
		}
		client.onSnapshot = { [weak self] snapshot in try self?.project(snapshot) }
	}
	func connect(path: String) {
		guard save() else { return }
		orchestrator.stopStage()
		guard orchestrator.releaseRetainedLeases() else {
			orchestrator.setStatus("Reconnect paused: Stop/Release must restore retained windows first.")
			return
		}
		client.disconnect()
		scope = .init(scope: UUID(), endpoint: path)
		projected = nil
		do { try project(.empty) } catch { orchestrator.setStatus(error.localizedDescription); return }
		client.connect(path: path)
	}
	func disconnect() {
		nativeIntent = nil
		_ = save()
		client.disconnect()
		// The current scope and readable graph stay available offline; leases can
		// always be released independently of a successful server command.
	}
	func stopAndRelease() {
		orchestrator.stopStage()
		if !orchestrator.releaseRetainedLeases() { orchestrator.setStatus("Some windows could not be restored; retry Stop/Release after restoring Accessibility.") }
	}
	func setNote(_ text: String, panelID: PanelID) {
		guard let document: String = projected?.panels.first(where: { $0.id == panelID.rawValue })?.binding.document_id else { return }
		scope?.documents[document] = text
		let documentID: NotesDocumentID = .init(document)
		for panel: OrganizationPanel in projected?.panels ?? [] where panel.binding.document_id.map(NotesDocumentID.init) == documentID {
			orchestrator.setNote(text, for: .init(panel.id))
		}
		_ = save()
		onChange?()
	}
	@discardableResult
	func save() -> Bool {
		guard scope != nil else { return true }
		scope?.capture(presentation: orchestrator.presentation, layout: orchestrator.layout)
		do {
			guard let archiveDirectory else { throw HerdrError.invalid("Local Notes archive directory is unavailable") }
			try scope?.save(in: archiveDirectory)
			persistenceError = nil
			return true
		} catch {
			persistenceError = "Local Notes/layout archive could not be saved: \(error.localizedDescription)"
			orchestrator.setStatus(persistenceError)
			onChange?()
			return false
		}
	}
	private func project(_ snapshot: OrganizationSnapshot) throws {
		let previous: OrganizationSnapshot? = projected
		let presentation: WorkspacePresentation = try OrganizationProjection.project(snapshot,
			previous: previous == nil ? nil : orchestrator.presentation,
			displayID: orchestrator.displays.first?.id ?? ShowcasePreset.mainDisplayID)
		let compatible: Set<PanelID> = Set(snapshot.panels.filter { panel in
			previous?.panels.contains(where: { $0.id == panel.id && $0.binding == panel.binding }) == true
		}.map { PanelID($0.id) })
		let adoptable: Set<PanelID> = Set(snapshot.panels.filter { [.unbound, .app].contains($0.binding.type) }.map { PanelID($0.id) })
		var notes: [PanelID: String] = [:]
		for panel: OrganizationPanel in snapshot.panels {
			if let document: String = panel.binding.document_id { notes[.init(panel.id)] = scope?.documents[document] ?? "" }
		}
		try orchestrator.reconcileOrganization(presentation, retaining: compatible, adoptable: adoptable, notes: notes)
		projected = snapshot
		completeIntent(snapshot)
		onProjection?()
	}

	private func split(_ intent: DesktopStageSplitIntent) {
		guard client.canApply, nativeIntent == nil,
			let target: OrganizationPanel = projected?.panels.first(where: { $0.id == intent.target.rawValue }) else {
			orchestrator.setStatus("Split unavailable: organization is disconnected, stale, or a command is pending."); return
		}
		if intent.handle != nil && intent.bundleID == nil {
			orchestrator.setStatus("Split requires an identifiable App bundle; no Panel was created."); return
		}
		let binding: OrganizationBinding = intent.bundleID.map { .init(type: .app, bundle_id: $0) } ?? .unbound
		let id: String = UUID().uuidString.lowercased()
		let panel: OrganizationPanel = .init(id: id, workspace_id: target.workspace_id,
			title: intent.handle?.initialSnapshot.applicationName ?? "New Panel", kind: intent.handle == nil ? "generic" : "app",
			binding: binding, size_profile: .standard)
		nativeIntent = .init(generation: client.generation, panelID: id, workspaceID: target.workspace_id,
			binding: binding, split: intent, targetBinding: target.binding, handle: intent.handle)
		client.apply([.createPanel(panel)])
		if nativeIntent != nil { orchestrator.setStatus("Creating Panel on server…") }
	}

	private func adopt(panelID: PanelID, handle: any ExternalWindowHandle, bundleID: String) -> Bool {
		guard client.canApply, nativeIntent == nil,
			let panel: OrganizationPanel = projected?.panels.first(where: { $0.id == panelID.rawValue }) else {
			orchestrator.setStatus("Adoption unavailable: connect and refresh organization first."); return false
		}
		let binding: OrganizationBinding = .init(type: .app, bundle_id: bundleID)
		if panel.binding == binding { return orchestrator.adoptCommittedWindow(handle, into: panelID) }
		guard panel.binding == .unbound else {
			orchestrator.setStatus("Selected window does not match the Panel's App binding. Rebind explicitly in Organization controls.")
			return false
		}
		nativeIntent = .init(generation: client.generation, panelID: panel.id, workspaceID: panel.workspace_id,
			binding: binding, split: nil, targetBinding: nil, handle: handle)
		client.apply([.rebindPanel(panel.id, binding)])
		if nativeIntent != nil { orchestrator.setStatus("Binding App on server before adopting the selected window…") }
		return nativeIntent != nil
	}

	private func completeIntent(_ snapshot: OrganizationSnapshot) {
		guard let intent: NativeIntent = nativeIntent else { return }
		guard intent.generation == client.generation else { nativeIntent = nil; return }
		guard let panel: OrganizationPanel = snapshot.panels.first(where: { $0.id == intent.panelID }) else { return }
		guard panel.workspace_id == intent.workspaceID, panel.binding == intent.binding else {
			nativeIntent = nil
			orchestrator.setStatus("Native intent cancelled: Panel membership or binding changed."); return
		}
		nativeIntent = nil
		do {
			if let split: DesktopStageSplitIntent = intent.split {
				guard let target: OrganizationPanel = snapshot.panels.first(where: { $0.id == split.target.rawValue }),
					target.workspace_id == intent.workspaceID, target.binding == intent.targetBinding else {
					orchestrator.setStatus("Panel committed; split target changed, so its default placement was retained."); return
				}
				try orchestrator.placeCommittedPanel(.init(panel.id), target: split.target, edge: split.edge)
			}
			if let handle: any ExternalWindowHandle = intent.handle {
				_ = orchestrator.adoptCommittedWindow(handle, into: .init(panel.id))
			}
		} catch { orchestrator.setStatus("Panel committed; local placement failed: \(error.localizedDescription)") }
	}
}
