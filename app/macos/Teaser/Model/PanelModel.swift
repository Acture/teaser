import Foundation

struct LayoutRange: Codable, Equatable, Hashable, Sendable {
	let minimum: Double
	let maximum: Double

	init(_ minimum: Double, _ maximum: Double) {
		precondition(minimum > 0 && maximum >= minimum)
		self.minimum = minimum
		self.maximum = maximum
	}

	func contains(_ value: Double) -> Bool {
		value >= minimum && value <= maximum
	}

	func distance(to value: Double) -> Double {
		if value < minimum {
			return minimum - value
		}
		if value > maximum {
			return value - maximum
		}
		return 0
	}
}

struct LayoutProfile: Codable, Equatable, Hashable, Sendable {
	let minimumSize: LayoutSize
	let preferredAspectRatio: LayoutRange
	let growthWeight: Double

	init(
		minimumSize: LayoutSize,
		preferredAspectRatio: LayoutRange,
		growthWeight: Double
	) {
		precondition(minimumSize.width > 0 && minimumSize.height > 0)
		precondition(growthWeight > 0)
		self.minimumSize = minimumSize
		self.preferredAspectRatio = preferredAspectRatio
		self.growthWeight = growthWeight
	}
}

struct PanelKindDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
	let id: PanelKindID
	let displayName: String
	let defaultProfile: LayoutProfile

	static let task: PanelKindDefinition = .init(
		id: .task,
		displayName: "Task",
		defaultProfile: .init(
			minimumSize: .init(width: 360, height: 240),
			preferredAspectRatio: .init(1.2, 2.0),
			growthWeight: 1.0
		)
	)

	static let cli: PanelKindDefinition = .init(
		id: .cli,
		displayName: "CLI",
		defaultProfile: .init(
			minimumSize: .init(width: 400, height: 220),
			preferredAspectRatio: .init(1.6, 3.2),
			growthWeight: 1.0
		)
	)

	static let app: PanelKindDefinition = .init(
		id: .app,
		displayName: "App",
		defaultProfile: .init(
			minimumSize: .init(width: 520, height: 320),
			preferredAspectRatio: .init(1.2, 2.2),
			growthWeight: 1.5
		)
	)

	static let agent: PanelKindDefinition = .init(
		id: .agent,
		displayName: "Agent",
		defaultProfile: .init(
			minimumSize: .init(width: 440, height: 280),
			preferredAspectRatio: .init(1.1, 2.2),
			growthWeight: 1.3
		)
	)

	static let file: PanelKindDefinition = .init(
		id: .file,
		displayName: "File",
		defaultProfile: .init(
			minimumSize: .init(width: 300, height: 360),
			preferredAspectRatio: .init(0.55, 1.4),
			growthWeight: 0.8
		)
	)

	static let notes: PanelKindDefinition = .init(
		id: .notes,
		displayName: "Notes",
		defaultProfile: .init(
			minimumSize: .init(width: 320, height: 240),
			preferredAspectRatio: .init(0.8, 1.6),
			growthWeight: 0.8
		)
	)

	static let generic: PanelKindDefinition = .init(
		id: .generic,
		displayName: "Generic",
		defaultProfile: .init(
			minimumSize: .init(width: 320, height: 220),
			preferredAspectRatio: .init(0.7, 2.8),
			growthWeight: 1.0
		)
	)

	static let builtIns: [PanelKindDefinition] = [
		.task,
		.cli,
		.app,
		.agent,
		.file,
		.notes,
		.generic,
	]
}

extension PanelKindID {
	static let task: PanelKindID = .init("task")
	static let cli: PanelKindID = .init("cli")
	static let app: PanelKindID = .init("app")
	static let agent: PanelKindID = .init("agent")
	static let file: PanelKindID = .init("file")
	static let notes: PanelKindID = .init("notes")
	static let generic: PanelKindID = .init("generic")
}

enum PanelKindRegistryError: Error, Equatable, Sendable {
	case reservedBuiltInID(PanelKindID)
	case duplicateCustomID(PanelKindID)
}

struct PanelKindRegistry: Codable, Equatable, Sendable {
	private(set) var customDefinitions: [PanelKindDefinition]

	init(customDefinitions: [PanelKindDefinition] = []) throws {
		let builtInIDs: Set<PanelKindID> = .init(
			PanelKindDefinition.builtIns.map(\.id)
		)
		var customIDs: Set<PanelKindID> = []
		for definition: PanelKindDefinition in customDefinitions {
			guard !builtInIDs.contains(definition.id) else {
				throw PanelKindRegistryError.reservedBuiltInID(definition.id)
			}
			guard customIDs.insert(definition.id).inserted else {
				throw PanelKindRegistryError.duplicateCustomID(definition.id)
			}
		}
		self.customDefinitions = customDefinitions
	}

	var allDefinitions: [PanelKindDefinition] {
		PanelKindDefinition.builtIns + customDefinitions
	}

	func definition(for id: PanelKindID) -> PanelKindDefinition? {
		allDefinitions.first { $0.id == id }
	}

	mutating func register(_ definition: PanelKindDefinition) throws {
		guard PanelKindDefinition.builtIns.allSatisfy({ $0.id != definition.id }) else {
			throw PanelKindRegistryError.reservedBuiltInID(definition.id)
		}
		guard customDefinitions.allSatisfy({ $0.id != definition.id }) else {
			throw PanelKindRegistryError.duplicateCustomID(definition.id)
		}
		customDefinitions.append(definition)
	}
}

struct PanelProviderHint: Codable, Equatable, Hashable, Sendable {
	let displayName: String
	let bundleIdentifier: String?
	let context: String?
}

enum NativePanelContent: Codable, Equatable, Hashable, Sendable {
	case notes
	case none
}

struct PanelDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
	let id: PanelID
	var title: String
	var kindID: PanelKindID
	var providerHint: PanelProviderHint?
	var profileOverride: LayoutProfile?
	var nativeContent: NativePanelContent
}
