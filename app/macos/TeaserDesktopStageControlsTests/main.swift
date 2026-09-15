import AppKit
import Darwin
@testable import TeaserKit

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			message
		}
	}
}

private func expect(
	_ condition: @autoclosure () -> Bool,
	_ message: String
) throws {
	guard condition() else {
		throw TestFailure.assertion(message)
	}
}

private let controlOption: UInt =
	NSEvent.ModifierFlags.control.rawValue
	| NSEvent.ModifierFlags.option.rawValue
private let command: UInt = NSEvent.ModifierFlags.command.rawValue

/// Reads the exact table handed to upstream. Carbon, not Teaser, matches the
/// live keystroke against it, so exact matching and repeat timing still need a
/// real keyboard.
private func boundCommand(keyCode: UInt16, modifiers: UInt) -> DesktopStageCommand? {
	DesktopStageShortcuts.bindings.first(where: {
		$0.shortcut.carbonKeyCode == Int(keyCode) && $0.shortcut.modifiers.rawValue == modifiers
	})?.command
}

private func testBindingTableIsExact() throws {
	let cases: [(keyCode: UInt16, modifiers: UInt, expected: DesktopStageCommand)] = [
		(53, controlOption, .stopLayout),
		(49, controlOption, .toggleArrange),
		(2, controlOption, .splitPanel),
		(3, controlOption, .toggleWorkspaceFocus),
		(33, controlOption, .previousWorkspace),
		(30, controlOption, .nextWorkspace),
		(123, controlOption, .moveVirtualFocus(.left)),
		(124, controlOption, .moveVirtualFocus(.right)),
		(126, controlOption, .moveVirtualFocus(.up)),
		(125, controlOption, .moveVirtualFocus(.down)),
		(36, controlOption, .handInputToPanel),
		(76, controlOption, .handInputToPanel),
		(6, controlOption, .undo),
	]

	for testCase: (keyCode: UInt16, modifiers: UInt, expected: DesktopStageCommand) in cases {
		try expect(
			boundCommand(
				keyCode: testCase.keyCode,
				modifiers: testCase.modifiers
			) == testCase.expected,
			"binding table must map key code \(testCase.keyCode) to \(testCase.expected)"
		)
	}
	try expect(
		DesktopStageShortcuts.bindings.count == cases.count,
		"binding table must contain only the documented shortcuts"
	)
}

private func testBindingTableLeavesProviderKeysAlone() throws {
	let shift: UInt = NSEvent.ModifierFlags.shift.rawValue
	try expect(boundCommand(keyCode: 6, modifiers: command) == nil,
		"Command-Z must remain exclusively provider input")
	try expect(boundCommand(keyCode: 53, modifiers: 0) == nil,
		"plain Escape must stay with the application holding Input Focus")
	let modifierCases: [(modifiers: UInt, message: String)] = [
		(0, "an unmodified D must not be bound"),
		(NSEvent.ModifierFlags.control.rawValue, "Ctrl+D must not be bound"),
		(NSEvent.ModifierFlags.option.rawValue, "Option+D must not be bound"),
		(controlOption | shift, "Ctrl+Option+Shift+D must not be bound"),
		(controlOption | command, "Ctrl+Option+Command+D must not be bound"),
	]
	for testCase: (modifiers: UInt, message: String) in modifierCases {
		try expect(
			boundCommand(keyCode: 2, modifiers: testCase.modifiers) == nil,
			testCase.message
		)
	}
	try expect(
		boundCommand(keyCode: 6, modifiers: command | shift) == nil,
		"Command+Shift+Z must remain available to the provider"
	)
	for binding: DesktopStageShortcutBinding in DesktopStageShortcuts.bindings {
		try expect(
			binding.shortcut.modifiers.contains([.control, .option]),
			"\(binding.command) must carry Control-Option: a registered hot key consumes its keystroke"
		)
	}
}

private func testStreamSelection() throws {
	let repeating: Set<DesktopStageCommand> = [
		.previousWorkspace, .nextWorkspace,
		.moveVirtualFocus(.left), .moveVirtualFocus(.right),
		.moveVirtualFocus(.up), .moveVirtualFocus(.down),
	]
	for binding: DesktopStageShortcutBinding in DesktopStageShortcuts.bindings {
		let expected: DesktopStageShortcutStream =
			repeating.contains(binding.command) ? .repeatingKeyDown : .keyDown
		try expect(
			binding.stream == expected,
			"\(binding.command) must subscribe to the \(expected) stream"
		)
	}
}

private func testLayoutUndoDoesNotReuseProviderUndo() throws {
	try expect(
		boundCommand(keyCode: 6, modifiers: command) == nil,
		"Command+Z belongs to the provider"
	)
	try expect(
		boundCommand(keyCode: 6, modifiers: controlOption) == .undo,
		"Ctrl+Option+Z maps to layout undo"
	)
}

@MainActor
private final class RecordingShortcutSource: DesktopStageShortcutSource {
	struct Listener {
		let binding: DesktopStageShortcutBinding
		let action: @MainActor @Sendable () -> Void
		let task: Task<Void, Never>
	}
	var listeners: [Listener] = []

	func listen(for binding: DesktopStageShortcutBinding,
		onKeyDown: @escaping @MainActor @Sendable () -> Void
	) -> Task<Void, Never> {
		let task: Task<Void, Never> = Task {}
		listeners.append(.init(binding: binding, action: onKeyDown, task: task))
		return task
	}
}

@MainActor
private func testLibrarySubscriptionLifetime() throws {
	let source: RecordingShortcutSource = .init()
	var commands: [DesktopStageCommand] = []
	let monitor: DesktopStageShortcutMonitor = .init(source: source) { commands.append($0) }
	try expect(source.listeners.isEmpty, "construction must not install global shortcuts")
	monitor.start()
	try expect(monitor.isRunning && source.listeners.count == 12, "stage starts only unscoped bindings")
	monitor.start()
	try expect(source.listeners.count == 12, "repeated start must not double-register")
	for listener: RecordingShortcutSource.Listener in source.listeners {
		try expect(!listener.binding.requiresArrangeMode, "layout Undo must stay unregistered outside Arrange")
		listener.action()
	}
	try expect(commands == source.listeners.map(\.binding.command), "library callbacks must dispatch real commands")
	monitor.setArrangeModeEnabled(true)
	try expect(source.listeners.count == 13, "Arrange installs layout Undo")
	let scoped: [RecordingShortcutSource.Listener] = Array(source.listeners.suffix(1))
	try expect(scoped.map(\.binding.command) == [.undo], "the only Arrange-scoped binding is layout Undo")
	for listener: RecordingShortcutSource.Listener in scoped { listener.action() }
	let count: Int = commands.count
	monitor.setArrangeModeEnabled(false)
	for listener: RecordingShortcutSource.Listener in scoped {
		try expect(listener.task.isCancelled, "leaving Arrange cancels its upstream subscription")
		listener.action()
	}
	try expect(commands.count == count, "queued callbacks from disabled bindings must be rejected")
	monitor.setArrangeModeEnabled(true)
	for listener: RecordingShortcutSource.Listener in scoped { listener.action() }
	try expect(commands.count == count, "old Arrange callbacks must not revive after re-entry")
	let stopped: [RecordingShortcutSource.Listener] = source.listeners
	monitor.stop()
	try expect(!monitor.isRunning, "Stop deactivates shortcuts")
	for listener: RecordingShortcutSource.Listener in stopped {
		try expect(listener.task.isCancelled, "Stop cancels every subscription")
		listener.action()
	}
	monitor.start()
	for listener: RecordingShortcutSource.Listener in stopped { listener.action() }
	try expect(commands.count == count, "stale callbacks cannot run after Stop or restart")
	source.listeners.last?.action()
	try expect(commands.count == count + 1, "new subscriptions remain usable after restart")
	monitor.stop()
}

@MainActor
private func testShortcutOwnerDeinitCancelsSubscriptions() throws {
	let source: RecordingShortcutSource = .init()
	var monitor: DesktopStageShortcutMonitor? = .init(source: source) { _ in }
	monitor?.start()
	monitor = nil
	try expect(source.listeners.allSatisfy { $0.task.isCancelled }, "owner teardown cancels upstream listeners")
}

@MainActor
private func run() throws {
	try testBindingTableIsExact()
	try testBindingTableLeavesProviderKeysAlone()
	try testStreamSelection()
	try testLayoutUndoDoesNotReuseProviderUndo()
	try testLibrarySubscriptionLifetime()
	try testShortcutOwnerDeinitCancelsSubscriptions()
}

do {
	try run()
	print("Teaser desktop-stage controls tests passed")
} catch {
	fputs("Teaser desktop-stage controls tests failed: \(error)\n", stderr)
	exit(1)
}
