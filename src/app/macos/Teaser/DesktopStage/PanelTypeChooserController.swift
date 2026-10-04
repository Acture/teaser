import AppKit
import SwiftUI

@MainActor
final class PanelTypeChooserController {
	private var window: NSPanel?

	func show(
		for panelID: PanelID,
		near panelFrame: CGRect,
		definitions: [PanelKindDefinition] = PanelKindDefinition.builtIns,
		onSelect: @escaping @MainActor (PanelID, PanelKindID) -> Void
	) {
		close()
		let choices: [PanelKindDefinition] = definitions.filter {
			$0.id != .generic && $0.id != .notes
		}
		let view: PanelTypeChooserView = .init(
			choices: choices,
			onSelect: { [weak self] kindID in
				onSelect(panelID, kindID)
				self?.close()
			}
		)
		let hostingView: NSHostingView<PanelTypeChooserView> = .init(rootView: view)
		let size: CGSize = hostingView.fittingSize
		let origin: CGPoint = .init(
			x: panelFrame.midX - size.width / 2,
			y: max(panelFrame.minY + 8, panelFrame.maxY - size.height - 8)
		)
		let panel: NSPanel = .init(
			contentRect: .init(origin: origin, size: size),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.level = .floating
		panel.collectionBehavior = [.transient, .moveToActiveSpace]
		panel.contentView = hostingView
		panel.orderFrontRegardless()
		window = panel
	}

	func close() {
		window?.orderOut(nil)
		window = nil
	}
}

@MainActor
private struct PanelTypeChooserView: View {
	let choices: [PanelKindDefinition]
	let onSelect: @MainActor (PanelKindID) -> Void

	var body: some View {
		HStack(spacing: 4) {
			Text("Panel type")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.secondary)
			ForEach(choices) { choice in
				Button(choice.displayName) {
					onSelect(choice.id)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
		.padding(8)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}
