import AppKit
import Combine
import SwiftUI

@MainActor
final class NotesPanelModel: ObservableObject {
	@Published var text: String {
		didSet {
			guard text != oldValue else { return }
			onChange(text)
		}
	}

	let title: String
	private let onChange: @MainActor (String) -> Void

	init(
		title: String,
		text: String,
		onChange: @escaping @MainActor (String) -> Void
	) {
		self.title = title
		self.text = text
		self.onChange = onChange
	}
}

/// Teaser's own Panel content, hosted inside the canvas rather than in a window
/// of its own. A separate window would stay behind on the desktop Space when
/// its canvas went fullscreen, and would need its own level and Space rules to
/// stay with the Panel it belongs to; a view simply moves with the canvas.
@MainActor
final class NotesPanelController {
	let panelID: PanelID
	private let model: NotesPanelModel
	private let hostingView: NSHostingView<NotesPanelView>

	init(
		panelID: PanelID,
		title: String,
		text: String,
		onChange: @escaping @MainActor (String) -> Void
	) {
		self.panelID = panelID
		let notesModel: NotesPanelModel = .init(
			title: title,
			text: text,
			onChange: onChange
		)
		model = notesModel
		hostingView = .init(rootView: .init(model: notesModel))
		// The canvas behind this view is transparent while windowed, so the
		// Panel provides its own surface instead of showing the desktop through
		// its text.
		hostingView.wantsLayer = true
		hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
		hostingView.layer?.cornerRadius = 6
		hostingView.layer?.masksToBounds = true
	}

	var view: NSView { hostingView }

	func updateText(_ text: String) {
		if model.text != text { model.text = text }
	}

	/// Typing needs the canvas window itself to be key; the Panel only takes the
	/// responder inside it.
	func focus() {
		guard let window: NSWindow = hostingView.window else { return }
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(hostingView)
	}
}

@MainActor
private struct NotesPanelView: View {
	@ObservedObject var model: NotesPanelModel

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "note.text")
					.foregroundStyle(.secondary)
				Text(model.title)
					.font(.system(size: 12, weight: .semibold))
				Spacer()
				Text("Local notes")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
			.padding(.horizontal, 12)
			.frame(height: 32)
			.background(.bar)

			Divider()

			TextEditor(text: $model.text)
				.font(.system(size: 13))
				.scrollContentBackground(.hidden)
				.padding(10)
		}
	}
}
