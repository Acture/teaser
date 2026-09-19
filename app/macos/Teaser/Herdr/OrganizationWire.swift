import Foundation

enum HerdrError: Error, LocalizedError, Equatable {
	case invalid(String)
	case remote(String, String)
	case disconnected
	case timeout
	var errorDescription: String? {
		switch self {
		case .invalid(let message): message
		case .remote(let code, let message): "\(code): \(message)"
		case .disconnected: "Herdr disconnected. Pending commands were not replayed."
		case .timeout: "Herdr request timed out. Its outcome may be unknown; reconnect to refresh."
		}
	}
}

struct OrganizationProject: Codable, Equatable, Sendable {
	let id: String
	var name: String
}
struct OrganizationTask: Codable, Equatable, Sendable {
	let provider: String
	let id: String
}
struct OrganizationWorkspace: Codable, Equatable, Sendable {
	let id: String
	let project_id: String
	var name: String
	var task: OrganizationTask?
}
struct OrganizationBinding: Codable, Equatable, Sendable {
	enum Kind: String, Codable, Sendable { case unbound, terminal, app, notes }
	let type: Kind
	var pane_id: String?
	var bundle_id: String?
	var document_id: String?
	static let unbound: Self = .init(type: .unbound)
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.type == rhs.type && lhs.pane_id == rhs.pane_id && lhs.bundle_id == rhs.bundle_id
			&& lhs.document_id.map(NotesDocumentID.init) == rhs.document_id.map(NotesDocumentID.init)
	}
	var description: String {
		switch type {
		case .unbound: "Unbound"
		case .terminal: "Terminal \(pane_id ?? "") — metadata only, not rendered"
		case .app: "App \(bundle_id ?? "") — adopt an exact window separately"
		case .notes: "Notes \(document_id ?? "") — local to this connection scope"
		}
	}
}
struct OrganizationProfile: Codable, Equatable, Sendable {
	struct Aspect: Codable, Equatable, Sendable { let minimum: Double; let maximum: Double }
	let name: String
	let min_width: UInt32
	let min_height: UInt32
	let preferred_width: UInt32
	let preferred_height: UInt32
	let growth_weight: Double
	let preferred_aspect_ratio: Aspect
	static let standard: Self = .init(name: "native", min_width: 320, min_height: 220,
		preferred_width: 640, preferred_height: 440, growth_weight: 1,
		preferred_aspect_ratio: .init(minimum: 0.7, maximum: 2.8))
	func validate() throws {
		guard min_width > 0, min_height > 0,
			preferred_width >= min_width, preferred_height >= min_height,
			preferred_width <= 1_000_000, preferred_height <= 1_000_000,
			growth_weight.isFinite, growth_weight > 0, growth_weight <= 1_000_000,
			preferred_aspect_ratio.minimum.isFinite, preferred_aspect_ratio.maximum.isFinite,
			preferred_aspect_ratio.minimum > 0,
			preferred_aspect_ratio.maximum >= preferred_aspect_ratio.minimum
		else { throw HerdrError.invalid("Invalid server size profile") }
	}
	func native() throws -> LayoutProfile {
		try validate()
		return .init(minimumSize: .init(width: Double(min_width), height: Double(min_height)),
			preferredAspectRatio: .init(preferred_aspect_ratio.minimum, preferred_aspect_ratio.maximum),
			growthWeight: growth_weight)
	}
}
struct OrganizationPanel: Codable, Equatable, Sendable {
	let id: String
	var workspace_id: String
	var title: String
	var kind: String
	var binding: OrganizationBinding
	var size_profile: OrganizationProfile
}
struct OrganizationSnapshot: Codable, Equatable, Sendable {
	let revision: UInt64
	var projects: [OrganizationProject]
	var workspaces: [OrganizationWorkspace]
	var panels: [OrganizationPanel]
	static let empty: Self = .init(revision: 0, projects: [], workspaces: [], panels: [])
	func validate() throws {
		guard projects.count + workspaces.count + panels.count <= 4096 else {
			throw HerdrError.invalid("Organization exceeds object limit")
		}
		var ids: Set<String> = []
		for id: String in projects.map(\.id) + workspaces.map(\.id) + panels.map(\.id) {
			guard !id.isEmpty, id.utf8.count <= 128,
				id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
					|| (97...122).contains($0) || [45, 95, 46, 58].contains($0) }),
				ids.insert(id).inserted else { throw HerdrError.invalid("Invalid or duplicate organization ID") }
		}
		let projectIDs: Set<String> = Set(projects.map(\.id))
		let workspaceIDs: Set<String> = Set(workspaces.map(\.id))
		for workspace: OrganizationWorkspace in workspaces {
			guard projectIDs.contains(workspace.project_id) else { throw HerdrError.invalid("Missing Project") }
		}
		for panel: OrganizationPanel in panels {
			guard workspaceIDs.contains(panel.workspace_id) else { throw HerdrError.invalid("Missing Workspace") }
			try panel.size_profile.validate()
			let binding: OrganizationBinding = panel.binding
			let values: [String?] = [binding.pane_id, binding.bundle_id, binding.document_id]
			let required: String? = switch binding.type {
			case .unbound: nil
			case .terminal: binding.pane_id
			case .app: binding.bundle_id
			case .notes: binding.document_id
			}
			guard values.compactMap({ $0 }).count == (binding.type == .unbound ? 0 : 1),
				binding.type == .unbound || required?.isEmpty == false
			else { throw HerdrError.invalid("Malformed content binding") }
		}
		let labels: [String] = projects.map(\.name) + workspaces.map(\.name)
			+ panels.flatMap { [$0.title, $0.kind, $0.size_profile.name] }
		let references: [String] = workspaces.flatMap { $0.task.map { [$0.provider, $0.id] } ?? [] }
			+ panels.flatMap { [$0.binding.pane_id, $0.binding.bundle_id, $0.binding.document_id].compactMap { $0 } }
		for label: String in labels + references {
			// Match Rust str::trim / char::is_control: Unicode White_Space and
			// category Cc. Foundation character sets also include format scalars.
			guard label.unicodeScalars.contains(where: { !$0.properties.isWhitespace }),
				label.utf8.count <= 4096,
				!label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
			else { throw HerdrError.invalid("Invalid organization label") }
		}
	}
}

/// Typed command payloads use the server's atomic, ordered batch boundary.
enum OrganizationCommand: Encodable, Sendable {
	case createProject(OrganizationProject), renameProject(String, String), deleteProject(String)
	case createWorkspace(OrganizationWorkspace), renameWorkspace(String, String), deleteWorkspace(String)
	case createPanel(OrganizationPanel), renamePanel(String, String), deletePanel(String)
	case regroupPanel(String, String), rebindPanel(String, OrganizationBinding), setPanelKind(String, String)
	case setPanelSizeProfile(String, OrganizationProfile)
	private enum Key: String, CodingKey {
		case type, project, workspace, panel, project_id, workspace_id, panel_id, name, title, binding, kind, size_profile
	}
	func encode(to encoder: any Encoder) throws {
		var c: KeyedEncodingContainer<Key> = encoder.container(keyedBy: Key.self)
		switch self {
		case .createProject(let value):
			try c.encode("create_project", forKey: .type); try c.encode(value, forKey: .project)
		case .renameProject(let id, let name):
			try c.encode("rename_project", forKey: .type); try c.encode(id, forKey: .project_id); try c.encode(name, forKey: .name)
		case .deleteProject(let id):
			try c.encode("delete_project", forKey: .type); try c.encode(id, forKey: .project_id)
		case .createWorkspace(let value):
			try c.encode("create_workspace", forKey: .type); try c.encode(value, forKey: .workspace)
		case .renameWorkspace(let id, let name):
			try c.encode("rename_workspace", forKey: .type); try c.encode(id, forKey: .workspace_id); try c.encode(name, forKey: .name)
		case .deleteWorkspace(let id):
			try c.encode("delete_workspace", forKey: .type); try c.encode(id, forKey: .workspace_id)
		case .createPanel(let value):
			try c.encode("create_panel", forKey: .type); try c.encode(value, forKey: .panel)
		case .renamePanel(let id, let title):
			try c.encode("rename_panel", forKey: .type); try c.encode(id, forKey: .panel_id); try c.encode(title, forKey: .title)
		case .deletePanel(let id):
			try c.encode("delete_panel", forKey: .type); try c.encode(id, forKey: .panel_id)
		case .regroupPanel(let id, let workspace):
			try c.encode("regroup_panel", forKey: .type); try c.encode(id, forKey: .panel_id); try c.encode(workspace, forKey: .workspace_id)
		case .rebindPanel(let id, let binding):
			try c.encode("rebind_panel", forKey: .type); try c.encode(id, forKey: .panel_id); try c.encode(binding, forKey: .binding)
		case .setPanelKind(let id, let kind):
			try c.encode("set_panel_kind", forKey: .type); try c.encode(id, forKey: .panel_id); try c.encode(kind, forKey: .kind)
		case .setPanelSizeProfile(let id, let profile):
			try c.encode("set_panel_size_profile", forKey: .type); try c.encode(id, forKey: .panel_id); try c.encode(profile, forKey: .size_profile)
		}
	}
}
