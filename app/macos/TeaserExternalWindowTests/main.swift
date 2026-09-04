import ApplicationServices
import CoreGraphics
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			return message
		}
	}
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else {
		throw TestFailure.assertion(message)
	}
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

private func candidate(
	_ index: Int,
	title: String,
	document: String? = nil,
	role: String = kAXWindowRole,
	subrole: String? = kAXStandardWindowSubrole,
	accessibilityFrame: CGRect? = .init(x: 100, y: 100, width: 800, height: 600),
	isMinimized: Bool = false,
	isOnCurrentSpace: Bool = true
) -> ManagedExternalWindowCandidate {
	.init(
		index: index,
		role: role,
		subrole: subrole,
		title: title,
		document: document,
		accessibilityFrame: accessibilityFrame,
		isMinimized: isMinimized,
		isOnCurrentSpace: isOnCurrentSpace
	)
}

private func testCoordinateConversion() throws {
	let menuBarScreen: CGRect = .init(x: 0, y: 0, width: 1_920, height: 1_080)
	let appKitFrame: CGRect = .init(x: 100, y: 120, width: 800, height: 600)
	let expectedAccessibilityFrame: CGRect = .init(
		x: 100,
		y: 360,
		width: 800,
		height: 600
	)
	let converted: CGRect = managedExternalWindowAccessibilityFrame(
		fromAppKitScreenFrame: appKitFrame,
		menuBarScreenFrame: menuBarScreen
	)
	try expectFrame(
		converted,
		expectedAccessibilityFrame,
		message: "primary-screen conversion"
	)
	try expectFrame(
		managedExternalWindowAppKitScreenFrame(
			fromAccessibilityFrame: converted,
			menuBarScreenFrame: menuBarScreen
		),
		appKitFrame,
		message: "primary-screen round trip"
	)

	let leftDisplayFrame: CGRect = .init(x: -1_280, y: 160, width: 1_280, height: 720)
	let leftAccessibilityFrame: CGRect = managedExternalWindowAccessibilityFrame(
		fromAppKitScreenFrame: leftDisplayFrame,
		menuBarScreenFrame: menuBarScreen
	)
	try expectFrame(
		leftAccessibilityFrame,
		.init(x: -1_280, y: 200, width: 1_280, height: 720),
		message: "left-display conversion"
	)

	let upperDisplayFrame: CGRect = .init(x: 100, y: 1_080, width: 1_000, height: 700)
	let upperAccessibilityFrame: CGRect = managedExternalWindowAccessibilityFrame(
		fromAppKitScreenFrame: upperDisplayFrame,
		menuBarScreenFrame: menuBarScreen
	)
	try expectFrame(
		upperAccessibilityFrame,
		.init(x: 100, y: -700, width: 1_000, height: 700),
		message: "upper-display conversion"
	)
}

private func testApproximateFrameComparison() throws {
	let baseline: CGRect = .init(x: 10, y: 20, width: 800, height: 600)
	try expect(
		managedExternalWindowFramesAreApproximatelyEqual(
			baseline,
			.init(x: 10.8, y: 19.4, width: 800.5, height: 599.2)
		),
		"sub-point frame differences should be suppressed"
	)
	try expect(
		!managedExternalWindowFramesAreApproximatelyEqual(
			baseline,
			.init(x: 12, y: 20, width: 800, height: 600)
		),
		"material frame differences must not be suppressed"
	)
}

private func testAdjacentLayoutFillsVisibleFrameWithoutOverlap() throws {
	let visibleFrame: CGRect = .init(x: -200, y: 40, width: 1_600, height: 900)
	guard let layout: ManagedExternalWindowAdjacentLayout =
		managedExternalWindowAdjacentLayout(
			in: visibleFrame,
			gap: 8,
			hostFraction: 0.45,
			minimumHostWidth: 620,
			minimumExternalWidth: 480
		)
	else {
		throw TestFailure.assertion("a valid visible frame must produce an adjacent layout")
	}
	try expect(layout.hostFrame.minX == visibleFrame.minX, "host must anchor to the left edge")
	try expect(
		layout.externalFrame.maxX == visibleFrame.maxX,
		"external window must anchor to the right edge"
	)
	try expect(
		layout.externalFrame.minX - layout.hostFrame.maxX == 8,
		"adjacent windows must preserve the requested gap"
	)
	try expect(
		layout.hostFrame.height == visibleFrame.height
			&& layout.externalFrame.height == visibleFrame.height,
		"both adjacent windows must fill the visible height"
	)
	try expect(layout.hostFrame.width >= 620, "host minimum width must be enforced")
	try expect(
		layout.externalFrame.width >= 480,
		"external minimum width must be enforced"
	)
	try expect(
		!layout.hostFrame.intersects(layout.externalFrame),
		"adjacent windows must never overlap"
	)
	try expect(
		managedExternalWindowAdjacentLayout(
			in: .init(x: 0, y: 0, width: 1_000, height: 700),
			minimumHostWidth: 620,
			minimumExternalWidth: 480
		) == nil,
		"an undersized screen must fail instead of overlapping windows"
	)
}

private func testAccessibilityNotificationMapping() throws {
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXMovedNotification as String
		) == .moved,
		"AX moved notifications should map to moved events"
	)
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXResizedNotification as String
		) == .resized,
		"AX resized notifications should map to resized events"
	)
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: kAXUIElementDestroyedNotification as String
		) == .destroyed,
		"AX destroyed notifications should map to destroyed events"
	)
	try expect(
		managedExternalWindowEvent(
			forAccessibilityNotification: "AXUnknownManagedWindowNotification"
		) == nil,
		"unknown AX notifications should be ignored"
	)
}

private func testExactRepositoryDocumentMatchWins() throws {
	let candidates: [ManagedExternalWindowCandidate] = [
		candidate(
			0,
			title: "foch — old checkout",
			document: "file:///old/foch/src/main.rs"
		),
		candidate(
			1,
			title: "main.rs — Zed",
			document: "file:///new/foch/src/main.rs"
		),
	]
	let selectedIndex: Int = try selectUniqueManagedExternalWindowCandidate(
		from: candidates,
		repositoryURL: URL(fileURLWithPath: "/new/foch")
	)
	try expect(selectedIndex == 1, "absolute repository paths must distinguish equal basenames")
}

private func testTitleOnlyCandidateFailsClosed() throws {
	do {
		_ = try selectUniqueManagedExternalWindowCandidate(
			from: [candidate(0, title: "foch — Zed")],
			repositoryURL: URL(fileURLWithPath: "/new/foch")
		)
		throw TestFailure.assertion("a basename-only title must not identify a repository")
	} catch let error as ManagedExternalWindowCandidateSelectionError {
		try expect(
			error == .noMatch(repositoryName: "foch"),
			"title-only matching must fail closed while an exact-path window may appear"
		)
	}
}

private func testOffSpaceCandidateFailsClosed() throws {
	do {
		_ = try selectUniqueManagedExternalWindowCandidate(
			from: [
				candidate(
					3,
					title: "foch — Zed",
					document: "file:///new/foch/src/main.rs",
					isOnCurrentSpace: false
				),
			],
			repositoryURL: URL(fileURLWithPath: "/new/foch")
		)
		throw TestFailure.assertion("an off-Space window must not be selected")
	} catch let error as ManagedExternalWindowCandidateSelectionError {
		try expect(
			error == .noMatch(repositoryName: "foch"),
			"off-Space matching must fail closed"
		)
	}
}

private func testMinimizedCandidateFailsClosed() throws {
	do {
		_ = try selectUniqueManagedExternalWindowCandidate(
			from: [
				candidate(
					3,
					title: "foch — Zed",
					document: "file:///new/foch/src/main.rs",
					isMinimized: true
				),
			],
			repositoryURL: URL(fileURLWithPath: "/new/foch")
		)
		throw TestFailure.assertion("a minimized window must not be selected")
	} catch let error as ManagedExternalWindowCandidateSelectionError {
		try expect(
			error == .noMatch(repositoryName: "foch"),
			"minimized matching must fail closed"
		)
	}
}

private func testCurrentSpaceCorrelationIsOneToOne() throws {
	let firstFrame: CGRect = .init(x: 100, y: 100, width: 800, height: 600)
	let secondFrame: CGRect = .init(x: 920, y: 100, width: 800, height: 600)
	let candidates: [ManagedExternalWindowCandidate] = [
		candidate(7, title: "foch — Zed", accessibilityFrame: firstFrame),
		candidate(9, title: "teaser — Zed", accessibilityFrame: secondFrame),
	]
	let correlations: [Int: CGWindowID] = managedExternalWindowCurrentSpaceCorrelations(
		candidates: candidates,
		currentSpaceWindows: [
			.init(windowID: 101, title: nil, accessibilityFrame: firstFrame),
		]
	)
	try expect(
		correlations == [7: 101],
		"only the uniquely correlated frame and CGWindowID are current-Space"
	)
}

private func testAmbiguousCurrentSpaceGeometryFailsClosed() throws {
	let sharedFrame: CGRect = .init(x: 100, y: 100, width: 800, height: 600)
	let candidates: [ManagedExternalWindowCandidate] = [
		candidate(0, title: "foch — one", accessibilityFrame: sharedFrame),
		candidate(1, title: "foch — two", accessibilityFrame: sharedFrame),
	]
	let unresolved: [Int: CGWindowID] = managedExternalWindowCurrentSpaceCorrelations(
		candidates: candidates,
		currentSpaceWindows: [
			.init(windowID: 202, title: nil, accessibilityFrame: sharedFrame),
		]
	)
	try expect(unresolved.isEmpty, "duplicate geometry without a title must be rejected")

	let resolved: [Int: CGWindowID] = managedExternalWindowCurrentSpaceCorrelations(
		candidates: candidates,
		currentSpaceWindows: [
			.init(
				windowID: 303,
				title: "foch — two",
				accessibilityFrame: sharedFrame
			),
		]
	)
	try expect(resolved == [1: 303], "an exact visible-window title may disambiguate geometry")
}

private func testNonlocalAndRelativeDocumentURLsFailClosed() throws {
	for document: String in [
		"file:relative/new/foch/main.swift",
		"file://server/new/foch/main.swift",
		"//server/new/foch/main.swift",
	] {
		do {
			_ = try selectUniqueManagedExternalWindowCandidate(
				from: [candidate(0, title: "foch — Zed", document: document)],
				repositoryURL: URL(fileURLWithPath: "/new/foch")
			)
			throw TestFailure.assertion("nonlocal or relative document URL was accepted: \(document)")
		} catch let error as ManagedExternalWindowCandidateSelectionError {
			try expect(
				error == .noMatch(repositoryName: "foch"),
				"nonlocal and relative document URLs must fail closed"
			)
		}
	}
}

private func testCannotFitErrorReportsRequestedAndActualFrames() throws {
	let requested: CGRect = .init(x: 10, y: 20, width: 280, height: 180)
	let actual: CGRect = .init(x: 10, y: 20, width: 480, height: 320)
	let error: ManagedExternalWindowError = .windowCannotFit(
		requested: requested,
		actual: actual
	)
	guard case .windowCannotFit(
		let reportedRequested,
		let reportedActual
	) = error else {
		throw TestFailure.assertion("cannot-fit errors must preserve both frames")
	}
	try expectFrame(
		reportedRequested,
		requested,
		message: "cannot-fit requested frame"
	)
	try expectFrame(
		reportedActual,
		actual,
		message: "cannot-fit actual frame"
	)
}

private func testAmbiguousCandidatesFailClosed() throws {
	let candidates: [ManagedExternalWindowCandidate] = [
		candidate(0, title: "foch — one", document: "file:///new/foch/a.swift"),
		candidate(1, title: "foch — two", document: "file:///new/foch/b.swift"),
	]
	do {
		_ = try selectUniqueManagedExternalWindowCandidate(
			from: candidates,
			repositoryURL: URL(fileURLWithPath: "/new/foch")
		)
		throw TestFailure.assertion("ambiguous candidates must not be guessed")
	} catch let error as ManagedExternalWindowCandidateSelectionError {
		try expect(
			error == .ambiguous(repositoryName: "foch", count: 2),
			"ambiguous selection should report the exact candidate count"
		)
	}
}

private func testNoCandidateFailsClosed() throws {
	do {
		_ = try selectUniqueManagedExternalWindowCandidate(
			from: [
				candidate(0, title: "teaser — Zed", document: "file:///other/teaser"),
				candidate(1, title: "notfoch — Zed", document: "file:///other/notfoch"),
			],
			repositoryURL: URL(fileURLWithPath: "/new/foch")
		)
		throw TestFailure.assertion("missing candidates must fail closed")
	} catch let error as ManagedExternalWindowCandidateSelectionError {
		try expect(
			error == .noMatch(repositoryName: "foch"),
			"missing candidate selection should retain the requested repository"
		)
	}
}

do {
	try testCoordinateConversion()
	try testApproximateFrameComparison()
	try testAdjacentLayoutFillsVisibleFrameWithoutOverlap()
	try testAccessibilityNotificationMapping()
	try testExactRepositoryDocumentMatchWins()
	try testTitleOnlyCandidateFailsClosed()
	try testOffSpaceCandidateFailsClosed()
	try testMinimizedCandidateFailsClosed()
	try testCurrentSpaceCorrelationIsOneToOne()
	try testAmbiguousCurrentSpaceGeometryFailsClosed()
	try testNonlocalAndRelativeDocumentURLsFailClosed()
	try testCannotFitErrorReportsRequestedAndActualFrames()
	try testAmbiguousCandidatesFailClosed()
	try testNoCandidateFailsClosed()
	print("ManagedExternalWindow tests passed")
} catch {
	fputs("ManagedExternalWindow tests failed: \(error)\n", stderr)
	exit(1)
}
