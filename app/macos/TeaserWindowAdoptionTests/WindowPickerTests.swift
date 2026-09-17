import AppKit
@testable import TeaserKit

/// The picker model drives the same orchestrator the application drives. Nothing
/// here shows a window, walks Accessibility, or touches a window the user owns:
/// the candidate list arrives through a substituted closure.
@MainActor
private func makePicker(
	_ harness: Harness,
	candidates: @escaping @MainActor () -> [ExternalWindowCandidate]
) -> DesktopStageWindowPickerModel {
	let model: DesktopStageWindowPickerModel = .init(
		onList: candidates,
		onAdopt: { identity, panelID in
			harness.orchestrator.adoptWindow(identity: identity, into: panelID)
		}
	)
	model.update(from: harness.orchestrator)
	return model
}

@MainActor
private func testPickerListsOnlyUnoccupiedPanelsAsTargets() throws {
	let harness: Harness = try makeStartedHarness()
	let window: FakeWindow = harness.addWindow()
	let model: DesktopStageWindowPickerModel = makePicker(harness) { [] }

	try expect(
		model.state.targets.contains { $0.id == leftPanelID },
		"an empty Panel must be offered as a target"
	)
	try harness.adopt(window, into: leftPanelID)
	model.update(from: harness.orchestrator)
	try expect(
		!model.state.targets.contains { $0.id == leftPanelID },
		"an occupied Panel must stop being a target"
	)
	try expect(
		model.panelTitle(holding: window.identity) != nil,
		"a window Teaser already holds must name the Panel holding it"
	)
}

@MainActor
private func testPickerRefreshIsSeparateFromProjection() throws {
	let harness: Harness = try makeStartedHarness()
	let hidden: FakeWindow = harness.addWindow()
	hidden.isVisibleOnCurrentSpace = false
	var listCalls: Int = 0
	let model: DesktopStageWindowPickerModel = makePicker(harness) {
		listCalls += 1
		return harness.orchestrator.adoptableWindows()
	}

	try expect(listCalls == 0, "projecting orchestrator state must not walk Accessibility")
	model.update(from: harness.orchestrator)
	harness.orchestrator.setStatus("something changed")
	model.update(from: harness.orchestrator)
	try expect(listCalls == 0, "further projections must still not walk Accessibility")

	model.refresh()
	try expect(listCalls == 1, "only an explicit refresh lists candidates")
	try expect(
		model.rows.contains { $0.candidate.identity == hidden.identity },
		"a hidden window must appear in the picker"
	)
	model.query = "no such application"
	try expect(model.rows.isEmpty, "the query filters the listed rows")
}

@MainActor
private func testPickerAdoptsIntoTheChosenPanelOnly() throws {
	let harness: Harness = try makeStartedHarness()
	let hidden: FakeWindow = harness.addWindow()
	hidden.isVisibleOnCurrentSpace = false
	let model: DesktopStageWindowPickerModel = makePicker(harness) {
		harness.orchestrator.adoptableWindows()
	}
	model.refresh()

	try expect(
		!model.adopt(hidden.identity) && model.message != nil,
		"adopting without a chosen Panel must refuse and say so"
	)
	try expect(
		harness.log.bindCount(for: hidden.identity) == 0,
		"a refused pick must take no lease"
	)

	model.select(panelID: leftPanelID)
	try expect(model.canAdopt, "a started stage with a chosen Panel can adopt")
	try expect(model.adopt(hidden.identity), "the chosen window must be adopted")
	try expect(
		harness.orchestrator.panelAssignments[leftPanelID] == hidden.identity,
		"the window must land in the chosen Panel, not in Virtual Focus's Panel"
	)

	model.update(from: harness.orchestrator)
	try expect(
		model.selectedPanelID == nil,
		"a Panel that stopped being a target must stop being selected"
	)
}

@MainActor
private func testPickerRefusesAdoptionWhileStopped() throws {
	let harness: Harness = .init(presentation: try testPresentation())
	let window: FakeWindow = harness.addWindow()
	let model: DesktopStageWindowPickerModel = makePicker(harness) {
		harness.orchestrator.adoptableWindows()
	}
	model.refresh()

	try expect(
		model.rows.contains { $0.candidate.identity == window.identity },
		"the picker lists candidates before the stage starts"
	)
	try expect(!model.canAdopt, "a stopped stage cannot adopt")
	try expect(
		!model.adopt(window.identity) && model.message != nil,
		"adopting while stopped must refuse with a reason"
	)
	try expect(
		harness.log.operations.isEmpty,
		"a refused pick on a stopped stage must touch no window"
	)
}

@MainActor
private func testPickerWindowConstructsWithoutShowingAnything() throws {
	// A stopped harness: starting the stage applies the layout, so window
	// operations there would say nothing about constructing the picker.
	let harness: Harness = .init(presentation: try testPresentation())
	let model: DesktopStageWindowPickerModel = makePicker(harness) { [] }
	let picker: DesktopStageWindowPickerWindow = .init(model: model)
	defer { picker.close() }

	try expect(
		picker.window.level == .normal && picker.window.styleMask.contains(.closable),
		"the picker is an ordinary closable window, never an overlay"
	)
	try expect(
		!picker.window.isVisible,
		"constructing the picker must never show it"
	)
	try expect(
		!NSApplication.shared.windows.contains(where: \.isVisible),
		"tests must never show windows"
	)
	try expect(
		harness.log.operations.isEmpty,
		"constructing the picker must touch no window"
	)
}

func windowPickerCases() -> [TestCase] {
	[
		.init("picker window constructs without showing anything", testPickerWindowConstructsWithoutShowingAnything),
		.init("picker offers only unoccupied Panels", testPickerListsOnlyUnoccupiedPanelsAsTargets),
		.init("picker refresh is separate from projection", testPickerRefreshIsSeparateFromProjection),
		.init("picker adopts into the chosen Panel only", testPickerAdoptsIntoTheChosenPanelOnly),
		.init("picker refuses adoption while stopped", testPickerRefusesAdoptionWhileStopped),
	]
}
