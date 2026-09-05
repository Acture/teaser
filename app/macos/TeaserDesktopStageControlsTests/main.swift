import AppKit
import Darwin

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

private func mappedCommand(
	keyCode: UInt16,
	modifiers: UInt,
	isRepeat: Bool = false
) -> DesktopStageCommand? {
	DesktopStageShortcutMapper.command(
		for: .init(
			keyCode: keyCode,
			modifierFlagsRawValue: modifiers,
			isRepeat: isRepeat
		)
	)
}

private func testAllShortcutMappings() throws {
	let cases: [(keyCode: UInt16, modifiers: UInt, expected: DesktopStageCommand)] = [
		(53, controlOption, .stopLayout),
		(53, 0, .exitArrange),
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
			mappedCommand(
				keyCode: testCase.keyCode,
				modifiers: testCase.modifiers
			) == testCase.expected,
			"key code \(testCase.keyCode) must map to \(testCase.expected)"
		)
	}
}

private func testModifierMatchingIsExact() throws {
	let shift: UInt = NSEvent.ModifierFlags.shift.rawValue
	try expect(mappedCommand(keyCode: 6, modifiers: command) == nil,
		"Command-Z must remain exclusively provider input")
	let modifierCases: [(modifiers: UInt, message: String)] = [
		(0, "an unmodified D must not split"),
		(NSEvent.ModifierFlags.control.rawValue, "raw Ctrl+D must not split"),
		(NSEvent.ModifierFlags.option.rawValue, "raw Option+D must not split"),
		(controlOption | shift, "Ctrl+Option+Shift+D must not split"),
		(controlOption | command, "Ctrl+Option+Command+D must not split"),
	]
	for testCase: (modifiers: UInt, message: String) in modifierCases {
		try expect(
			mappedCommand(keyCode: 2, modifiers: testCase.modifiers) == nil,
			testCase.message
		)
	}

	let capsLock: UInt = NSEvent.ModifierFlags.capsLock.rawValue
	try expect(
		mappedCommand(keyCode: 2, modifiers: controlOption | capsLock) == .splitPanel,
		"state-only Caps Lock must not disable Ctrl+Option+D"
	)
	try expect(
		mappedCommand(keyCode: 6, modifiers: command | shift) == nil,
		"Command+Shift+Z must remain available to the provider"
	)
}

private func testRepeatRules() throws {
	let nonRepeating: [(keyCode: UInt16, modifiers: UInt)] = [
		(53, controlOption),
		(53, 0),
		(49, controlOption),
		(2, controlOption),
		(3, controlOption),
		(36, controlOption),
		(76, controlOption),
		(6, controlOption),
	]
	for shortcut: (keyCode: UInt16, modifiers: UInt) in nonRepeating {
		try expect(
			mappedCommand(
				keyCode: shortcut.keyCode,
				modifiers: shortcut.modifiers,
				isRepeat: true
			) == nil,
			"one-shot shortcuts must reject key-repeat events"
		)
	}

	let repeating: [(keyCode: UInt16, expected: DesktopStageCommand)] = [
		(33, .previousWorkspace),
		(30, .nextWorkspace),
		(123, .moveVirtualFocus(.left)),
		(124, .moveVirtualFocus(.right)),
		(126, .moveVirtualFocus(.up)),
		(125, .moveVirtualFocus(.down)),
	]
	for shortcut: (keyCode: UInt16, expected: DesktopStageCommand) in repeating {
		try expect(
			mappedCommand(
				keyCode: shortcut.keyCode,
				modifiers: controlOption,
				isRepeat: true
			) == shortcut.expected,
			"navigation shortcuts must accept key-repeat events"
		)
	}
}

private func testLayoutUndoDoesNotReuseProviderUndo() throws {
	try expect(
		mappedCommand(keyCode: 6, modifiers: command) == nil,
		"Command+Z belongs to the provider"
	)
	try expect(
		mappedCommand(keyCode: 6, modifiers: controlOption) == .undo,
		"Ctrl+Option+Z maps to layout undo"
	)
}

private func run() throws {
	try testAllShortcutMappings()
	try testModifierMatchingIsExact()
	try testRepeatRules()
	try testLayoutUndoDoesNotReuseProviderUndo()
}

do {
	try run()
	print("Teaser desktop-stage controls tests passed")
} catch {
	fputs("Teaser desktop-stage controls tests failed: \(error)\n", stderr)
	exit(1)
}
