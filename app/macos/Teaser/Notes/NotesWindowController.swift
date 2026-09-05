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

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
	let panelID: PanelID
	private let model: NotesPanelModel
	private let window: NSWindow
	private let onFocus: @MainActor (PanelID) -> Void
	private var dismissed: Bool = false
	var isVisible: Bool { window.isVisible }

	init(
		panelID: PanelID,
		title: String,
		text: String,
		onChange: @escaping @MainActor (String) -> Void,
		onFocus: @escaping @MainActor (PanelID) -> Void
	) {
		self.panelID = panelID
		let notesModel: NotesPanelModel = .init(
			title: title,
			text: text,
			onChange: onChange
		)
		self.model = notesModel
		self.onFocus = onFocus
		let rootView: NotesPanelView = .init(model: notesModel)
		let hostingView: NSHostingView<NotesPanelView> = .init(rootView: rootView)
		let window: NotesPanelWindow = .init(
			contentRect: .init(x: 0, y: 0, width: 480, height: 360),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = title
		window.titleVisibility = .visible
		window.tabbingMode = .disallowed
		window.isReleasedWhenClosed = false
		window.contentView = hostingView
		window.minSize = .init(width: 320, height: 240)
		self.window = window
		super.init()
		window.delegate = self
		window.onClick = { [weak self] in
			guard let self else { return }
			self.onFocus(self.panelID)
		}
	}

	func update(frame: CGRect, visible: Bool) {
		guard frame.width > 0, frame.height > 0 else { return }
		window.setFrame(frame, display: visible, animate: false)
		if visible && !dismissed {
			window.orderFront(nil)
		} else {
			window.orderOut(nil)
		}
	}

	func focus() {
		dismissed = false
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
		onFocus(panelID)
	}

	func close() {
		window.orderOut(nil)
	}

	func windowDidBecomeKey(_ notification: Notification) {
		onFocus(panelID)
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		dismissed = true
		window.orderOut(nil)
		return false
	}
}

@MainActor
private final class NotesPanelWindow: NSWindow {
	var onClick: (@MainActor () -> Void)?
	override func sendEvent(_ event: NSEvent) {
		if event.type == .leftMouseDown { onClick?() }
		super.sendEvent(event)
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
		.background(Color(nsColor: .textBackgroundColor))
	}
}
