import AppKit

enum DesktopStageFocusDirection: Equatable, Hashable, Sendable {
	case left
	case right
	case up
	case down
}

enum DesktopStageCommand: Equatable, Hashable, Sendable {
	case stopLayout
	case exitArrange
	case toggleArrange
	case splitPanel
	case toggleWorkspaceFocus
	case previousWorkspace
	case nextWorkspace
	case moveVirtualFocus(DesktopStageFocusDirection)
	case handInputToPanel
	case undo

	var allowsKeyRepeat: Bool {
		switch self {
		case .previousWorkspace, .nextWorkspace, .moveVirtualFocus:
			true
		case .stopLayout, .exitArrange, .toggleArrange, .splitPanel, .toggleWorkspaceFocus,
			.handInputToPanel, .undo:
			false
		}
	}
}

enum DesktopStageShortcutOrigin: Equatable, Sendable {
	case local
	case global
}

struct DesktopStageKeystroke: Equatable, Sendable {
	let keyCode: UInt16
	let modifierFlagsRawValue: UInt
	let isRepeat: Bool

	@MainActor
	init(event: NSEvent) {
		self.init(
			keyCode: event.keyCode,
			modifierFlagsRawValue: event.modifierFlags.rawValue,
			isRepeat: event.isARepeat
		)
	}

	init(
		keyCode: UInt16,
		modifierFlagsRawValue: UInt,
		isRepeat: Bool = false
	) {
		self.keyCode = keyCode
		self.modifierFlagsRawValue = modifierFlagsRawValue
		self.isRepeat = isRepeat
	}
}

enum DesktopStageShortcutMapper {
	private enum KeyCode {
		static let d: UInt16 = 2
		static let f: UInt16 = 3
		static let z: UInt16 = 6
		static let rightBracket: UInt16 = 30
		static let leftBracket: UInt16 = 33
		static let returnKey: UInt16 = 36
		static let space: UInt16 = 49
		static let escape: UInt16 = 53
		static let keypadEnter: UInt16 = 76
		static let leftArrow: UInt16 = 123
		static let rightArrow: UInt16 = 124
		static let downArrow: UInt16 = 125
		static let upArrow: UInt16 = 126
	}

	private static let relevantModifierMask: UInt =
		NSEvent.ModifierFlags.command.rawValue
		| NSEvent.ModifierFlags.control.rawValue
		| NSEvent.ModifierFlags.option.rawValue
		| NSEvent.ModifierFlags.shift.rawValue
	private static let controlOption: UInt =
		NSEvent.ModifierFlags.control.rawValue
		| NSEvent.ModifierFlags.option.rawValue

	static func command(for keystroke: DesktopStageKeystroke) -> DesktopStageCommand? {
		let modifiers: UInt = keystroke.modifierFlagsRawValue & relevantModifierMask
		let command: DesktopStageCommand?

		switch (modifiers, keystroke.keyCode) {
		case (controlOption, KeyCode.escape):
			command = .stopLayout
		case (0, KeyCode.escape):
			command = .exitArrange
		case (controlOption, KeyCode.space):
			command = .toggleArrange
		case (controlOption, KeyCode.d):
			command = .splitPanel
		case (controlOption, KeyCode.f):
			command = .toggleWorkspaceFocus
		case (controlOption, KeyCode.leftBracket):
			command = .previousWorkspace
		case (controlOption, KeyCode.rightBracket):
			command = .nextWorkspace
		case (controlOption, KeyCode.leftArrow):
			command = .moveVirtualFocus(.left)
		case (controlOption, KeyCode.rightArrow):
			command = .moveVirtualFocus(.right)
		case (controlOption, KeyCode.upArrow):
			command = .moveVirtualFocus(.up)
		case (controlOption, KeyCode.downArrow):
			command = .moveVirtualFocus(.down)
		case (controlOption, KeyCode.returnKey),
			(controlOption, KeyCode.keypadEnter):
			command = .handInputToPanel
		case (controlOption, KeyCode.z):
			command = .undo
		default:
			command = nil
		}

		guard let command else { return nil }
		guard !keystroke.isRepeat || command.allowsKeyRepeat else { return nil }
		return command
	}
}

enum DesktopStageShortcutMonitorError: Error, LocalizedError, Sendable {
	case localMonitorUnavailable
	case globalMonitorUnavailable

	var errorDescription: String? {
		switch self {
		case .localMonitorUnavailable:
			"macOS did not install Teaser's local shortcut monitor."
		case .globalMonitorUnavailable:
			"macOS did not install Teaser's global shortcut monitor."
		}
	}
}

/// Passively observes desktop-stage shortcuts. The local monitor always returns
/// the original event, and the global monitor cannot consume events, so provider
/// applications retain their normal input path.
@MainActor
final class DesktopStageShortcutMonitor {
	typealias CommandHandler = @MainActor (DesktopStageCommand) -> Void

	private final class MonitorRelay: @unchecked Sendable {
		private weak var owner: DesktopStageShortcutMonitor?

		init(owner: DesktopStageShortcutMonitor) {
			self.owner = owner
		}

		func receive(_ keystroke: DesktopStageKeystroke, origin: DesktopStageShortcutOrigin) {
			Task { @MainActor [weak owner, self] in
				owner?.receive(keystroke, origin: origin, relay: self)
			}
		}
	}

	private final class MonitorToken: @unchecked Sendable {
		let value: Any

		init(value: Any) {
			self.value = value
		}

		deinit {
			NSEvent.removeMonitor(value)
		}
	}

	private let onCommand: CommandHandler
	private var localMonitor: MonitorToken?
	private var globalMonitor: MonitorToken?
	private var relay: MonitorRelay?
	private var arrangeModeEnabled: Bool

	init(
		arrangeModeEnabled: Bool = false,
		onCommand: @escaping CommandHandler
	) {
		self.arrangeModeEnabled = arrangeModeEnabled
		self.onCommand = onCommand
	}

	var isRunning: Bool {
		localMonitor != nil && globalMonitor != nil
	}

	/// Layout undo uses Control-Option-Z; Command-Z is always provider input.
	func setArrangeModeEnabled(_ enabled: Bool) {
		arrangeModeEnabled = enabled
	}

	func start() throws {
		guard !isRunning else { return }
		stop()

		let relay: MonitorRelay = .init(owner: self)
		guard let globalValue: Any = NSEvent.addGlobalMonitorForEvents(
			matching: .keyDown,
			handler: { event in
				relay.receive(
					.init(event: event),
					origin: .global
				)
			}
		) else {
			throw DesktopStageShortcutMonitorError.globalMonitorUnavailable
		}
		let globalMonitor: MonitorToken = .init(value: globalValue)

		guard let localValue: Any = NSEvent.addLocalMonitorForEvents(
			matching: .keyDown,
			handler: { event in
				relay.receive(
					.init(event: event),
					origin: .local
				)
				return event
			}
		) else {
			withExtendedLifetime(globalMonitor) {}
			throw DesktopStageShortcutMonitorError.localMonitorUnavailable
		}

		self.relay = relay
		self.globalMonitor = globalMonitor
		self.localMonitor = .init(value: localValue)
	}

	func stop() {
		localMonitor = nil
		globalMonitor = nil
		relay = nil
	}

	private func receive(
		_ keystroke: DesktopStageKeystroke,
		origin: DesktopStageShortcutOrigin,
		relay: MonitorRelay
	) {
		guard self.relay === relay else { return }
		guard let command: DesktopStageCommand = DesktopStageShortcutMapper.command(
			for: keystroke
		) else { return }
		guard command != .undo || arrangeModeEnabled else { return }
		guard command != .exitArrange || arrangeModeEnabled else { return }
		onCommand(command)
	}
}
