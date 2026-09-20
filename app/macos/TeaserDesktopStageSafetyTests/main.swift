import AppKit
import Darwin
@testable import TeaserKit

private enum TestFailure: Error { case assertion(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

@MainActor
private func makeCanvas(
	id: CanvasID,
	onEvent: @escaping @MainActor (CanvasEvent) -> Void = { _ in }
) -> DesktopCanvasWindow {
	.init(
		id: id,
		snapshot: .init(
			displayID: .init(canvas: id),
			screenFrame: .init(x: 0, y: 0, width: 1_200, height: 800),
			workspaces: [], panels: [], dividers: [],
			virtualFocus: .init(workspaceID: nil, panelID: nil), arrangeMode: false
		),
		callbacks: .init(onVirtualFocusChange: { _ in }, onWorkspaceFocusRequest: { _ in },
			onDividerRatioChange: { _, _, _ in }),
		onEvent: onEvent,
		onBecameKey: { _ in },
		onContentClick: { _ in }
	)
}

@MainActor
private func testCanvasStartsHiddenAndReportsItsOwnClose() throws {
	var events: [CanvasEvent] = []
	let id: CanvasID = .init("safety")
	let canvas: DesktopCanvasWindow = makeCanvas(id: id) { events.append($0) }
	try expect(!canvas.isVisible, "constructing a canvas must not show it")
	try expect(canvas.window.styleMask.contains(.closable) && canvas.window.level < .normal,
		"a windowed canvas is a closable backdrop below ordinary windows, never an overlay above them")
	try expect(canvas.window.collectionBehavior.contains(.fullScreenPrimary)
		&& !canvas.window.collectionBehavior.contains(.fullScreenNone),
		"a canvas must be able to enter macOS full screen, where it carries Teaser's own content")
	try expect(canvas.window.collectionBehavior.contains(.managed),
		"a canvas belongs to one Space; a below-normal level must not make it float across Spaces")
	try expect(!canvas.window.isOpaque && canvas.window.backgroundColor == .clear,
		"a windowed canvas only outlines Panels; it must not hide what is behind it")
	canvas.setOpaque(true)
	try expect(canvas.window.isOpaque && canvas.window.backgroundColor != .clear,
		"filling the screen or going full screen makes the canvas an opaque backdrop")
	canvas.setOpaque(false)
	canvas.setStatus("display does not fit: it needs at least 1968×812 pt")
	try expect(!canvas.isVisible, "updating a canvas must not show it")
	try expect(canvas.statusIsSelectable, "canvas status must be selectable so errors can be copied")
	// Closing is the lifecycle's decision, not the window's: a fullscreen canvas
	// has to leave its Space first, and other canvases keep running either way.
	try expect(canvas.windowShouldClose(canvas.window) == false,
		"the window must not close itself before its canvas has been released")
	try expect(events == [.closeRequested(id)], "closing a canvas must report exactly one close request")
	canvas.closeWindow()
}

@MainActor
private func testSeveralCanvasesStayIndependent() throws {
	let lifecycle: CanvasLifecycle = .init()
	let first: CanvasID = .init("first")
	let second: CanvasID = .init("second")
	let frame: LayoutRect = .init(x: 0, y: 0, width: 1_200, height: 800)
	_ = lifecycle.handle(.opened(first, frame: frame, space: nil))
	_ = lifecycle.handle(.opened(second, frame: frame, space: nil))
	try expect(lifecycle.openCanvases == [first, second], "canvases keep the order they were opened in")
	_ = lifecycle.handle(.closeRequested(first))
	_ = lifecycle.handle(.windowClosed(first))
	try expect(lifecycle.openCanvases == [second], "closing one canvas must leave the others open")
	try expect(lifecycle.displayFrames[.init(canvas: second)] == frame,
		"a surviving canvas keeps its own display rectangle")
	try expect(lifecycle.displayFrames[.init(canvas: first)] == nil,
		"a closed canvas must stop being a display the solver lays out")
}

@MainActor
private func testNotesContentNeedsNoWindow() throws {
	let notes: NotesPanelController = .init(
		panelID: .init("test-notes"), title: "Test notes", text: "", onChange: { _ in }
	)
	try expect(notes.view.window == nil, "Teaser-owned Panel content must not create a window of its own")
	let canvas: DesktopCanvasWindow = makeCanvas(id: .init("notes-host"))
	canvas.setContent(notes.view, for: notes.panelID, frame: .init(x: 0, y: 0, width: 480, height: 360))
	try expect(canvas.contentPanelIDs == [notes.panelID], "the canvas hosts the Panel's content")
	try expect(!canvas.isVisible, "hosting content must not show the canvas")
	canvas.removeContent(for: notes.panelID)
	try expect(canvas.contentPanelIDs.isEmpty, "removing content leaves nothing behind")
	canvas.closeWindow()
	try expect(!NSApplication.shared.windows.contains(where: \.isVisible), "safety tests must not display windows")
}

do {
	NSApplication.shared.setActivationPolicy(.prohibited)
	try testCanvasStartsHiddenAndReportsItsOwnClose()
	try testSeveralCanvasesStayIndependent()
	try testNotesContentNeedsNoWindow()
	print("Teaser desktop-stage safety tests passed (no visible windows)")
} catch {
	fputs("Teaser desktop-stage safety tests failed: \(error)\n", stderr)
	exit(1)
}
