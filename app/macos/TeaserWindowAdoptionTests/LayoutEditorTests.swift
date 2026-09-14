import AppKit
import SplitView
@testable import TeaserKit

@MainActor
private func makeEditor(_ harness: Harness) -> DesktopStageLayoutEditorModel {
	// The same command callbacks as DesktopStageController, with a fake host.
	let model: DesktopStageLayoutEditorModel = .init(presentation: harness.orchestrator.presentation, onResize: { [weak harness] reference, ratio in
		guard let harness else { return }
		harness.orchestrator.setDividerRatio(ratio, scope: reference.scope, splitID: reference.splitID)
	}, onUndo: { [weak harness] in harness?.orchestrator.undoLastLayoutChange() })
	model.update(presentation: harness.orchestrator.presentation, active: harness.orchestrator.isStageActive,
		assignedPanels: Set(harness.orchestrator.panelAssignments.keys))
	return model
}

@MainActor
private func rootPreference(_ harness: Harness) throws -> SplitPreference {
	guard case .split(_, _, let preference, _, _) = harness.orchestrator.presentation
		.workspaces[testWorkspaceID]?.panelTree else { throw TestFailure.assertion("missing split") }
	return preference
}

@MainActor
private func testEditorResizesThroughRealOrchestrator() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	let before: CGRect = window.appKitScreenFrame
	let model: DesktopStageLayoutEditorModel = makeEditor(harness)
	let holder: FractionHolder = model.fractionHolder(for: .init(scope: .workspace(testWorkspaceID),
		splitID: .init("alpha-root")), axis: .horizontal, preference: try rootPreference(harness))
	let applyCount: Int = harness.log.applies(for: window.identity).count
	holder.value = 0.65 // SplitView's actual end-of-drag contract.
	try expect(harness.log.applies(for: window.identity).count == applyCount + 1,
		"one editor commit must apply the actual provider exactly once")
	try expect(window.appKitScreenFrame.width > before.width, "the provider must actually resize")
	try expect(try rootPreference(harness).desiredRatio == 0.65, "editor writes the shared layout tree")
	model.onUndo()
	try expect(window.appKitScreenFrame == before, "editor Undo must restore provider geometry")
}

@MainActor
private func testEditorRejectsInvalidAndReflectsRollback() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	let before: WorkspacePresentation = harness.orchestrator.presentation
	let originalFrame: CGRect = window.appKitScreenFrame
	let model: DesktopStageLayoutEditorModel = makeEditor(harness)
	let reference: LayoutSplitReference = .init(scope: .workspace(testWorkspaceID), splitID: .init("alpha-root"))
	for invalid: CGFloat in [.nan, .infinity, 0, 1, -0.2] {
		model.fractionHolder(for: reference, axis: .horizontal, preference: try rootPreference(harness)).value = invalid
	}
	try expect(harness.orchestrator.presentation == before, "invalid fractions must not mutate state")
	window.minimumSize = .init(width: 1_900, height: 900)
	model.fractionHolder(for: reference, axis: .horizontal, preference: try rootPreference(harness)).value = 0.3
	try expect(harness.orchestrator.presentation == before, "provider rejection restores the canonical tree")
	try expect(window.appKitScreenFrame == originalFrame, "provider rejection rolls back actual geometry")
	model.update(presentation: harness.orchestrator.presentation, active: true, assignedPanels: [leftPanelID])
	let refreshed: FractionHolder = model.fractionHolder(for: reference, axis: .horizontal,
		preference: try rootPreference(harness))
	try expect(refreshed.value == 0.5, "a rejected editor drag must display the committed ratio")
	try expect(model.revision > 0, "even a rejection resets upstream gesture state")
}

@MainActor
private func testEditorCoordinatesAndEffectiveRatio() throws {
	for axis: LayoutAxis in [.horizontal, .vertical] {
		for ratio: Double in [0.15, 0.4, 0.83] {
			let primary: CGFloat = LayoutEditorCoordinates.primaryFraction(firstRatio: ratio, axis: axis)
			let restored: Double = try unwrap(LayoutEditorCoordinates.firstRatio(primaryFraction: primary, axis: axis),
				"valid fractions must map")
			try expect(abs(restored - ratio) < 0.000_001, "coordinate mapping must round-trip")
		}
	}
	let harness: Harness = .init(presentation: try testPresentation())
	let model: DesktopStageLayoutEditorModel = makeEditor(harness)
	let holder: FractionHolder = model.fractionHolder(for: .init(scope: .workspace(testWorkspaceID),
		splitID: .init("alpha-root")), axis: .vertical,
		preference: .init(desiredRatio: 0.4, effectiveRatio: 0.7))
	try expect(abs(holder.value - 0.3) < 0.000_001, "vertical primary is top and displays the effective ratio")
}

@MainActor
private func testStoppedEditorDoesNotTouchDesktop() throws {
	let harness: Harness = .init(presentation: try testPresentation())
	let model: DesktopStageLayoutEditorModel = makeEditor(harness)
	let editor: DesktopStageLayoutEditorWindow = .init(model: model)
	defer { editor.close() }
	let holder: FractionHolder = model.fractionHolder(for: .init(scope: .workspace(testWorkspaceID),
		splitID: .init("alpha-root")), axis: .horizontal, preference: try rootPreference(harness))
	holder.value = 0.6
	model.update(presentation: harness.orchestrator.presentation, active: false, assignedPanels: [])
	try expect(try rootPreference(harness).desiredRatio == 0.6, "stopped layout remains editable")
	try expect(harness.log.operations.isEmpty, "offline editing must not observe or move windows")
	try expect(harness.service.promptCount == 0, "offline editing must not prompt for Accessibility")
	try expect(editor.window.level == .normal && editor.window.styleMask.contains(.closable),
		"editor is an ordinary closable window")
	try expect(!editor.window.isVisible, "construction and updates must never show the editor")
	try expect(!NSApplication.shared.windows.contains(where: \.isVisible), "tests must never show windows")
}

@MainActor
private func testEditorIgnoresStaleDragAfterStop() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	try harness.adopt(window, into: leftPanelID)
	let model: DesktopStageLayoutEditorModel = makeEditor(harness)
	let holder: FractionHolder = model.fractionHolder(for: .init(scope: .workspace(testWorkspaceID),
		splitID: .init("alpha-root")), axis: .horizontal, preference: try rootPreference(harness))
	window.refusesRelease = true
	harness.orchestrator.stopStage()
	model.update(presentation: harness.orchestrator.presentation, active: false, assignedPanels: [leftPanelID])
	let operations: [FakeWindowOperation] = harness.log.operations
	holder.value = 0.7
	let fresh: FractionHolder = model.fractionHolder(for: .init(scope: .workspace(testWorkspaceID),
		splitID: .init("alpha-root")), axis: .horizontal, preference: try rootPreference(harness))
	fresh.value = 0.7
	try expect(!model.canEdit, "failed release must disable offline editing")
	try expect(harness.log.operations == operations, "stale or fresh editor gestures must not move unreleased windows")
	window.refusesRelease = false
	harness.orchestrator.stopStage()
}

@MainActor
private func testEditorDisplayAndVerticalResize() throws {
	let displayHarness: Harness = .init(presentation: try testPresentationWithTwoWorkspaces())
	try displayHarness.orchestrator.startStage()
	defer { displayHarness.orchestrator.stopStage() }
	let displayWindow: FakeWindow = displayHarness.addWindow()
	try displayHarness.adopt(displayWindow, into: leftPanelID)
	let oldWidth: CGFloat = displayWindow.appKitScreenFrame.width
	let displayEditor: DesktopStageLayoutEditorModel = makeEditor(displayHarness)
	displayEditor.fractionHolder(for: .init(scope: .display(testDisplayID), splitID: .init("display-root")),
		axis: .horizontal, preference: .init(desiredRatio: 0.5)).value = 0.65
	try expect(displayWindow.appKitScreenFrame.width > oldWidth,
		"display-scoped edits must resize Workspaces and their actual provider panels")

	var presentation: WorkspacePresentation = try testPresentation()
	presentation.workspaces[testWorkspaceID]?.panelTree = .split(id: .init("alpha-root"), axis: .vertical,
		preference: .init(desiredRatio: 0.5), first: .leaf(leftPanelID), second: .leaf(rightPanelID))
	let verticalHarness: Harness = .init(presentation: presentation)
	try verticalHarness.orchestrator.startStage()
	defer { verticalHarness.orchestrator.stopStage() }
	let bottomWindow: FakeWindow = verticalHarness.addWindow()
	try verticalHarness.adopt(bottomWindow, into: leftPanelID)
	let oldHeight: CGFloat = bottomWindow.appKitScreenFrame.height
	let verticalEditor: DesktopStageLayoutEditorModel = makeEditor(verticalHarness)
	verticalEditor.fractionHolder(for: .init(scope: .workspace(testWorkspaceID), splitID: .init("alpha-root")),
		axis: .vertical, preference: try rootPreference(verticalHarness)).value = 0.65
	try expect(bottomWindow.appKitScreenFrame.height < oldHeight,
		"growing SplitView's top child must shrink Teaser's first/bottom provider")
	try expect(abs(try rootPreference(verticalHarness).desiredRatio - 0.35) < 0.000_001,
		"vertical commits must invert the upstream primary fraction")
}

func layoutEditorCases() -> [TestCase] {
	[
		.init("SplitView commit applies and undoes provider geometry", testEditorResizesThroughRealOrchestrator),
		.init("SplitView rejection rolls back state and geometry", testEditorRejectsInvalidAndReflectsRollback),
		.init("SplitView coordinates preserve vertical orientation and effective ratios", testEditorCoordinatesAndEffectiveRatio),
		.init("stopped layout editor remains hidden and touches no desktop state", testStoppedEditorDoesNotTouchDesktop),
		.init("editor ignores stale drag and failed-release edits", testEditorIgnoresStaleDragAfterStop),
		.init("display and vertical editor commits reach the correct providers", testEditorDisplayAndVerticalResize),
	]
}
