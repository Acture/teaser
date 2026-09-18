import ApplicationServices
import CoreGraphics
import Foundation
@testable import TeaserKit

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message): return message
		}
	}
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

private func expectFrame(
	_ actual: CGRect,
	_ expected: CGRect,
	message: String
) throws {
	try expect(
		managedExternalWindowFramesAreApproximatelyEqual(
			actual,
			expected,
			tolerance: 0.000_001
		),
		"\(message): expected \(expected), got \(actual)"
	)
}

private func cgWindow(
	_ id: CGWindowID,
	pid: pid_t = 42,
	layer: Int = 0,
	isOnscreen: Bool = true,
	ownerIsRegularApplication: Bool = true,
	frame: CGRect
) -> ExternalWindowCurrentSpaceWindow {
	.init(
		identity: .init(processIdentifier: pid, windowID: id),
		layer: layer,
		isOnscreen: isOnscreen,
		ownerIsRegularApplication: ownerIsRegularApplication,
		accessibilityFrame: frame
	)
}

private func dragSample(
	mouseX: CGFloat,
	mouseY: CGFloat,
	windowX: CGFloat,
	windowY: CGFloat,
	width: CGFloat = 800,
	height: CGFloat = 600
) -> ExternalWindowDragSample {
	.init(
		mouseAppKitScreenLocation: .init(x: mouseX, y: mouseY),
		windowAppKitScreenFrame: .init(
			x: windowX,
			y: windowY,
			width: width,
			height: height
		)
	)
}

private func testCoordinateConversion() throws {
	let menuBarScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
	let appKitFrame = CGRect(x: 100, y: 120, width: 800, height: 600)
	let accessibilityFrame = managedExternalWindowAccessibilityFrame(
		fromAppKitScreenFrame: appKitFrame,
		menuBarScreenFrame: menuBarScreen
	)
	try expectFrame(
		accessibilityFrame,
		.init(x: 100, y: 360, width: 800, height: 600),
		message: "primary display conversion"
	)
	try expectFrame(
		managedExternalWindowAppKitScreenFrame(
			fromAccessibilityFrame: accessibilityFrame,
			menuBarScreenFrame: menuBarScreen
		),
		appKitFrame,
		message: "coordinate conversion round trip"
	)
	try expect(
		managedExternalWindowAccessibilityPoint(
			fromAppKitScreenPoint: .init(x: -200, y: 1_200),
			menuBarScreenFrame: menuBarScreen
		) == .init(x: -200, y: -120),
		"screen points must support negative and upper-display coordinates"
	)
}

private func testWindowIdentitySelectsOneExactWindowID() throws {
	try expect(
		externalWindowUniqueIndex(ofWindowID: 202, in: [101, 202, 303]) == 1,
		"an exact window ID must select its own Accessibility element"
	)
	try expect(
		externalWindowUniqueIndex(ofWindowID: 404, in: [101, 202, nil]) == nil,
		"an identity absent from the element list must not select a neighbor"
	)
	try expect(
		externalWindowUniqueIndex(ofWindowID: 101, in: [101, 101]) == nil,
		"duplicate window IDs must fail closed instead of picking the first"
	)
	try expect(
		externalWindowUniqueIndex(ofWindowID: 101, in: [nil, nil]) == nil,
		"elements whose window ID macOS refuses are never selectable"
	)
	try expect(
		externalWindowUniqueIndex(ofWindowID: kCGNullWindowID, in: [nil]) == nil,
		"the null window ID never matches an element without one"
	)
}

private func pickerCandidate(
	_ windowID: CGWindowID,
	application: String,
	title: String? = nil,
	pid: pid_t = 42,
	visible: Bool = true,
	size: CGSize = .init(width: 800, height: 600),
	rejection: String? = nil
) -> ExternalWindowCandidate {
	.init(
		identity: .init(processIdentifier: pid, windowID: windowID),
		applicationName: application,
		bundleIdentifier: "com.example.\(application)",
		windowTitle: title,
		appKitScreenFrame: .init(origin: .zero, size: size),
		isVisibleOnCurrentSpace: visible,
		rejectionReason: rejection
	)
}

private func testPickerRowsOrderAndDescribeCandidates() throws {
	let rows = externalWindowPickerRows(candidates: [
		pickerCandidate(4, application: "Zed", title: "empty project", visible: false),
		pickerCandidate(1, application: "Warp", rejection: "full-screen"),
		pickerCandidate(3, application: "TextEdit", visible: false),
		pickerCandidate(2, application: "TextEdit"),
	])
	try expect(
		rows.map(\.candidate.identity.windowID) == [2, 3, 4, 1],
		"adoptable windows come first, then application name, then visible before hidden: \(rows.map(\.candidate.identity.windowID))"
	)
	try expect(
		rows[0].primaryText == "TextEdit" && rows[0].secondaryText == "800 × 600 · On screen",
		"a window without a title reads as its application, size, and state: \(rows[0])"
	)
	try expect(
		rows[2].primaryText == "empty project"
			&& rows[2].secondaryText == "Zed · 800 × 600 · Hidden",
		"a titled hidden window names its application and says it is hidden: \(rows[2])"
	)
	try expect(
		!rows[3].isAdoptable && rows[3].candidate.rejectionReason == "full-screen",
		"a rejected candidate stays in the list carrying its reason"
	)
}

private func testPickerFiltersAndDeduplicates() throws {
	let candidates: [ExternalWindowCandidate] = [
		pickerCandidate(2, application: "TextEdit", title: "Notes"),
		pickerCandidate(2, application: "TextEdit", title: "Notes"),
		pickerCandidate(5, application: "Warp", title: "~/repos"),
	]
	try expect(
		externalWindowPickerRows(candidates: candidates).count == 2,
		"the same window must appear once"
	)
	try expect(
		externalWindowPickerRows(candidates: candidates, query: "  TEXTedit ")
			.map(\.candidate.identity.windowID) == [2],
		"a query matches the application name regardless of case or padding"
	)
	try expect(
		externalWindowPickerRows(candidates: candidates, query: "repos")
			.map(\.candidate.identity.windowID) == [5],
		"a query matches the window title"
	)
	try expect(
		externalWindowPickerRows(candidates: candidates, query: "nothing").isEmpty,
		"a query that matches nothing yields no rows"
	)
	try expect(
		externalWindowPickerDetail(for: pickerCandidate(
			9, application: "Preview", size: .init(width: CGFloat.infinity, height: 600)
		)) == "unknown size · On screen",
		"a non-finite frame must not be rendered as a number"
	)
}

private func testPlacementLandsWhenTheProviderKeepsTheCorner() throws {
	let requested: CGRect = .init(x: 382, y: 166, width: 370.7, height: 516.2)
	try expect(
		managedExternalWindowPlacementLanded(
			applied: .init(x: 382, y: 166, width: 534, height: 516), requested: requested
		),
		"a provider that widens to its own minimum at the requested corner has been placed"
	)
	try expect(
		managedExternalWindowPlacementLanded(
			applied: .init(x: 383.5, y: 164.5, width: 200, height: 200), requested: requested
		),
		"a corner within tolerance has been placed, whatever size the provider took"
	)
	try expect(
		!managedExternalWindowPlacementLanded(
			applied: .init(x: 900, y: 166, width: 370.7, height: 516.2), requested: requested
		),
		"a window that did not move to the requested corner refused the write"
	)
}

private func testLargeWindowIsAimedByItsBody() throws {
	let left = ExternalWindowPanelGeometry(
		panelID: "left", appKitScreenFrame: .init(x: 0, y: 0, width: 600, height: 800),
		isOccupied: false
	)
	let right = ExternalWindowPanelGeometry(
		panelID: "right", appKitScreenFrame: .init(x: 610, y: 0, width: 600, height: 800),
		isOccupied: true
	)
	let outside: CGPoint = .init(x: 400, y: 950)
	try expect(
		externalWindowPanelDropTarget(
			pointer: outside, windowFrame: .init(x: 100, y: 100, width: 400, height: 600),
			panels: [left, right]
		) == .init(panelID: "left", region: .empty),
		"with the pointer off the canvas, the Panel under the window's centre is the target"
	)
	try expect(
		externalWindowPanelDropTarget(
			pointer: outside, windowFrame: .init(x: 560, y: 700, width: 900, height: 400),
			panels: [left, right]
		) == nil,
		"a window that only grazes the layout has no target, so it can be dragged out"
	)
	try expect(
		externalWindowPanelDropTarget(
			pointer: outside, windowFrame: .init(x: 700, y: 100, width: 400, height: 600),
			panels: [left, right]
		) == .init(panelID: "right", region: .center),
		"an occupied Panel under the centre is a whole-Panel target"
	)
	try expect(
		externalWindowPanelDropTarget(
			pointer: outside, windowFrame: .init(x: 2_000, y: 2_000, width: 400, height: 300),
			panels: [left, right]
		) == nil,
		"a window over no Panel at all has no target"
	)
	try expect(
		externalWindowPanelDropTarget(
			pointer: .init(x: 1_190, y: 400), windowFrame: .init(x: 100, y: 100, width: 400, height: 600),
			panels: [left, right]
		) == .init(panelID: "right", region: .trailing),
		"when the pointer is over a Panel it still decides, so edge splits stay aimable"
	)
}

private func testPanelTargetSemantics() throws {
	let empty = ExternalWindowPanelGeometry(
		panelID: "empty",
		appKitScreenFrame: .init(x: 0, y: 0, width: 400, height: 300),
		isOccupied: false
	)
	try expect(
		externalWindowPanelDropTarget(
			at: .init(x: 2, y: 150),
			panels: [empty]
		) == .init(panelID: "empty", region: .empty),
		"an empty panel must be one whole replacement target"
	)

	let occupied = ExternalWindowPanelGeometry(
		panelID: "occupied",
		appKitScreenFrame: .init(x: 500, y: 100, width: 600, height: 400),
		isOccupied: true
	)
	let probes: [(CGPoint, ExternalWindowPanelDropRegion)] = [
		(.init(x: 800, y: 300), .center),
		(.init(x: 505, y: 300), .leading),
		(.init(x: 1_095, y: 300), .trailing),
		(.init(x: 800, y: 495), .top),
		(.init(x: 800, y: 105), .bottom),
		(.init(x: 510, y: 130), .leading),
	]
	for (point, expectedRegion) in probes {
		try expect(
			externalWindowPanelDropTarget(at: point, panels: [occupied])
				== .init(panelID: "occupied", region: expectedRegion),
			"occupied panel target at \(point) must be \(expectedRegion)"
		)
	}
	try expect(
		externalWindowPanelDropTarget(
			at: .init(x: 450, y: 300),
			panels: [occupied]
		) == nil,
		"a point outside every panel must not create a target"
	)
}

private func testPanelOverlapFailsClosed() throws {
	let panels = [
		ExternalWindowPanelGeometry(
			panelID: "one",
			appKitScreenFrame: .init(x: 0, y: 0, width: 400, height: 400),
			isOccupied: true
		),
		ExternalWindowPanelGeometry(
			panelID: "two",
			appKitScreenFrame: .init(x: 200, y: 200, width: 400, height: 400),
			isOccupied: false
		),
	]
	try expect(
		externalWindowPanelDropTarget(at: .init(x: 300, y: 300), panels: panels) == nil,
		"overlapping panel geometry must fail closed"
	)
}

private func testWindowDragQualification() throws {
	let initial = dragSample(mouseX: 200, mouseY: 800, windowX: 100, windowY: 400)
	try expect(
		qualifiesExternalWindowDrag(
			initial: initial,
			current: dragSample(
				mouseX: 260,
				mouseY: 760,
				windowX: 160,
				windowY: 360
			)
		),
		"correlated mouse and window displacement must qualify"
	)
	try expect(
		!qualifiesExternalWindowDrag(
			initial: initial,
			current: dragSample(
				mouseX: 260,
				mouseY: 760,
				windowX: 100,
				windowY: 400
			)
		),
		"mouse-only drags such as text, tabs, and files must not qualify"
	)
	try expect(
		!qualifiesExternalWindowDrag(
			initial: initial,
			current: dragSample(
				mouseX: 260,
				mouseY: 760,
				windowX: 300,
				windowY: 650
			)
		),
		"uncorrelated window motion must not qualify"
	)
	try expect(
		!qualifiesExternalWindowDrag(
			initial: initial,
			current: dragSample(
				mouseX: 260,
				mouseY: 760,
				windowX: 160,
				windowY: 360,
				width: 900
			)
		),
		"window resizing must not be classified as a title-bar drag"
	)
}

private func testAccessibilityNotificationMapping() throws {
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXMovedNotification as String
		) == .moved,
		"AX moved notifications must map to moved events"
	)
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXResizedNotification as String
		) == .resized,
		"AX resized notifications must map to resized events"
	)
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXUIElementDestroyedNotification as String
		) == .destroyed,
		"AX destroyed notifications must map to destroyed events"
	)
	try expect(
		managedExternalWindowEvent(forAccessibilityNotification: "AXUnknown") == nil,
		"unknown AX notifications must be ignored"
	)
}

private func testHitSelectionPassesThroughChromeButNotOwnWindows() throws {
	let provider: ExternalWindowIdentity = .init(processIdentifier: 42, windowID: 10)
	let own: ExternalWindowIdentity = .init(processIdentifier: 99, windowID: 11)
	let frame: CGRect = .init(x: 0, y: 0, width: 600, height: 400)
	let providerWindow: ExternalWindowCurrentSpaceWindow = .init(
		identity: provider, layer: 0, isOnscreen: true,
		ownerIsRegularApplication: true, accessibilityFrame: frame
	)
	let chrome: ExternalWindowCurrentSpaceWindow = .init(
		identity: own, layer: 3, isOnscreen: true,
		ownerIsRegularApplication: true, accessibilityFrame: frame
	)
	let control: ExternalWindowCurrentSpaceWindow = .init(
		identity: own, layer: 0, isOnscreen: true,
		ownerIsRegularApplication: true, accessibilityFrame: frame
	)
	// Stage Manager's WindowManager owns layer-zero windows as an accessory app.
	let systemChrome: ExternalWindowCurrentSpaceWindow = .init(
		identity: .init(processIdentifier: 7, windowID: 12), layer: 0, isOnscreen: true,
		ownerIsRegularApplication: false, accessibilityFrame: frame
	)
	try expect(externalWindowAtPoint(.init(x: 50, y: 50), windows: [systemChrome, providerWindow],
		excludingProcessIdentifiers: [99]) == provider,
		"system windows such as Stage Manager's must never be selected or block a provider")
	try expect(externalWindowAtPoint(.init(x: 50, y: 50), windows: [systemChrome],
		excludingProcessIdentifiers: [99]) == nil, "an accessory owner alone yields no selection")
	try expect(externalWindowAtPoint(.init(x: 50, y: 50), windows: [chrome, providerWindow],
		excludingProcessIdentifiers: [99]) == provider, "transparent chrome must not hide provider candidates")
	try expect(externalWindowAtPoint(.init(x: 50, y: 50), windows: [control, providerWindow],
		excludingProcessIdentifiers: [99]) == nil, "clicking Teaser controls must not select a window behind them")
	try expect(externalWindowAtPoint(.init(x: 900, y: 50), windows: [providerWindow],
		excludingProcessIdentifiers: [99]) == nil, "points outside provider frames must not select them")
}

private func testTransactionErrorsRetainInputs() throws {
	let expected = ExternalWindowIdentity(processIdentifier: 42, windowID: 10)
	let actual = ExternalWindowIdentity(processIdentifier: 42, windowID: 11)
	let mismatch = ManagedExternalWindowError.snapshotIdentityMismatch(
		expected: expected,
		actual: actual
	)
	try expect(
		mismatch == .snapshotIdentityMismatch(expected: expected, actual: actual),
		"snapshot mismatch must retain exact identities"
	)
	let requested = CGRect(x: 10, y: 20, width: 280, height: 180)
	let fitted = CGRect(x: 10, y: 20, width: 480, height: 320)
	try expect(
		ManagedExternalWindowError.windowCannotFit(
			requested: requested,
			actual: fitted
		) == .windowCannotFit(requested: requested, actual: fitted),
		"cannot-fit errors must retain requested and actual frames"
	)
}

do {
	try testCoordinateConversion()
	try testWindowIdentitySelectsOneExactWindowID()
	try testPickerRowsOrderAndDescribeCandidates()
	try testPickerFiltersAndDeduplicates()
	try testPlacementLandsWhenTheProviderKeepsTheCorner()
	try testLargeWindowIsAimedByItsBody()
	try testPanelTargetSemantics()
	try testPanelOverlapFailsClosed()
	try testWindowDragQualification()
	try testAccessibilityNotificationMapping()
	try testTransactionErrorsRetainInputs()
	try testHitSelectionPassesThroughChromeButNotOwnWindows()
	print("ManagedExternalWindow tests passed")
} catch {
	fputs("ManagedExternalWindow tests failed: \(error)\n", stderr)
	exit(1)
}
