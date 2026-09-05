import AppKit
import Darwin

private enum TestFailure: Error { case assertion(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

@MainActor
private func testControlWindowStartsHiddenAndCanQuit() throws {
	var quitRequests: Int = 0
	let controls: DesktopStageControlWindow = .init(
		onToggleStage: {}, onArrange: {}, onRequestPermission: {},
		onQuit: { quitRequests += 1 }
	)
	try expect(!controls.window.isVisible, "constructing controls must not show any desktop window")
	try expect(controls.window.styleMask.contains(.closable), "controls need a normal close affordance")
	controls.update(active: true, arranging: true, authorized: true, message: nil)
	try expect(controls.window.level == .normal, "controls must not float over provider panels")
	try expect(!controls.window.isVisible, "refreshing controls must not reopen them")
	_ = controls.windowShouldClose(controls.window)
	try expect(quitRequests == 1, "the red close button must request complete app shutdown")
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
	try testControlWindowStartsHiddenAndCanQuit()
	try testVisualOverlayNeverCapturesDesktopInput()
	try testClosedNotesStayClosedAcrossRelayout()
	print("Teaser desktop-stage safety tests passed (no visible windows)")
} catch {
	fputs("Teaser desktop-stage safety tests failed: \(error)\n", stderr)
	exit(1)
}
