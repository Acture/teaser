import Foundation
@testable import TeaserKit

@MainActor
final class FakeTransport: HerdrTransport {
	var endpointIdentity: String? = "test-instance"
	var onFrame: ((Data) -> Void)?
	var onClose: ((Error) -> Void)?
	var sent: [Data] = []
	var closed: Bool = false
	func open(path: String) throws { closed = false }
	func send(_ data: Data) throws { sent.append(data) }
	func close() { closed = true }
	func respond(_ result: String) throws {
		struct RequestID: Decodable { let id: String }
		let id: String = try JSONDecoder().decode(RequestID.self, from: sent.last!).id
		onFrame?(Data("{\"id\":\"\(id)\",\"result\":\(result)}".utf8))
	}
	func snapshot(_ snapshot: OrganizationSnapshot) throws {
		let json: String = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
		try respond("{\"type\":\"teaser_organization_snapshot\",\"snapshot\":\(json)}")
	}
	func event(_ snapshot: OrganizationSnapshot) throws {
		let json: String = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
		onFrame?(Data("{\"event\":\"teaser.organization.updated\",\"data\":{\"type\":\"teaser_organization_updated\",\"snapshot\":\(json)}}".utf8))
	}
}

@MainActor
final class FixtureClient {
	var sockets: [FakeTransport] = []
	var identity: String = "test-instance"
	lazy var client: OrganizationClient = .init(factory: { [unowned self] in
		let socket: FakeTransport = .init(); socket.endpointIdentity = self.identity
		self.sockets.append(socket); return socket
	})
	func ready(_ snapshot: OrganizationSnapshot) throws {
		client.connect(path: "/tmp/isolated-test.sock")
		try sockets[sockets.count - 1].respond("{\"type\":\"subscription_started\"}")
		try sockets[sockets.count - 1].snapshot(snapshot)
	}
}

func fixture() throws -> OrganizationSnapshot {
	let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
	return try JSONDecoder().decode(OrganizationSnapshot.self,
		from: Data(contentsOf: root.appendingPathComponent("crates/teaser-core/tests/fixtures/organization.json")))
}

func revision(_ snapshot: OrganizationSnapshot, _ revision: UInt64) -> OrganizationSnapshot {
	.init(revision: revision, projects: snapshot.projects, workspaces: snapshot.workspaces, panels: snapshot.panels)
}

func appFixture() throws -> OrganizationSnapshot {
	var value: OrganizationSnapshot = try fixture()
	value.panels[2].binding = .init(type: .app, bundle_id: "com.example.provider\(providerPID)")
	return value
}

@MainActor
func pendingPanel(_ socket: FakeTransport) throws -> OrganizationPanel {
	struct Request: Decodable {
		struct Parameters: Decodable {
			struct Command: Decodable { let panel: OrganizationPanel }
			let commands: [Command]
		}
		let params: Parameters
	}
	return try JSONDecoder().decode(Request.self, from: socket.sent.last!).params.commands[0].panel
}

@MainActor
final class FixtureSession {
	let world: PointerDriver = .init()
	let network: FixtureClient = .init()
	let orchestrator: DesktopStageOrchestrator
	let session: OrganizationSession
	let directory: URL
	init() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaser-herdr-\(UUID().uuidString)")
		orchestrator = .init(presentation: try testPresentation(), notes: [:], service: world.service,
			clock: world.clock, pointerSource: world.pointer, identifiers: CountingIdentifierSource())
		orchestrator.setDisplays([.init(id: testDisplayID, frame: .init(x: 0, y: 0, width: 2000, height: 1000))])
		session = .init(orchestrator: orchestrator, client: network.client, archiveDirectory: directory)
	}
	func connect(_ snapshot: OrganizationSnapshot) throws {
		session.connect(path: "/tmp/isolated-test.sock")
		try network.sockets[network.sockets.count - 1].respond("{\"type\":\"subscription_started\"}")
		try network.sockets[network.sockets.count - 1].snapshot(snapshot)
	}
	func cleanup() throws {
		session.disconnect(); session.stopAndRelease()
		if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
	}
}

/// The projection needs to know which canvases are open. These cases are about
/// the server model rather than placement, so they use one canvas.
let testPlacement: WorkspacePlacement = .init(openDisplays: [testDisplayID], targetDisplay: testDisplayID)

@MainActor
func project(
	_ snapshot: OrganizationSnapshot,
	previous: WorkspacePresentation? = nil
) throws -> WorkspacePresentation {
	try OrganizationProjection.project(snapshot, previous: previous, placement: testPlacement)
}

let cases: [TestCase] = [
	.init("shared Rust fixture validates and projects all bindings") {
		let value: OrganizationSnapshot = try fixture(); try value.validate()
		try expect(value.panels[0].title == "Design 👩‍💻", "shared fixture includes joined emoji")
		let projected: WorkspacePresentation = try project(value)
		try expect(projected.panels.count == 4, "all fixture Panels")
		try expect(projected.panelKinds.definition(for: .init("custom-chart")) != nil, "custom kind retained")
	},
	.init("Rust-valid Unicode labels and format scalars remain valid") {
		var value: OrganizationSnapshot = try fixture()
		let labels: [String] = ["Design 👩‍💻", "设计笔记", "e\u{0301}", "\u{200B}", "\u{200D}", "\u{FEFF}"]
		for label: String in labels {
			value.panels[0].title = label
			try value.validate()
		}
	},
	.init("Rust whitespace-only and every Unicode Cc scalar are rejected") {
		var value: OrganizationSnapshot = try fixture()
		let whitespace: [UInt32] = Array(0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680]
			+ Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
		let controls: [UInt32] = Array(0x00...0x1F) + Array(0x7F...0x9F)
		let labels: [String] = [""] + whitespace.map { String(Unicode.Scalar($0)!) }
			+ controls.map { "before\(Unicode.Scalar($0)!)after" }
		for label: String in labels {
			value.panels[0].title = label
			do { try value.validate(); throw TestFailure.assertion("invalid Unicode label accepted") }
			catch is HerdrError {}
		}
	},
	.init("fragmented NDJSON and oversized frames fail safely") {
		var framer: NDJSONFramer = .init()
		try expect(try framer.append(Data("{\"a\":".utf8)).isEmpty, "partial frame buffered")
		try expect(try framer.append(Data("1}\n{}\n".utf8)).count == 2, "two complete frames")
		do { _ = try framer.append(Data(repeating: 65, count: NDJSONFramer.maximumFrame + 1)); throw TestFailure.assertion("oversize accepted") }
		catch is HerdrError {}
	},
	.init("ACK precedes snapshot; event before snapshot and stale apply") {
		let fixtureClient: FixtureClient = .init(); let client: OrganizationClient = fixtureClient.client
		let value: OrganizationSnapshot = try fixture()
		client.connect(path: "/tmp/isolated-test.sock")
		try expect(fixtureClient.sockets.count == 1, "no snapshot before ACK")
		try fixtureClient.sockets[0].respond("{\"type\":\"subscription_started\"}")
		try expect(fixtureClient.sockets.count == 2, "snapshot uses separate request socket")
		try fixtureClient.sockets[0].event(revision(value, 8))
		try fixtureClient.sockets[1].snapshot(value)
		try expect(client.snapshot?.revision == 8 && client.canApply, "buffered event outruns snapshot")
		client.apply([.renamePanel("panel-notes", "new")])
		try fixtureClient.sockets[0].event(revision(value, 9))
		try fixtureClient.sockets[2].snapshot(revision(value, 8))
		try expect(client.snapshot?.revision == 9, "stale apply cannot regress")
		client.disconnect()
	},
	.init("gaps resnapshot; disconnect invalidates old generation and pending write") {
		let f: FixtureClient = .init(); let value: OrganizationSnapshot = try fixture(); try f.ready(value)
		try f.sockets[0].event(revision(value, 10))
		try expect(f.client.state == .loading && f.sockets.count == 3, "gap starts resnapshot")
		try f.sockets[2].snapshot(revision(value, 10))
		f.client.apply([.deletePanel("panel-app")])
		let oldCallback: ((Data) -> Void)? = f.sockets[0].onFrame
		f.client.connect(path: "/tmp/different-test.sock")
		oldCallback?(Data("bad old data".utf8))
		try expect(f.client.state == .subscribing, "old generation ignored")
		try expect(f.sockets.last?.sent.count == 1, "reconnect sends only subscription, no replay")
		f.client.disconnect(); let count: Int = f.sockets.count
		f.client.apply([.deletePanel("panel-app")])
		try expect(f.sockets.count == count && f.client.errorMessage != nil, "offline writes refused")
	},
	.init("malformed reply, unsupported ACK, timeouts and event bounds") {
		let f: FixtureClient = .init(); f.client.connect(path: "/tmp/test.sock")
		f.sockets[0].onFrame?(Data("not json".utf8))
		try expect(!f.client.canApply, "malformed reply fails closed")
		f.client.connect(path: "/tmp/test.sock")
		try f.sockets.last!.respond("{\"type\":\"ok\"}")
		try expect(f.client.errorMessage != nil, "wrong ACK rejected")
		f.client.connect(path: "/tmp/test.sock")
		f.client.checkTimeouts(now: .now.advanced(by: .seconds(10)))
		try expect(f.client.errorMessage == HerdrError.timeout.localizedDescription, "bounded timeout")
		f.client.connect(path: "/tmp/test.sock")
		let socket: FakeTransport = f.sockets.last!
		let value: OrganizationSnapshot = try fixture()
		for _: Int in 0..<33 { try socket.event(value) }
		try expect(f.client.errorMessage?.contains("buffer") == true, "bounded event queue")
		f.client.disconnect()
	},
	.init("invalid profile rejected before native constructors") {
		var value: OrganizationSnapshot = try fixture()
		value.panels[0].size_profile = .init(name: "invalid", min_width: 0, min_height: 1,
			preferred_width: 1, preferred_height: 1, growth_weight: 1,
			preferred_aspect_ratio: .init(minimum: 2, maximum: 1))
		do { _ = try project(value); throw TestFailure.assertion("bad profile accepted") }
		catch is HerdrError {}
	},
	.init("rename preserves placement; regroup and deletion reconcile stable IDs") {
		var value: OrganizationSnapshot = try fixture()
		var old: WorkspacePresentation = try project(value)
		let canvasID: DisplayID = old.canvases.keys.first!
		let splitID: LayoutSplitID = old.canvases[canvasID]!.panelTree!.splitIDs[0]
		try old.setUserRatio(0.7, for: splitID, onCanvas: canvasID)
		value.panels[0].title = "Renamed"
		let renamed: WorkspacePresentation = try project(value, previous: old)
		try expect(renamed.canvases[canvasID]!.panelTree == old.canvases[canvasID]!.panelTree, "pixel placement survives rename")
		value.workspaces.append(.init(id: "second", project_id: value.projects[0].id, name: "Second"))
		value.panels[0].workspace_id = "second"; value.panels.removeLast()
		let next: WorkspacePresentation = try project(value, previous: renamed)
		try expect(next.workspaceID(of: .init("panel-notes")) == .init("second"), "regroup accepted")
		try expect(next.panels[.init("panel-custom")] == nil, "deleted Panel removed")
	},
	.init("server rejection remains visible and revision conflict refreshes") {
		struct RequestID: Decodable { let id: String }
		let f: FixtureClient = .init(); let value: OrganizationSnapshot = try fixture(); try f.ready(value)
		f.client.apply([.renamePanel("panel-app", "Renamed")])
		let socket: FakeTransport = f.sockets.last!
		let id: String = try JSONDecoder().decode(RequestID.self, from: socket.sent[0]).id
		socket.onFrame?(Data("{\"id\":\"\(id)\",\"error\":{\"code\":\"revision_conflict\",\"message\":\"stale\"}}".utf8))
		try expect(f.client.state == .loading, "conflict refresh")
		try expect(f.client.errorMessage?.contains("revision_conflict") == true, "conflict shown")
		try f.sockets.last!.snapshot(revision(value, 8))
		try expect(f.client.canApply, "fresh state admits new explicit commands")
		f.client.disconnect()
	},
	.init("replaced endpoint cannot mix subscription and request instances") {
		let f: FixtureClient = .init(); try f.ready(try fixture())
		f.identity = "replacement"
		f.client.apply([.deletePanel("panel-app")])
		try expect(f.client.errorMessage?.contains("replaced") == true && !f.client.canApply, "endpoint replacement detected before write")
		try expect(f.sockets.last!.sent.isEmpty, "no write sent to replacement")
	},
	.init("same-connection compatible leases survive rename and regroup; rebind and delete release") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try appFixture(); try f.connect(value)
		try expect(f.world.pointer.startCount == 0 && f.world.service.promptCount == 0, "connect cannot engage desktop")
		let window: FakeWindow = f.world.addWindow()
		try f.orchestrator.startStage()
		try expect(f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-app")), "explicit fake adoption")
		value.panels[2].title = "Renamed"
		value.workspaces.append(.init(id: "second", project_id: value.projects[0].id, name: "Second"))
		value.panels[2].workspace_id = "second"
		try f.network.sockets[0].event(revision(value, 8))
		try expect(f.orchestrator.panelAssignments[.init("panel-app")] == window.identity, "compatible lease retained")
		try expect(f.world.log.bindCount(for: window.identity) == 1, "no rebind on metadata update")
		value.panels[2].binding = .unbound
		try f.network.sockets[0].event(revision(value, 9))
		try expect(!f.orchestrator.hasRetainedLeases, "changed binding releases exact lease")
		value.panels[2].binding = .init(type: .app, bundle_id: "com.example.provider\(providerPID)")
		try f.network.sockets[0].event(revision(value, 10))
		try expect(f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-app")), "readopt explicit")
		value.panels.removeAll { $0.id == "panel-app" }
		try f.network.sockets[0].event(revision(value, 11))
		try expect(!f.orchestrator.hasRetainedLeases, "deletion releases")
		try f.cleanup()
	},
	.init("same-path reconnect clears leases, local scope and caches; offline Stop releases") {
		let f: FixtureSession = try .init(); let value: OrganizationSnapshot = try appFixture(); try f.connect(value)
		let firstScope: UUID? = f.session.scope?.scope
		f.session.setNote("old body", panelID: .init("panel-notes"))
		let window: FakeWindow = f.world.addWindow(); try f.orchestrator.startStage()
		try expect(f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-app")), "fake adopted")
		f.session.disconnect(); f.session.stopAndRelease()
		try expect(!f.orchestrator.hasRetainedLeases, "offline release remains available")
		try f.connect(value)
		try expect(f.session.scope?.scope != firstScope, "new same-path connection scope")
		try expect(f.orchestrator.notes[.init("panel-notes")] == "", "old body never transplanted")
		try expect(!f.orchestrator.hasRetainedLeases && f.orchestrator.panelAssignments.isEmpty, "no lease transplant")
		let archive: URL = f.directory.appendingPathComponent("\(firstScope!.uuidString).json")
		let saved: OrganizationLocalScope = try JSONDecoder().decode(OrganizationLocalScope.self, from: Data(contentsOf: archive))
		try expect(saved.documents["document-native"] == "old body", "previous body recoverable")
		try f.cleanup()
	},
	.init("Notes are keyed by document, not Panel; rebinding never copies text") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture()
		value.panels[3].binding = .init(type: .notes, document_id: "document-native")
		try f.connect(value)
		f.session.setNote("shared body", panelID: .init("panel-notes"))
		try expect(f.orchestrator.notes[.init("panel-custom")] == "shared body", "same document shows same local body")
		value.panels[0].binding = .init(type: .notes, document_id: "different-document")
		try f.network.sockets[0].event(revision(value, 8))
		try expect(f.orchestrator.notes[.init("panel-notes")] == "", "new binding empty")
		try expect(f.orchestrator.notes[.init("panel-custom")] == "shared body", "old document retained")
		try expect(f.session.scope?.documents["document-native"] == "shared body", "archive retains unreferenced documents")
		try f.cleanup()
	},
	.init("UTF-8-distinct canonically equivalent Notes IDs remain independent through sharing and rebind") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture()
		let composed: String = "\u{00E9}"
		let decomposed: String = "e\u{0301}"
		try expect(composed == decomposed && NotesDocumentID(composed) != NotesDocumentID(decomposed), "fixture distinguishes byte identity from Swift equality")
		value.panels[0].binding = .init(type: .notes, document_id: composed)
		value.panels[3].binding = .init(type: .notes, document_id: decomposed)
		try expect(value.panels[0].binding != value.panels[3].binding, "binding comparison preserves byte identity")
		try f.connect(value)
		f.session.setNote("composed body", panelID: .init("panel-notes"))
		try expect(f.orchestrator.notes[.init("panel-custom")] == "", "editing NFC does not propagate to NFD")
		f.session.setNote("decomposed body", panelID: .init("panel-custom"))
		try expect(f.orchestrator.notes[.init("panel-notes")] == "composed body", "editing NFD does not overwrite NFC")
		let archive: URL = f.directory.appendingPathComponent("\(f.session.scope!.scope.uuidString).json")
		let saved: OrganizationLocalScope = try JSONDecoder().decode(OrganizationLocalScope.self, from: Data(contentsOf: archive))
		try expect(saved.documents[composed] == "composed body" && saved.documents[decomposed] == "decomposed body", "archive roundtrip preserves both byte-distinct IDs")
		value.panels[0].binding = .init(type: .notes, document_id: decomposed)
		try f.network.sockets[0].event(revision(value, 8))
		try expect(f.orchestrator.notes[.init("panel-notes")] == "decomposed body", "rebind selects exact new resource")
		f.session.setNote("shared NFD body", panelID: .init("panel-notes"))
		try expect(f.orchestrator.notes[.init("panel-custom")] == "shared NFD body", "byte-identical references share edits")
		try expect(f.session.scope?.documents[composed] == "composed body", "unreferenced NFC body remains recoverable")
		try f.cleanup()
	},
	.init("guards protect real mutation entrypoints and terminal/native boundary") {
		let f: FixtureSession = try .init(); try f.connect(try fixture())
		let before: WorkspacePresentation = f.orchestrator.presentation
		f.orchestrator.resetToBlankCanvas()
		f.orchestrator.registerPanelKind(.init(id: .init("custom-other"), displayName: "Other", defaultProfile: PanelKindDefinition.app.defaultProfile))
		f.orchestrator.undoLastLayoutChange()
		try expect(f.orchestrator.presentation == before, "local reset/kind registration/undo refused")
		f.orchestrator.setPanelKind(.notes, panelID: .init("panel-app"))
		try expect(f.network.sockets.count == 3 && f.orchestrator.presentation == before, "kind routes to server without optimistic mutation")
		try f.orchestrator.startStage()
		f.orchestrator.setVirtualPanel(.init("panel-app"))
		f.orchestrator.perform(.splitPanel)
		try expect(f.orchestrator.presentation.workspaces.count == before.workspaces.count
			&& f.orchestrator.presentation.panels.count == 4, "split cannot invent local Panel")
		let window: FakeWindow = f.world.addWindow()
		try expect(!f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-cli")), "terminal metadata cannot acquire native lease")
		try f.cleanup()
	},
	.init("archive stores preferences and documents only; write failures surface") {
		let f: FixtureSession = try .init(); try f.connect(try fixture())
		f.session.setNote("recoverable", panelID: .init("panel-notes"))
		let url: URL = f.directory.appendingPathComponent("\(f.session.scope!.scope.uuidString).json")
		let encoded: String = String(decoding: try Data(contentsOf: url), as: UTF8.self)
		try expect(!encoded.contains("\"panels\"") && !encoded.contains("\"workspaces\"") && !encoded.contains("\"binding\""), "no authoritative objects persisted")
		let bad: URL = f.directory.appendingPathComponent("file-instead-of-directory")
		try Data().write(to: bad)
		let session: OrganizationSession = .init(orchestrator: f.orchestrator, client: f.network.client, archiveDirectory: bad)
		session.connect(path: "/tmp/test.sock")
		try expect(!session.save() && session.persistenceError != nil, "persistence failure visible")
		session.disconnect(); try f.cleanup()
	},
	.init("Ctrl-D commits creation before local split placement") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture(); try f.connect(value)
		try expect(f.orchestrator.layout?.panelFrames.count == 4, "connect previews layout without stage")
		try f.orchestrator.startStage(); f.orchestrator.setVirtualPanel(.init("panel-notes"))
		f.orchestrator.perform(.splitPanel)
		try expect(f.orchestrator.presentation.panels.count == 4, "no optimistic local membership")
		let panel: OrganizationPanel = try pendingPanel(f.network.sockets.last!)
		value.panels.append(panel)
		try f.network.sockets.last!.snapshot(revision(value, 8))
		try expect(f.orchestrator.presentation.virtualFocus.panelID == .init(panel.id), "committed split focused")
		try expect(f.orchestrator.presentation.panels.count == 5, "authoritative new Panel appears")
		try f.cleanup()
	},
	.init("drag-edge creation waits for commit before exact-window adoption") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture(); try f.connect(value)
		try f.orchestrator.startStage()
		let window: FakeWindow = f.world.addWindow()
		let frame: CGRect = nsRect(f.orchestrator.layout!.panelFrames[.init("panel-notes")]!)
		let point: CGPoint = .init(x: frame.maxX - 3, y: frame.midY)
		f.world.press(window); f.world.dragWindow(window, to: point); f.world.releasePointer(at: point)
		try expect(!f.orchestrator.hasRetainedLeases, "edge does not lease before server commit")
		let panel: OrganizationPanel = try pendingPanel(f.network.sockets.last!)
		try expect(panel.binding.bundle_id == "com.example.provider\(providerPID)", "only provider reference sent")
		value.panels.append(panel)
		try f.network.sockets.last!.snapshot(revision(value, 8))
		try expect(f.orchestrator.panelAssignments[.init(panel.id)] == window.identity, "committed edge adopts exact handle")
		try f.cleanup()
	},
	.init("unbound adoption commits App reference first; incompatible App rejected") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture(); try f.connect(value)
		try f.orchestrator.startStage(); let window: FakeWindow = f.world.addWindow()
		try expect(!f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-app")), "mismatched App rejected")
		try expect(f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-custom")), "unbound adoption command accepted")
		try expect(!f.orchestrator.hasRetainedLeases, "no lease before rebind commit")
		value.panels[3].binding = .init(type: .app, bundle_id: "com.example.provider\(providerPID)")
		try f.network.sockets.last!.snapshot(revision(value, 8))
		try expect(f.orchestrator.panelAssignments[.init("panel-custom")] == window.identity, "rebind followed by exact lease")
		try f.cleanup()
	},
	.init("disconnect and late commit discard native split intent without replay") {
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture(); try f.connect(value)
		try f.orchestrator.startStage(); f.orchestrator.setVirtualPanel(.init("panel-notes"))
		f.orchestrator.perform(.splitPanel)
		let socket: FakeTransport = f.network.sockets.last!
		let old: ((Data) -> Void)? = socket.onFrame
		let panel: OrganizationPanel = try pendingPanel(socket)
		f.session.disconnect()
		old?(Data("malformed late response".utf8))
		value.panels.append(panel)
		try f.connect(revision(value, 8))
		try expect(f.orchestrator.presentation.virtualFocus.panelID != .init(panel.id), "reconnect does not replay old placement/focus intent")
		try expect(!f.orchestrator.hasRetainedLeases, "reconnect does not replay old native adoption")
		try f.cleanup()
	},
	.init("rejected split does not mutate graph and stale commit cannot adopt") {
		struct RequestID: Decodable { let id: String }
		let f: FixtureSession = try .init(); var value: OrganizationSnapshot = try fixture(); try f.connect(value)
		try f.orchestrator.startStage(); f.orchestrator.setVirtualPanel(.init("panel-notes"))
		f.orchestrator.perform(.splitPanel)
		let socket: FakeTransport = f.network.sockets.last!
		let panel: OrganizationPanel = try pendingPanel(socket)
		let id: String = try JSONDecoder().decode(RequestID.self, from: socket.sent[0]).id
		socket.onFrame?(Data("{\"id\":\"\(id)\",\"error\":{\"code\":\"invalid_value\",\"message\":\"rejected\"}}".utf8))
		try expect(f.orchestrator.presentation.panels.count == 4, "rejected split leaves graph unchanged")
		value.panels.append(panel)
		try f.network.sockets[0].event(revision(value, 8))
		try expect(f.orchestrator.presentation.virtualFocus.panelID != .init(panel.id), "cancelled intent never reactivates on later snapshot")
		try f.cleanup()
	},
	.init("initial buffered revision gaps require a fresh snapshot") {
		let f: FixtureClient = .init(); let value: OrganizationSnapshot = try fixture()
		f.client.connect(path: "/tmp/test.sock")
		try f.sockets[0].respond("{\"type\":\"subscription_started\"}")
		try f.sockets[0].event(revision(value, 10))
		try f.sockets[1].snapshot(value)
		try expect(f.client.state == .loading && f.sockets.count == 3, "buffered gap requires resnapshot")
		try f.sockets[2].snapshot(revision(value, 10))
		try expect(f.client.state == .ready && f.client.snapshot?.revision == 10, "gap recovered")
		f.client.disconnect()
	},
	.init("one pending mutation is bounded and timeout never replays it") {
		let f: FixtureClient = .init(); try f.ready(try fixture())
		f.client.apply([.deletePanel("panel-app")])
		for _: Int in 0..<20 { f.client.apply([.deletePanel("panel-app")]) }
		try expect(f.sockets.count == 3, "only one write may be pending")
		f.client.checkTimeouts(now: .now.advanced(by: .seconds(10)))
		try expect(f.sockets[2].closed && !f.client.canApply, "timeout disconnects uncertain mutation")
		f.client.connect(path: "/tmp/test.sock")
		try expect(f.sockets.count == 4, "reconnect only subscribes")
		f.client.disconnect()
	},
	.init("failed lease restoration blocks endpoint switch until explicit release succeeds") {
		let f: FixtureSession = try .init(); let value: OrganizationSnapshot = try appFixture(); try f.connect(value)
		try f.orchestrator.startStage(); let window: FakeWindow = f.world.addWindow()
		try expect(f.orchestrator.adoptWindow(identity: window.identity, into: .init("panel-app")), "adopt")
		let scope: UUID? = f.session.scope?.scope
		window.refusesRelease = true
		f.session.connect(path: "/tmp/replacement.sock")
		try expect(f.session.scope?.scope == scope && f.network.sockets.count == 2, "endpoint switch blocked before scope admission")
		try expect(f.orchestrator.hasRetainedLeases, "failed release retained for retry")
		f.session.disconnect(); window.refusesRelease = false; f.session.stopAndRelease()
		try expect(!f.orchestrator.hasRetainedLeases, "offline release retries successfully")
		try f.cleanup()
	},
]

var failures: [String] = []
for test: TestCase in cases {
	do { try test.run() } catch { failures.append("\(test.name): \(error)") }
}
do { try await transportCase() } catch { failures.append("actual Unix transport: \(error)") }
if !failures.isEmpty {
	for failure: String in failures { print("FAIL: \(failure)") }
	exit(1)
}
print("Teaser Herdr regression passed: \(cases.count + 1) cases (isolated in-process Unix peer; no desktop, Herdr server, or PTY)")
