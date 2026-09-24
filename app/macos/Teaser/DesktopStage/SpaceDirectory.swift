import AppKit
import ApplicationServices
import Foundation

// Teaser's Space awareness, built entirely on public interfaces. Identity comes
// from the user's own `com.apple.spaces` preferences, which is a plain read of a
// property list; adding a desktop goes through Mission Control's own
// Accessibility controls, published by the Dock. Neither half uses a private
// API, and neither synthesizes input.
//
// The two halves sit behind their own protocols so a regression can drive the
// directory with a fixture, without this machine's desktops and without touching
// the Dock.

// MARK: - Identity, read from the Spaces preferences

/// One monitor's Spaces bar, in Mission Control's own order. `spaces` includes
/// fullscreen Spaces, because the bar shows them between the desktops and a
/// position that skipped them would not be the position the user sees.
struct SpaceMonitor: Equatable, Sendable {
	/// `"Main"` for the built-in display; a display UUID for the others. It is
	/// the key macOS itself uses, not a `CGDirectDisplayID`.
	let displayIdentifier: String
	let spaces: [SpaceIdentity]
	/// Absent for a monitor macOS currently has no display for. Such a monitor
	/// keeps a collapsed record in the preferences but shows no Spaces bar.
	let currentSpace: SpaceIdentity?

	/// Where a Space sits in this monitor's Spaces bar. Matching is by
	/// `managedID`, which macOS keeps unique and stable for the login session,
	/// so a caller holding a Space whose fullscreen flag has since changed still
	/// resolves it.
	func index(of space: SpaceIdentity) -> Int? {
		spaces.firstIndex { $0.managedID == space.managedID }
	}
}

/// Every monitor the Spaces preferences describe, connected or not.
struct SpaceSnapshot: Equatable, Sendable {
	let monitors: [SpaceMonitor]

	func monitor(displayIdentifier: String) -> SpaceMonitor? {
		monitors.first { $0.displayIdentifier == displayIdentifier }
	}

	func monitor(hosting space: SpaceIdentity) -> SpaceMonitor? {
		monitors.first { $0.index(of: space) != nil }
	}

	/// The Spaces-bar position of a Space on whichever monitor holds it.
	func index(of space: SpaceIdentity) -> Int? {
		monitor(hosting: space)?.index(of: space)
	}

	/// What Mission Control calls this Space, so anything naming a Space names
	/// it the way the person will see it there.
	///
	/// macOS's own label is readable — the Dock publishes each Spaces-bar
	/// button with an `AXDescription` of "Exit to Desktop 2", localized — but
	/// only while Mission Control is on screen. Measured on 2026-09-23: with
	/// Mission Control closed the Dock's whole Accessibility tree is one
	/// `AXList` of `AXDockItem`s, with no Mission Control group and no Spaces
	/// bar, so `spacesBarList()` throws. Reading the real label would mean
	/// taking over the screen, which naming a Space must never do. The number
	/// below is therefore derived, and derived to agree with that label.
	///
	/// Desktops are numbered across every monitor in the order the preferences
	/// list them, not restarted per monitor: on one display the two rules agree,
	/// and on several, restarting would hand two Spaces the same name. Only
	/// desktops are counted, because a fullscreen Space shows its application
	/// in the bar and takes no desktop number.
	///
	/// A fullscreen Space is named by its own `ManagedSpaceID`, because "a
	/// full-screen Space" stops identifying anything the moment two
	/// applications are in full screen, and the application's name is only
	/// readable through the Dock's Accessibility tree — a permission this path
	/// must never reach for. The ID matches nothing on screen, but it is macOS's
	/// own and it is unique.
	///
	/// The live record is re-read by `managedID` rather than trusting the
	/// caller's copy, because a Space that has since become or stopped being
	/// fullscreen keeps its ID while its type changes. A Space the preferences
	/// no longer describe resolves to nothing rather than to a wrong number.
	func name(of space: SpaceIdentity) -> String? {
		let bars: [SpaceIdentity] = monitors.flatMap(\.spaces)
		guard let live: SpaceIdentity = bars.first(where: {
			$0.managedID == space.managedID
		})
		else { return nil }
		guard !live.isFullScreen else {
			return "full-screen Space \(live.managedID)"
		}
		guard let position: Int = bars
			.filter({ !$0.isFullScreen })
			.firstIndex(where: { $0.managedID == live.managedID })
		else { return nil }
		return "Desktop \(position + 1)"
	}

	/// macOS leaves the first desktop of every monitor without a UUID, so an
	/// empty one identifies no single Space and resolves to nothing.
	func space(uuid: String) -> SpaceIdentity? {
		guard !uuid.isEmpty else { return nil }
		for monitor: SpaceMonitor in monitors {
			if let space: SpaceIdentity = monitor.spaces.first(where: {
				$0.uuid == uuid
			}) {
				return space
			}
		}
		return nil
	}
}

enum SpacePreferencesError: Error, Equatable, LocalizedError, Sendable {
	case preferencesUnavailable
	case missingKey(String)
	case unexpectedType(key: String)
	case unknownSpaceType(Int)

	var errorDescription: String? {
		switch self {
		case .preferencesUnavailable:
			return "macOS published no readable com.apple.spaces preferences."
		case .missingKey(let key):
			return "The com.apple.spaces preferences carry no \(key)."
		case .unexpectedType(let key):
			return "The com.apple.spaces preferences give \(key) an unexpected type."
		case .unknownSpaceType(let type):
			return "macOS reported Space type \(type), which Teaser does not know."
		}
	}
}

/// The parser for `com.apple.spaces`. Pure and total: every shape it does not
/// recognize becomes a typed error, so a macOS release that changes the
/// preferences is reported rather than guessed at.
enum SpacePreferences {
	static let suiteName: String = "com.apple.spaces"
	static let configurationKey: String = "SpacesDisplayConfiguration"

	private static let managementDataKey: String = "Management Data"
	private static let monitorsKey: String = "Monitors"
	private static let displayIdentifierKey: String = "Display Identifier"
	private static let spacesKey: String = "Spaces"
	private static let currentSpaceKey: String = "Current Space"
	private static let collapsedSpaceKey: String = "Collapsed Space"
	private static let managedSpaceIDKey: String = "ManagedSpaceID"
	private static let uuidKey: String = "uuid"
	private static let typeKey: String = "type"

	/// macOS's own Space types. Only these two appear at the top level of a
	/// Space entry; the larger numbers in the preferences belong to the nested
	/// tile and window-manager records, which this parser never descends into.
	private static let desktopSpaceType: Int = 0
	private static let fullScreenSpaceType: Int = 4

	static func snapshot(from preferences: [String: Any]) throws -> SpaceSnapshot {
		let configuration: [String: Any] = try dictionary(
			preferences,
			forKey: configurationKey
		)
		let management: [String: Any] = try dictionary(
			configuration,
			forKey: managementDataKey
		)
		guard let rawMonitors: Any = management[monitorsKey] else {
			throw SpacePreferencesError.missingKey(monitorsKey)
		}
		guard let entries = rawMonitors as? [[String: Any]] else {
			throw SpacePreferencesError.unexpectedType(key: monitorsKey)
		}
		return .init(monitors: try entries.map(monitor(from:)))
	}

	private static func monitor(from entry: [String: Any]) throws -> SpaceMonitor {
		let identifier: String = try string(entry, forKey: displayIdentifierKey)
		guard let rawSpaces: Any = entry[spacesKey] else {
			// A monitor with no attached display keeps only its collapsed record.
			// Its identifier still resolves, so a lookup answers "no Spaces bar
			// there" instead of "no such monitor"; anything else is a shape this
			// parser does not know.
			guard entry[collapsedSpaceKey] != nil else {
				throw SpacePreferencesError.missingKey(spacesKey)
			}
			return .init(
				displayIdentifier: identifier,
				spaces: [],
				currentSpace: nil
			)
		}
		guard let spaceEntries = rawSpaces as? [[String: Any]] else {
			throw SpacePreferencesError.unexpectedType(key: spacesKey)
		}
		let current: [String: Any] = try dictionary(entry, forKey: currentSpaceKey)
		return .init(
			displayIdentifier: identifier,
			spaces: try spaceEntries.map(space(from:)),
			currentSpace: try space(from: current)
		)
	}

	/// `Current Space` and each `Spaces` element carry the same shape, so both
	/// arrive here.
	private static func space(from entry: [String: Any]) throws -> SpaceIdentity {
		let type: Int = try integer(entry, forKey: typeKey)
		let isFullScreen: Bool
		switch type {
		case desktopSpaceType: isFullScreen = false
		case fullScreenSpaceType: isFullScreen = true
		default: throw SpacePreferencesError.unknownSpaceType(type)
		}
		return .init(
			managedID: try integer(entry, forKey: managedSpaceIDKey),
			uuid: try string(entry, forKey: uuidKey),
			isFullScreen: isFullScreen
		)
	}

	private static func dictionary(
		_ entry: [String: Any],
		forKey key: String
	) throws -> [String: Any] {
		guard let value: Any = entry[key] else {
			throw SpacePreferencesError.missingKey(key)
		}
		guard let dictionary = value as? [String: Any] else {
			throw SpacePreferencesError.unexpectedType(key: key)
		}
		return dictionary
	}

	private static func string(
		_ entry: [String: Any],
		forKey key: String
	) throws -> String {
		guard let value: Any = entry[key] else {
			throw SpacePreferencesError.missingKey(key)
		}
		guard let string = value as? String else {
			throw SpacePreferencesError.unexpectedType(key: key)
		}
		return string
	}

	private static func integer(
		_ entry: [String: Any],
		forKey key: String
	) throws -> Int {
		guard let value: Any = entry[key] else {
			throw SpacePreferencesError.missingKey(key)
		}
		guard let number = value as? Int else {
			throw SpacePreferencesError.unexpectedType(key: key)
		}
		return number
	}
}

/// Where the Spaces layout comes from. Production reads the user's own
/// preferences; a regression substitutes a fixture.
@MainActor
protocol SpaceDirectorySource: AnyObject {
	func snapshot() throws -> SpaceSnapshot
}

@MainActor
final class PreferencesSpaceDirectorySource: SpaceDirectorySource {
	func snapshot() throws -> SpaceSnapshot {
		try SpacePreferences.snapshot(from: Self.preferences())
	}

	/// `cfprefsd` answers with the live value, so `UserDefaults` is asked first.
	/// The file on disk is written back on macOS's own schedule and can lag a
	/// Space created a moment ago, which makes it the fallback rather than the
	/// source.
	private static func preferences() throws -> [String: Any] {
		if let defaults = UserDefaults(suiteName: SpacePreferences.suiteName),
			let configuration: [String: Any] = defaults.dictionary(
				forKey: SpacePreferences.configurationKey
			)
		{
			return [SpacePreferences.configurationKey: configuration]
		}
		let url: URL = FileManager.default.homeDirectoryForCurrentUser
			.appending(path: "Library/Preferences/\(SpacePreferences.suiteName).plist")
		guard let data: Data = try? Data(contentsOf: url),
			let plist = try? PropertyListSerialization.propertyList(
				from: data,
				options: [],
				format: nil
			),
			let preferences = plist as? [String: Any]
		else {
			throw SpacePreferencesError.preferencesUnavailable
		}
		return preferences
	}
}

// MARK: - Mission Control's own Spaces-bar controls

enum SpacesBarError: Error, Equatable, LocalizedError, Sendable {
	case accessibilityPermissionRequired
	case dockNotRunning
	case missionControlUnavailable
	case spacesBarUnavailable
	case spacesBarEmpty
	case foreignElement
	case spaceButtonOutOfRange(index: Int, count: Int)
	/// The button was pressed and macOS stayed where it was, which is what a bar
	/// belonging to another display looks like from here.
	case spaceDidNotActivate
	case accessibilityOperationFailed(operation: String, code: AXError)

	/// Every message ends the same way on purpose: when Teaser cannot drive the
	/// Spaces bar there is one reliable remedy, and the person should be told it
	/// rather than left with a failure.
	var errorDescription: String? {
		let remedy: String = "Add a desktop yourself in Mission Control."
		switch self {
		case .accessibilityPermissionRequired:
			return "Teaser needs Accessibility permission to use Mission Control's "
				+ "Spaces bar. \(remedy)"
		case .dockNotRunning:
			return "macOS reports no Dock process, so Mission Control's Spaces bar "
				+ "cannot be reached. \(remedy)"
		case .missionControlUnavailable:
			return "Mission Control is not showing. \(remedy)"
		case .spacesBarUnavailable:
			return "Mission Control is not publishing its Spaces bar where macOS "
				+ "documents it. \(remedy)"
		case .spacesBarEmpty:
			return "Mission Control's Spaces bar published no button Teaser "
				+ "recognizes. \(remedy)"
		case .foreignElement:
			return "That Accessibility element does not belong to the Dock, so "
				+ "Teaser will not press it. \(remedy)"
		case .spaceButtonOutOfRange(let index, let count):
			return "Mission Control's Spaces bar has \(count) Spaces, so position "
				+ "\(index) does not exist. \(remedy)"
		case .spaceDidNotActivate:
			return "Mission Control did not switch to that Space, so its bar most "
				+ "likely belongs to another display. \(remedy)"
		case .accessibilityOperationFailed(let operation, let code):
			return "Accessibility operation \(operation) failed with \(code). "
				+ remedy
		}
	}
}

/// What a button in the Spaces bar does. Mission Control labels each button with
/// its action, which is the only thing that distinguishes a Space from the
/// add-desktop control — they share a role and a parent list.
enum SpacesBarButtonKind: Equatable, Sendable {
	case space
	case addDesktop
	case unrecognized
}

// Teaser reads the bar the user's own system localized, so every name is matched
// against the localization observed on macOS 26 and against its English
// equivalent. Comparison is lowercased, which leaves the Chinese names untouched.
private let missionControlNames: [String] = ["调度中心", "mission control"]
private let spacesBarNames: [String] = ["空间栏", "spaces bar"]
private let addDesktopNames: [String] = ["添加桌面", "add desktop"]
private let spaceButtonPrefixes: [String] = ["退出到", "exit to"]

/// Classifies one Spaces-bar button from the labels macOS gives it. Pure, so the
/// rule that decides what Teaser is about to press is checkable without a Dock.
func spacesBarButtonKind(description: String?, title: String?) -> SpacesBarButtonKind {
	let labels: [String] = [description, title]
		.compactMap { $0 }
		.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
	if labels.contains(where: { label in
		addDesktopNames.contains(where: label.hasPrefix)
	}) {
		return .addDesktop
	}
	if labels.contains(where: { label in
		spaceButtonPrefixes.contains(where: label.hasPrefix)
	}) {
		return .space
	}
	return .unrecognized
}

/// The Spaces bar's buttons and the press that activates one. Opening Mission
/// Control is the caller's business; everything here assumes the bar is already
/// on screen and fails with a typed error when it is not.
@MainActor
protocol SpacesBarControls: AnyObject {
	/// The Space buttons in Spaces-bar order, add-desktop excluded.
	func spacesBarButtons() throws -> [AXUIElement]
	/// Nil when Mission Control is not currently offering the control; macOS
	/// publishes it only while the bar is expanded.
	func addDesktopButton() throws -> AXUIElement?
	func press(_ element: AXUIElement) throws
}

/// One Spaces-bar button with the meaning its labels gave it.
private struct ClassifiedSpacesBarButton {
	let element: AXUIElement
	let kind: SpacesBarButtonKind
}

/// Mission Control's Spaces bar, addressed through the Dock's own Accessibility
/// hierarchy: Mission Control group, its group, the Spaces-bar group, its list.
/// Addressing the bar by that path rather than walking the Dock's whole tree
/// keeps the read to a handful of round trips and keeps a wrong match from ever
/// being pressed.
@MainActor
final class DockSpacesBar: SpacesBarControls {
	static let dockBundleIdentifier: String = "com.apple.dock"

	func spacesBarButtons() throws -> [AXUIElement] {
		let spaces: [AXUIElement] = try classifiedButtons()
			.filter { $0.kind == .space }
			.map { $0.element }
		// A bar whose buttons none of the known labels match is a bar Teaser
		// cannot read. Pressing an unrecognized button would switch the user's
		// Space at random, so this fails closed instead.
		guard !spaces.isEmpty else { throw SpacesBarError.spacesBarEmpty }
		return spaces
	}

	func addDesktopButton() throws -> AXUIElement? {
		try classifiedButtons().first { $0.kind == .addDesktop }?.element
	}

	func press(_ element: AXUIElement) throws {
		let dock: pid_t = try Self.dockProcessIdentifier()
		var owner: pid_t = 0
		guard AXUIElementGetPid(element, &owner) == .success, owner == dock else {
			throw SpacesBarError.foreignElement
		}
		let error: AXError = AXUIElementPerformAction(element, kAXPressAction as CFString)
		guard error == .success else {
			throw SpacesBarError.accessibilityOperationFailed(
				operation: "press a Spaces bar button",
				code: error
			)
		}
	}

	private func classifiedButtons() throws -> [ClassifiedSpacesBarButton] {
		let list: AXUIElement = try spacesBarList()
		let buttons: [AXUIElement] = try Self.children(of: list).filter {
			Self.string(kAXRoleAttribute, of: $0) == kAXButtonRole
		}
		guard !buttons.isEmpty else { throw SpacesBarError.spacesBarEmpty }
		return buttons.map { element in
			ClassifiedSpacesBarButton(
				element: element,
				kind: spacesBarButtonKind(
					description: Self.string(kAXDescriptionAttribute, of: element),
					title: Self.string(kAXTitleAttribute, of: element)
				)
			)
		}
	}

	private func spacesBarList() throws -> AXUIElement {
		let dock: AXUIElement = try Self.dockApplicationElement()
		guard let missionControl: AXUIElement = try Self.child(
			of: dock,
			role: kAXGroupRole,
			namedAnyOf: missionControlNames
		) else {
			throw SpacesBarError.missionControlUnavailable
		}
		// Mission Control publishes one group of its own, and the Spaces bar
		// hangs off that group rather than off Mission Control directly.
		guard let stage: AXUIElement = try Self.child(
			of: missionControl,
			role: kAXGroupRole
		),
			let bar: AXUIElement = try Self.child(
				of: stage,
				role: kAXGroupRole,
				namedAnyOf: spacesBarNames
			),
			let list: AXUIElement = try Self.child(of: bar, role: kAXListRole)
		else {
			throw SpacesBarError.spacesBarUnavailable
		}
		return list
	}

	private static func dockProcessIdentifier() throws -> pid_t {
		guard let dock: NSRunningApplication = NSWorkspace.shared.runningApplications
			.first(where: { $0.bundleIdentifier == dockBundleIdentifier })
		else {
			throw SpacesBarError.dockNotRunning
		}
		return dock.processIdentifier
	}

	private static func dockApplicationElement() throws -> AXUIElement {
		// Reading the trust state never prompts. Teaser asks for Accessibility
		// where the user starts the work that needs it, not from here.
		guard AXIsProcessTrusted() else {
			throw SpacesBarError.accessibilityPermissionRequired
		}
		let element: AXUIElement = AXUIElementCreateApplication(
			try dockProcessIdentifier()
		)
		// A busy Dock must not hold the main thread while Mission Control animates.
		AXUIElementSetMessagingTimeout(element, 0.75)
		return element
	}

	private static func child(
		of element: AXUIElement,
		role: String,
		namedAnyOf names: [String] = []
	) throws -> AXUIElement? {
		try children(of: element).first {
			string(kAXRoleAttribute, of: $0) == role
				&& (names.isEmpty || matches($0, anyOf: names))
		}
	}

	private static func matches(_ element: AXUIElement, anyOf names: [String]) -> Bool {
		let labels: [String] = [
			string(kAXTitleAttribute, of: element),
			string(kAXDescriptionAttribute, of: element),
		]
		.compactMap { $0 }
		.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
		return labels.contains { names.contains($0) }
	}

	private static func children(of element: AXUIElement) throws -> [AXUIElement] {
		var raw: CFTypeRef?
		let error: AXError = AXUIElementCopyAttributeValue(
			element,
			kAXChildrenAttribute as CFString,
			&raw
		)
		guard error == .success else {
			throw SpacesBarError.accessibilityOperationFailed(
				operation: "read Spaces bar children",
				code: error
			)
		}
		return raw as? [AXUIElement] ?? []
	}

	private static func string(_ attribute: String, of element: AXUIElement) -> String? {
		var raw: CFTypeRef?
		guard AXUIElementCopyAttributeValue(
			element,
			attribute as CFString,
			&raw
		) == .success else {
			return nil
		}
		return raw as? String
	}
}

// MARK: - The directory the rest of the app uses

/// Teaser's Space awareness in one handle: which Spaces exist and where they sit
/// in the bar, and — only when the person asks for one — a new desktop through
/// Mission Control's own controls. `AXUIElement` stops here; nothing above this
/// type handles an Accessibility reference.
@MainActor
final class SpaceDirectory {
	private let source: any SpaceDirectorySource
	private let controls: any SpacesBarControls

	init(
		source: any SpaceDirectorySource = PreferencesSpaceDirectorySource(),
		controls: any SpacesBarControls = DockSpacesBar()
	) {
		self.source = source
		self.controls = controls
	}

	/// Read fresh every time: Spaces come and go while Teaser runs, and a cached
	/// bar order would place a canvas on a Space the user already closed.
	func snapshot() throws -> SpaceSnapshot {
		try source.snapshot()
	}

	func index(of space: SpaceIdentity) throws -> Int? {
		try snapshot().index(of: space)
	}

	func currentSpace(ofDisplayIdentifier identifier: String) throws -> SpaceIdentity? {
		try snapshot().monitor(displayIdentifier: identifier)?.currentSpace
	}

	/// Presses Mission Control's add-desktop button, and reports false when
	/// Mission Control is not offering it. Never retried and never replaced with
	/// synthesized input: the error tells the person to add the desktop.
	@discardableResult
	func addDesktop() throws -> Bool {
		guard let button: AXUIElement = try controls.addDesktopButton() else {
			return false
		}
		try controls.press(button)
		return true
	}

	/// Switches to a Space by pressing its button in the bar.
	///
	/// The position comes from the preferences, the button from Mission Control,
	/// and the two only line up while the bar shows exactly the Spaces of the
	/// monitor that holds this one. When they disagree — another display's bar,
	/// or a Space added since the read — pressing by position would switch the
	/// person to a Space they never asked for, so this fails closed instead.
	func activate(_ space: SpaceIdentity) throws {
		let snapshot: SpaceSnapshot = try self.snapshot()
		guard let monitor: SpaceMonitor = snapshot.monitor(hosting: space),
			let index: Int = monitor.index(of: space)
		else {
			throw SpacesBarError.spaceButtonOutOfRange(index: 0, count: 0)
		}
		let buttons: [AXUIElement] = try controls.spacesBarButtons()
		guard buttons.count == monitor.spaces.count, buttons.indices.contains(index) else {
			throw SpacesBarError.spaceButtonOutOfRange(
				index: index,
				count: buttons.count
			)
		}
		try controls.press(buttons[index])
		// Matching counts does not prove the bar belongs to this monitor: two
		// displays with the same number of Spaces would pass it. So the press is
		// checked against what macOS says afterwards rather than assumed.
		guard try currentSpace(ofDisplayIdentifier: monitor.displayIdentifier) == space else {
			throw SpacesBarError.spaceDidNotActivate
		}
	}
}
