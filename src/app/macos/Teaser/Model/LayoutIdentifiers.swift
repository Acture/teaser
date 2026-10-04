import Foundation

struct DisplayID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

struct WorkspaceID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

struct PanelID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

struct LayoutSplitID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}

struct PanelKindID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
	let rawValue: String

	init(rawValue: String) {
		self.rawValue = rawValue
	}

	init(_ rawValue: String) {
		self.rawValue = rawValue
	}
}
