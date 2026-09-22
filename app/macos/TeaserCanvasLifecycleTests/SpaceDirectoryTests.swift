import Foundation
@testable import TeaserKit

// The Spaces-preferences parser, checked against the shape macOS actually
// writes: several monitors, a fullscreen Space in bar order, the first desktop
// that macOS leaves without a UUID, and a monitor whose display is gone. Nothing
// here reads this machine's preferences or touches the Dock, so the fixture is
// the only Spaces layout these cases know.

private let mainDisplayIdentifier: String = "Main"
private let collapsedDisplayIdentifier: String = "73FCD5F0-74D7-486C-ACA3-D1FE4A04DC36"
private let secondDisplayIdentifier: String = "9BDDEE86-8AAF-4FE0-B43D-0DD3C2E949DF"
private let fullScreenUUID: String = "B6CDDFAC-D582-49C8-BD17-BCADA5A50450"
private let secondDesktopUUID: String = "5368EE59-48D3-4A8A-BFC8-03849DC7EA46"
private let otherMonitorDesktopUUID: String = "70141F57-11E1-4C38-9E4C-80903D0A51A5"

/// One `Spaces` element. The values are `Any` so a malformed case can put the
/// wrong type in one field without a second builder, and `id64` is carried
/// because macOS writes it and the parser must ignore it.
private func makeSpaceEntry(managedID: Any, uuid: Any, type: Any) -> [String: Any] {
	["ManagedSpaceID": managedID, "id64": managedID, "uuid": uuid, "type": type]
}

/// The first desktop as macOS writes it: no UUID, and a nested window-manager
/// record that carries `type` values of its own. A parser that recursed would
/// read one of those instead of the Space's own type.
private func makeFirstDesktopEntry() -> [String: Any] {
	var entry: [String: Any] = makeSpaceEntry(managedID: 1, uuid: "", type: 0)
	let windowSet: [String: Any] = [
		"type": 5,
		"uuid": "0405C544-2100-462F-A5E0-22BB1DBE6F4C",
	]
	let windowSets: [String: Any] = [
		"4A34AEB4-3F9B-99B8-EFA8-0D2B9962E57A": [windowSet]
	]
	entry["WindowManagerInfo"] = ["windowSets": windowSets] as [String: Any]
	return entry
}

private func makeMainSpaces() -> [[String: Any]] {
	[
		makeFirstDesktopEntry(),
		makeSpaceEntry(managedID: 280, uuid: fullScreenUUID, type: 4),
		makeSpaceEntry(managedID: 328, uuid: secondDesktopUUID, type: 0),
	]
}

private func makePreferences(monitors: [[String: Any]]) -> [String: Any] {
	[
		"SpacesDisplayConfiguration": [
			"Management Data": [
				"Management Mode": 1,
				"Monitors": monitors,
			] as [String: Any]
		] as [String: Any]
	]
}

private func makeMonitors() -> [[String: Any]] {
	[
		[
			"Display Identifier": mainDisplayIdentifier,
			"Spaces": makeMainSpaces(),
			// Mission Control's fullscreen Space is the one in front.
			"Current Space": makeSpaceEntry(
				managedID: 280,
				uuid: fullScreenUUID,
				type: 4
			),
		],
		// A monitor macOS has no attached display for keeps only this record.
		[
			"Display Identifier": collapsedDisplayIdentifier,
			"Collapsed Space": makeSpaceEntry(
				managedID: 171,
				uuid: "C9F9FE6A-B772-4C96-B1E1-E69DD9E3139E",
				type: 0
			),
		],
		[
			"Display Identifier": secondDisplayIdentifier,
			"Spaces": [
				makeSpaceEntry(managedID: 27, uuid: otherMonitorDesktopUUID, type: 0)
			],
			"Current Space": makeSpaceEntry(
				managedID: 27,
				uuid: otherMonitorDesktopUUID,
				type: 0
			),
		],
	]
}

private func makeFixture() -> [String: Any] {
	makePreferences(monitors: makeMonitors())
}

/// Asserts the exact typed error, not merely that the parser refused. A case
/// that only checked "it threw" would pass on the wrong diagnosis.
private func expectRejection(
	_ preferences: [String: Any],
	_ expected: SpacePreferencesError,
	_ message: String
) throws {
	do {
		_ = try SpacePreferences.snapshot(from: preferences)
	} catch let error as SpacePreferencesError {
		try expect(error == expected, "\(message): reported \(error)")
		return
	}
	throw TestFailure.assertion("\(message): the parser accepted the input")
}

@MainActor
private func testParsesEveryMonitorInSpacesBarOrder() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	try expect(snapshot.monitors.count == 3, "every monitor entry must be parsed")
	let main: SpaceMonitor = try unwrap(
		snapshot.monitor(displayIdentifier: mainDisplayIdentifier),
		"the built-in display is keyed by the literal identifier Main"
	)
	try expect(
		main.spaces.map(\.managedID) == [1, 280, 328],
		"Spaces keep the Mission Control bar order macOS wrote"
	)
	try expect(
		main.spaces.map(\.isFullScreen) == [false, true, false],
		"a type 4 entry is the fullscreen Space between the two desktops"
	)
	try expect(
		main.spaces[0].uuid.isEmpty,
		"macOS leaves the first desktop without a UUID"
	)
	try expect(
		main.spaces[1].uuid == fullScreenUUID,
		"a Space keeps its own UUID, not one from a nested record"
	)
}

@MainActor
private func testResolvesTheCurrentSpaceOfEachMonitor() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	let main: SpaceIdentity = try unwrap(
		snapshot.monitor(displayIdentifier: mainDisplayIdentifier)?.currentSpace,
		"a connected monitor reports the Space in front"
	)
	try expect(
		main == .init(managedID: 280, uuid: fullScreenUUID, isFullScreen: true),
		"the current Space is parsed with the same shape as a bar entry"
	)
	let second: SpaceIdentity = try unwrap(
		snapshot.monitor(displayIdentifier: secondDisplayIdentifier)?.currentSpace,
		"each monitor carries its own current Space"
	)
	try expect(second.managedID == 27, "monitors do not share a current Space")
}

@MainActor
private func testCollapsedMonitorResolvesWithNoSpacesBar() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	let collapsed: SpaceMonitor = try unwrap(
		snapshot.monitor(displayIdentifier: collapsedDisplayIdentifier),
		"a monitor whose display is gone still resolves by identifier"
	)
	try expect(collapsed.spaces.isEmpty, "a collapsed monitor shows no Spaces bar")
	try expect(
		collapsed.currentSpace == nil,
		"a monitor with no display has no Space in front"
	)
}

@MainActor
private func testResolvesSpacesBarPositionByUUID() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	let fullScreen: SpaceIdentity = try unwrap(
		snapshot.space(uuid: fullScreenUUID),
		"a Space resolves from the UUID macOS wrote for it"
	)
	try expect(
		snapshot.index(of: fullScreen) == 1,
		"a fullscreen Space occupies its own position in the bar"
	)
	let secondDesktop: SpaceIdentity = try unwrap(
		snapshot.space(uuid: secondDesktopUUID),
		"the desktop after a fullscreen Space resolves too"
	)
	try expect(
		snapshot.index(of: secondDesktop) == 2,
		"positions count fullscreen Spaces, because the bar shows them"
	)
	let otherMonitor: SpaceIdentity = try unwrap(
		snapshot.space(uuid: otherMonitorDesktopUUID),
		"a Space on another monitor resolves from the same snapshot"
	)
	try expect(
		snapshot.index(of: otherMonitor) == 0,
		"a position is read within the monitor that hosts the Space"
	)
	try expect(
		snapshot.space(uuid: "") == nil,
		"an empty UUID names the first desktop of every monitor, so it names none"
	)
}

@MainActor
private func testMalformedPreferencesReportTheirOwnKey() throws {
	try expectRejection(
		["SpacesDisplayConfiguration": [String: Any]()],
		.missingKey("Management Data"),
		"an absent Management Data is named"
	)
	try expectRejection(
		[
			"SpacesDisplayConfiguration": [
				"Management Data": ["Monitors": "none"] as [String: Any]
			] as [String: Any]
		],
		.unexpectedType(key: "Monitors"),
		"Monitors that is not an array is a type failure, not an empty desktop"
	)
	try expectRejection(
		makePreferences(monitors: [["Spaces": makeMainSpaces()]]),
		.missingKey("Display Identifier"),
		"a monitor without its identifier cannot be addressed"
	)
	try expectRejection(
		makePreferences(monitors: [["Display Identifier": mainDisplayIdentifier]]),
		.missingKey("Spaces"),
		"a monitor that is neither connected nor collapsed is an unknown shape"
	)
}

@MainActor
private func testMalformedSpaceEntriesReportTheirOwnField() throws {
	try expectRejection(
		makePreferences(monitors: [
			[
				"Display Identifier": mainDisplayIdentifier,
				"Spaces": [makeSpaceEntry(managedID: 1, uuid: "", type: "0")],
				"Current Space": makeSpaceEntry(managedID: 1, uuid: "", type: 0),
			]
		]),
		.unexpectedType(key: "type"),
		"a Space type written as text is never coerced to a number"
	)
	try expectRejection(
		makePreferences(monitors: [
			[
				"Display Identifier": mainDisplayIdentifier,
				"Spaces": [["uuid": "", "type": 0] as [String: Any]],
				"Current Space": makeSpaceEntry(managedID: 1, uuid: "", type: 0),
			]
		]),
		.missingKey("ManagedSpaceID"),
		"a Space without its managed ID cannot be identified"
	)
	try expectRejection(
		makePreferences(monitors: [
			[
				"Display Identifier": mainDisplayIdentifier,
				"Spaces": [makeSpaceEntry(managedID: 9, uuid: "", type: 7)],
				"Current Space": makeSpaceEntry(managedID: 9, uuid: "", type: 7),
			]
		]),
		.unknownSpaceType(7),
		"a Space type Teaser has not verified is reported, not guessed at"
	)
}

@MainActor
private func testClassifiesSpacesBarButtonsInBothLocalizations() throws {
	try expect(
		spacesBarButtonKind(description: "退出到桌面 1", title: nil) == .space,
		"a localized Space button is recognized by the action it names"
	)
	try expect(
		spacesBarButtonKind(description: "Exit to Desktop 2", title: nil) == .space,
		"the English Space button is recognized the same way"
	)
	try expect(
		spacesBarButtonKind(description: "添加桌面", title: nil) == .addDesktop,
		"the localized add-desktop button is never taken for a Space"
	)
	try expect(
		spacesBarButtonKind(description: nil, title: "add desktop") == .addDesktop,
		"macOS may label the add button by title instead of description"
	)
	try expect(
		spacesBarButtonKind(description: "Dock", title: nil) == .unrecognized,
		"an unfamiliar button stays unrecognized rather than being pressed"
	)
	try expect(
		spacesBarButtonKind(description: nil, title: nil) == .unrecognized,
		"a button with no label at all is not a Space"
	)
}

/// A Space has to be nameable the way the person sees it in Mission Control,
/// or naming it sends them looking for something that is not there. Desktops
/// count only desktops: the fullscreen Space sits between them in the bar and
/// takes no desktop number, so the desktop after it is Desktop 2, not 3.
@MainActor
private func testNamesSpacesTheWayMissionControlDoes() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	try expect(
		snapshot.name(of: .init(managedID: 1, uuid: "", isFullScreen: false))
			== "Desktop 1",
		"the first desktop, which macOS leaves without a UUID, is Desktop 1"
	)
	try expect(
		snapshot.name(
			of: .init(managedID: 328, uuid: secondDesktopUUID, isFullScreen: false)
		) == "Desktop 2",
		"a fullscreen Space in bar order must not consume a desktop number"
	)
	// A fullscreen Space has a ManagedSpaceID like any other, and saying only
	// that it is fullscreen identifies nothing once two applications are.
	try expect(
		snapshot.name(
			of: .init(managedID: 280, uuid: fullScreenUUID, isFullScreen: true)
		) == "full-screen Space 280",
		"a fullscreen Space is named by its own ID, not merely as fullscreen"
	)
	try expect(
		snapshot.name(
			of: .init(managedID: 27, uuid: otherMonitorDesktopUUID, isFullScreen: false)
		) == "Desktop 1",
		"desktops are numbered per monitor, which is the bar the person sees"
	)
}

/// The caller's copy of a Space can be out of date — a Space keeps its ID
/// while becoming or ceasing to be fullscreen — so the live record decides,
/// and a Space macOS no longer describes is named nothing rather than wrongly.
@MainActor
private func testSpaceNamingReadsTheLiveRecord() throws {
	let snapshot: SpaceSnapshot = try SpacePreferences.snapshot(from: makeFixture())
	try expect(
		snapshot.name(
			of: .init(managedID: 280, uuid: fullScreenUUID, isFullScreen: false)
		) == "full-screen Space 280",
		"a stale fullscreen flag must not turn a fullscreen Space into a desktop"
	)
	try expect(
		snapshot.name(
			of: .init(managedID: 9_999, uuid: "", isFullScreen: false)
		) == nil,
		"a Space the preferences no longer describe is named nothing"
	)
	try expect(
		snapshot.name(
			of: .init(managedID: 171, uuid: "C9F9FE6A-B772-4C96-B1E1-E69DD9E3139E", isFullScreen: false)
		) == nil,
		"a collapsed monitor shows no bar, so its Space has no position to name"
	)
}

func spaceDirectoryCases() -> [TestCase] {
	[
		.init(
			"Spaces preferences parse into Mission Control bar order",
			testParsesEveryMonitorInSpacesBarOrder
		),
		.init(
			"each monitor reports its own current Space",
			testResolvesTheCurrentSpaceOfEachMonitor
		),
		.init(
			"a monitor with no display resolves with no Spaces bar",
			testCollapsedMonitorResolvesWithNoSpacesBar
		),
		.init(
			"a Space UUID resolves to its Spaces bar position",
			testResolvesSpacesBarPositionByUUID
		),
		.init(
			"malformed Spaces preferences name the key that failed",
			testMalformedPreferencesReportTheirOwnKey
		),
		.init(
			"malformed Space entries name the field that failed",
			testMalformedSpaceEntriesReportTheirOwnField
		),
		.init(
			"Spaces are named the way Mission Control names them",
			testNamesSpacesTheWayMissionControlDoes
		),
		.init(
			"Space naming reads the live record, not the caller's copy",
			testSpaceNamingReadsTheLiveRecord
		),
		.init(
			"Spaces bar buttons classify in both localizations",
			testClassifiesSpacesBarButtonsInBothLocalizations
		),
	]
}
