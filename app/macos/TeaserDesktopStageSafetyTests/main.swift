import AppKit
import Darwin
@testable import TeaserKit

private enum TestFailure: Error { case assertion(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

@MainActor
private func testCanvasStartsHiddenAndQuitsOnClose() throws {
	var quitRequests: Int = 0
	let snapshot: DesktopOverlaySnapshot = .init(
		displayID: .init("test"),
		screenFrame: .init(x: 0, y: 0, width: 1_200, height: 800),
		workspaces: [], panels: [], dividers: [],
		virtualFocus: .init(workspaceID: nil, panelID: nil), arrangeMode: false
	)
	let canvas: DesktopCanvasWindow = .init(
		snapshot: snapshot,
		callbacks: .init(onVirtualFocusChange: { _ in }, onWorkspaceFocusRequest: { _ in },
			onDividerRatioChange: { _, _, _ in }),
		onGeometryChange: { _ in },
		onClose: { quitRequests += 1 }
	)
	try expect(!canvas.isVisible, "constructing the canvas must not show it")
	try expect(canvas.window.styleMask.contains(.closable) && canvas.window.level < .normal,
		"the canvas is a closable backdrop below ordinary windows, never an overlay above them")
	try expect(canvas.window.collectionBehavior.contains(.fullScreenNone),
		"the canvas must never enter macOS full screen, where no adopted window can appear")
	try expect(!canvas.window.isOpaque && canvas.window.backgroundColor == .clear,
		"the canvas only outlines Panels; it must not hide what is behind it")
	canvas.update(snapshot)
	canvas.setStatus("display does not fit: it needs at least 1968×812 pt")
	try expect(!canvas.isVisible, "updating the canvas must not show it")
	try expect(canvas.statusIsSelectable, "canvas status must be selectable so errors can be copied")
	_ = canvas.windowShouldClose(canvas.window)
	try expect(quitRequests == 1, "closing the canvas must quit Teaser")
	canvas.close()
}

@MainActor
private func testVisualOverlayNeverCapturesDesktopInput() throws {
	for arranging: Bool in [false, true] {
		let overlay: DesktopOverlayWindow = .init(
			snapshot: .init(
				displayID: .init("test"),
				screenFrame: .init(x: 0, y: 0, width: 1_440, height: 800),
				workspaces: [], panels: [], dividers: [],
				virtualFocus: .init(workspaceID: nil, panelID: nil), arrangeMode: arranging
			),
			callbacks: .init(onVirtualFocusChange: { _ in }, onWorkspaceFocusRequest: { _ in },
				onDividerRatioChange: { _, _, _ in })
		)
		try expect(!overlay.isVisible, "constructing an overlay must not show it")
		try expect(overlay.ignoresMouseEvents, "even Arrange must never create a display-sized input shield")
		try expect(!overlay.canBecomeKey && !overlay.canBecomeMain, "chrome must not steal input focus")
		try expect(!overlay.collectionBehavior.contains(.canJoinAllSpaces), "chrome must stay off unrelated Spaces")
		try expect(!overlay.collectionBehavior.contains(.fullScreenAuxiliary), "chrome must stay off full-screen apps")
		overlay.close()
	}
}

@MainActor
private func testClosedNotesStayClosedAcrossRelayout() throws {
	let notes: NotesWindowController = .init(
		panelID: .init("test-notes"), title: "Test notes", text: "", onChange: { _ in }, onFocus: { _ in }
	)
	let sender: NSWindow = .init()
	_ = notes.windowShouldClose(sender)
	for width: CGFloat in [480, 640, 800] {
		notes.update(frame: .init(x: 0, y: 0, width: width, height: 360), visible: true)
		try expect(!notes.isVisible, "a layout refresh must not reopen user-closed Notes")
	}
	try expect(!NSApplication.shared.windows.contains(where: \.isVisible), "safety tests must not display windows")
}

do {
	NSApplication.shared.setActivationPolicy(.prohibited)
	try testCanvasStartsHiddenAndQuitsOnClose()
	try testVisualOverlayNeverCapturesDesktopInput()
	try testClosedNotesStayClosedAcrossRelayout()
	print("Teaser desktop-stage safety tests passed (no visible windows)")
} catch {
	fputs("Teaser desktop-stage safety tests failed: \(error)\n", stderr)
	exit(1)
}
