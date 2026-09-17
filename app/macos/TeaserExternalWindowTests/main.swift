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
