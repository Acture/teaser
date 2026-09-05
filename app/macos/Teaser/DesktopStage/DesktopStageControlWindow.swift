import AppKit

/// The ordinary, closable app window remains available while the stage is active.
@MainActor
final class DesktopStageControlWindow: NSObject, NSWindowDelegate {
	let window: NSWindow
	private let statusLabel: NSTextField = .init(wrappingLabelWithString: "")
	private let permissionLabel: NSTextField = .init(labelWithString: "")
	private let startButton: NSButton = .init(title: "Start Layout", target: nil, action: nil)
	private let arrangeButton: NSButton = .init(title: "Arrange", target: nil, action: nil)
	private let permissionButton: NSButton = .init(title: "Allow Accessibility…", target: nil, action: nil)
	private let onToggleStage: @MainActor () -> Void
	private let onArrange: @MainActor () -> Void
	private let onRequestPermission: @MainActor () -> Void
	private let onQuit: @MainActor () -> Void

	init(
		onToggleStage: @escaping @MainActor () -> Void,
		onArrange: @escaping @MainActor () -> Void,
		onRequestPermission: @escaping @MainActor () -> Void,
		onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
	) {
		self.onToggleStage = onToggleStage
		self.onArrange = onArrange
		self.onRequestPermission = onRequestPermission
		self.onQuit = onQuit
		window = .init(
			contentRect: .init(x: 0, y: 0, width: 520, height: 320),
			styleMask: [.titled, .closable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		super.init()
		window.title = "Teaser"
		window.isReleasedWhenClosed = false
		window.isRestorable = false
		window.tabbingMode = .disallowed
		window.delegate = self

		let heading: NSTextField = .init(labelWithString: "Your apps, arranged by project")
		heading.font = .systemFont(ofSize: 18, weight: .semibold)
		let instructions: NSTextField = .init(wrappingLabelWithString:
			"Start the layout, then drag a window by its title bar into a Panel. Drop on an occupied edge to split."
		)
		instructions.textColor = .secondaryLabelColor
		permissionLabel.font = .systemFont(ofSize: 12)
		statusLabel.font = .systemFont(ofSize: 12)
		statusLabel.maximumNumberOfLines = 3
		let shortcuts: NSTextField = .init(wrappingLabelWithString:
			"⌃⌥Space  Arrange    ⌃⌥D  Split    ⌃⌥F  Focus\nEsc  Leave Arrange    ⌃⌥Esc  Stop layout    ⌘Q  Quit"
		)
		shortcuts.font = .systemFont(ofSize: 11)
		shortcuts.textColor = .secondaryLabelColor
		startButton.target = self
		startButton.action = #selector(toggleStage(_:))
		startButton.bezelStyle = .rounded
		arrangeButton.target = self
		arrangeButton.action = #selector(arrange(_:))
		arrangeButton.bezelStyle = .rounded
		permissionButton.target = self
		permissionButton.action = #selector(requestPermission(_:))
		permissionButton.bezelStyle = .rounded
		let quitButton: NSButton = .init(
			title: "Quit Teaser", target: self, action: #selector(quit(_:))
		)
		quitButton.bezelStyle = .rounded
		let actions: NSStackView = .init(views: [startButton, arrangeButton, quitButton])
		actions.orientation = .horizontal
		actions.spacing = 8
		let content: NSStackView = .init(views: [
			heading, instructions, permissionLabel, permissionButton, actions,
			statusLabel, shortcuts,
		])
		content.orientation = .vertical
		content.alignment = .leading
		content.spacing = 14
		content.translatesAutoresizingMaskIntoConstraints = false
		let container: NSView = .init()
		container.addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
			content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
			content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
			content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
			instructions.widthAnchor.constraint(equalTo: content.widthAnchor),
			statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
		])
		window.contentView = container
		window.center()
	}

	func show() {
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	func update(active: Bool, arranging: Bool, authorized: Bool, message: String?) {
		startButton.title = active ? "Stop Layout" : "Start Layout"
		startButton.isEnabled = authorized || active
		arrangeButton.isEnabled = active
		arrangeButton.title = arranging ? "Finish Arranging" : "Arrange"
		permissionLabel.stringValue = authorized
			? "Accessibility allowed" : "Accessibility access is required to arrange windows."
		permissionButton.isHidden = authorized
		statusLabel.stringValue = message ?? (active ? "Ready for a window" : "Layout stopped. Your desktop is unchanged.")
		window.level = .normal
	}

	func close() {
		window.orderOut(nil)
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		onQuit()
		return false
	}

	@objc private func toggleStage(_ sender: NSButton) { onToggleStage() }
	@objc private func arrange(_ sender: NSButton) { onArrange() }
	@objc private func requestPermission(_ sender: NSButton) { onRequestPermission() }
	@objc private func quit(_ sender: NSButton) { onQuit() }
}
