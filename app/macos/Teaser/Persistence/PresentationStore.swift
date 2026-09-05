import Foundation

struct PersistedNote: Codable, Equatable, Sendable {
	let panelID: PanelID
	var text: String
}

struct PresentationDocument: Codable, Equatable, Sendable {
	static let currentSchemaVersion: Int = 1

	let schemaVersion: Int
	var presentation: WorkspacePresentation
	var notes: [PersistedNote]

	init(
		presentation: WorkspacePresentation,
		notes: [PersistedNote]
	) {
		self.schemaVersion = Self.currentSchemaVersion
		self.presentation = presentation
		self.notes = notes
	}
}

enum PresentationStoreError: Error, LocalizedError {
	case unsupportedSchemaVersion(Int)

	var errorDescription: String? {
		switch self {
		case .unsupportedSchemaVersion(let version):
			return "Teaser cannot open presentation schema version \(version)."
		}
	}
}

struct PresentationStore: Sendable {
	let documentURL: URL

	static func live() throws -> PresentationStore {
		let applicationSupportURL: URL = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		let teaserURL: URL = applicationSupportURL.appendingPathComponent(
			"Teaser",
			isDirectory: true
		)
		return .init(
			documentURL: teaserURL.appendingPathComponent("presentation.json")
		)
	}

	func load() throws -> PresentationDocument? {
		guard FileManager.default.fileExists(atPath: documentURL.path) else {
			return nil
		}
		let data: Data = try Data(contentsOf: documentURL)
		let document: PresentationDocument = try JSONDecoder().decode(
			PresentationDocument.self,
			from: data
		)
		guard document.schemaVersion == PresentationDocument.currentSchemaVersion else {
			throw PresentationStoreError.unsupportedSchemaVersion(
				document.schemaVersion
			)
		}
		return document
	}

	func save(_ document: PresentationDocument) throws {
		let directoryURL: URL = documentURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700], ofItemAtPath: directoryURL.path
		)
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data: Data = try encoder.encode(document)
		try data.write(to: documentURL, options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: documentURL.path
		)
	}
}
