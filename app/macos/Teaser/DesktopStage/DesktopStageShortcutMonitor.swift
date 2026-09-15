import AppKit
import KeyboardShortcuts

enum DesktopStageFocusDirection: Equatable, Hashable, Sendable {
	case left, right, up, down
}

enum DesktopStageCommand: Equatable, Hashable, Sendable {
	case stopLayout
	case toggleArrange
	case splitPanel
	case toggleWorkspaceFocus
	case previousWorkspace
	case nextWorkspace
	case moveVirtualFocus(DesktopStageFocusDirection)
	case handInputToPanel
	case undo
}

/// How upstream delivers a held key: once per press, or at the key-repeat rate.
enum DesktopStageShortcutStream: Equatable, Sendable {
	case keyDown
	case repeatingKeyDown
}

/// Shared by library registration and the headless binding-contract tests.
struct DesktopStageShortcutBinding: Hashable, Sendable {
	let shortcut: KeyboardShortcuts.Shortcut
	let command: DesktopStageCommand

	var requiresArrangeMode: Bool { command == .undo }

	var stream: DesktopStageShortcutStream {
		switch command {
		case .previousWorkspace, .nextWorkspace, .moveVirtualFocus: .repeatingKeyDown
		default: .keyDown
		}
	}
}

enum DesktopStageShortcuts {
	/// Every binding carries Control-Option. A registered Carbon hot key consumes
	/// its keystroke system-wide, so an unmodified key such as Escape would be
	/// taken from the application holding Input Focus.
	static let bindings: [DesktopStageShortcutBinding] = {
		let keys: [(KeyboardShortcuts.Key, DesktopStageCommand)] = [
			(.escape, .stopLayout), (.space, .toggleArrange), (.d, .splitPanel),
			(.f, .toggleWorkspaceFocus), (.leftBracket, .previousWorkspace),
			(.rightBracket, .nextWorkspace), (.leftArrow, .moveVirtualFocus(.left)),
			(.rightArrow, .moveVirtualFocus(.right)), (.upArrow, .moveVirtualFocus(.up)),
			(.downArrow, .moveVirtualFocus(.down)), (.return, .handInputToPanel),
			(.keypadEnter, .handInputToPanel), (.z, .undo),
		]
		return keys.map { key, command in
			.init(shortcut: .init(key, modifiers: [.control, .option]), command: command)
		}
	}()
}

@MainActor
protocol DesktopStageShortcutSource {
	func listen(
		for binding: DesktopStageShortcutBinding,
		onKeyDown: @escaping @MainActor @Sendable () -> Void
	) -> Task<Void, Never>
}

/// Upstream owns Carbon registration, dispatch, key-repeat timing and teardown.
/// Hard-coded streams avoid writing a second shortcut configuration to defaults.
@MainActor
struct LibraryDesktopStageShortcutSource: DesktopStageShortcutSource {
	func listen(
		for binding: DesktopStageShortcutBinding,
		onKeyDown: @escaping @MainActor @Sendable () -> Void
	) -> Task<Void, Never> {
		Task { @MainActor in
			guard !Task.isCancelled else { return }
			switch binding.stream {
			case .repeatingKeyDown:
				for await _ in KeyboardShortcuts.repeatingKeyDownEvents(for: binding.shortcut) {
					guard !Task.isCancelled else { return }
					onKeyDown()
				}
			case .keyDown:
				for await _ in KeyboardShortcuts.events(.keyDown, for: binding.shortcut) {
					guard !Task.isCancelled else { return }
					onKeyDown()
				}
			}
		}
	}
}

/// Only active while the stage is running; layout Undo is scoped further to
/// Arrange. Command-Z and unmodified provider keys are never bound.
@MainActor
final class DesktopStageShortcutMonitor {
	private struct Registration: Sendable {
		let id: UUID
		let task: Task<Void, Never>
	}

	private let source: any DesktopStageShortcutSource
	private let onCommand: @MainActor (DesktopStageCommand) -> Void
	private var registrations: [DesktopStageShortcutBinding: Registration] = [:]
	private var arrangeModeEnabled: Bool
	private(set) var isRunning: Bool = false

	init(
		arrangeModeEnabled: Bool = false,
		source: any DesktopStageShortcutSource = LibraryDesktopStageShortcutSource(),
		onCommand: @escaping @MainActor (DesktopStageCommand) -> Void
	) {
		self.arrangeModeEnabled = arrangeModeEnabled
		self.source = source
		self.onCommand = onCommand
	}

	deinit {
		for registration: Registration in registrations.values { registration.task.cancel() }
	}

	func setArrangeModeEnabled(_ enabled: Bool) {
		guard arrangeModeEnabled != enabled else { return }
		arrangeModeEnabled = enabled
		if isRunning { updateRegistrations() }
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		updateRegistrations()
	}

	func stop() {
		isRunning = false
		for registration: Registration in registrations.values { registration.task.cancel() }
		registrations.removeAll()
	}

	private func updateRegistrations() {
		for binding: DesktopStageShortcutBinding in DesktopStageShortcuts.bindings {
			if binding.requiresArrangeMode && !arrangeModeEnabled {
				registrations.removeValue(forKey: binding)?.task.cancel()
			} else if registrations[binding] == nil {
				let id: UUID = .init()
				let task: Task<Void, Never> = source.listen(for: binding) { [weak self] in
					guard let self, self.isRunning, self.registrations[binding]?.id == id else { return }
					self.onCommand(binding.command)
				}
				registrations[binding] = .init(id: id, task: task)
			}
		}
	}
}
