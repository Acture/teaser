import AppKit
import Foundation

enum PanelDefinitionEditorError: Error, LocalizedError {
	case invalidName
	case invalidNumber(String)

	var errorDescription: String? {
		switch self {
		case .invalidName:
			return "Enter a name for the Panel type."
		case .invalidNumber(let field):
			return "Enter a valid positive value for \(field)."
		}
	}
}

@MainActor
final class PanelDefinitionEditorController {
	func present(
		onSave: @escaping @MainActor (Result<PanelKindDefinition, Error>) -> Void
	) {
		let nameField: NSTextField = .init(string: "")
		let widthField: NSTextField = .init(string: "360")
		let heightField: NSTextField = .init(string: "240")
		let aspectMinimumField: NSTextField = .init(string: "1.0")
		let aspectMaximumField: NSTextField = .init(string: "2.0")
		let weightField: NSTextField = .init(string: "1.0")
		let grid: NSGridView = .init(views: [
			[label("Name"), nameField],
			[label("Minimum width"), widthField],
			[label("Minimum height"), heightField],
			[label("Aspect minimum"), aspectMinimumField],
			[label("Aspect maximum"), aspectMaximumField],
			[label("Growth weight"), weightField],
		])
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).width = 180
		grid.rowSpacing = 6
		grid.columnSpacing = 10

		let alert: NSAlert = .init()
		alert.messageText = "New Panel Type"
		alert.informativeText = "Panel types declare layout preferences; the provider window remains unchanged."
		alert.accessoryView = grid
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")

		guard alert.runModal() == .alertFirstButtonReturn else { return }
		do {
			let definition: PanelKindDefinition = try makeDefinition(
				name: nameField.stringValue,
				minimumWidth: widthField.stringValue,
				minimumHeight: heightField.stringValue,
				aspectMinimum: aspectMinimumField.stringValue,
				aspectMaximum: aspectMaximumField.stringValue,
				growthWeight: weightField.stringValue
			)
			onSave(.success(definition))
		} catch {
			onSave(.failure(error))
		}
	}

	private func label(_ value: String) -> NSTextField {
		let field: NSTextField = .init(labelWithString: value)
		field.alignment = .right
		return field
	}

	private func makeDefinition(
		name rawName: String,
		minimumWidth rawMinimumWidth: String,
		minimumHeight rawMinimumHeight: String,
		aspectMinimum rawAspectMinimum: String,
		aspectMaximum rawAspectMaximum: String,
		growthWeight rawGrowthWeight: String
	) throws -> PanelKindDefinition {
		let name: String = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else {
			throw PanelDefinitionEditorError.invalidName
		}
		let minimumWidth: Double = try positiveDouble(rawMinimumWidth, field: "minimum width")
		let minimumHeight: Double = try positiveDouble(rawMinimumHeight, field: "minimum height")
		let aspectMinimum: Double = try positiveDouble(rawAspectMinimum, field: "aspect minimum")
		let aspectMaximum: Double = try positiveDouble(rawAspectMaximum, field: "aspect maximum")
		let growthWeight: Double = try positiveDouble(rawGrowthWeight, field: "growth weight")
		guard aspectMaximum >= aspectMinimum else {
			throw PanelDefinitionEditorError.invalidNumber("aspect range")
		}
		let slug: String = name.lowercased()
			.replacingOccurrences(
				of: "[^a-z0-9]+",
				with: "-",
				options: .regularExpression
			)
			.trimmingCharacters(in: .init(charactersIn: "-"))
		guard !slug.isEmpty else {
			throw PanelDefinitionEditorError.invalidName
		}
		return .init(
			id: .init("custom.\(slug)"),
			displayName: name,
			defaultProfile: .init(
				minimumSize: .init(width: minimumWidth, height: minimumHeight),
				preferredAspectRatio: .init(aspectMinimum, aspectMaximum),
				growthWeight: growthWeight
			)
		)
	}

	private func positiveDouble(_ rawValue: String, field: String) throws -> Double {
		guard let value: Double = Double(rawValue), value.isFinite, value > 0 else {
			throw PanelDefinitionEditorError.invalidNumber(field)
		}
		return value
	}
}
