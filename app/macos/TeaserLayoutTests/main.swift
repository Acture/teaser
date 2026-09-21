import Darwin
import Foundation
@testable import TeaserKit

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			return message
		}
	}
}

private func expect(
	_ condition: @autoclosure () -> Bool,
	_ message: String
) throws {
	guard condition() else {
		throw TestFailure.assertion(message)
	}
}

private func expectApproximatelyEqual(
	_ actual: Double,
	_ expected: Double,
	tolerance: Double = 0.000_001,
	_ message: String
) throws {
	try expect(
		abs(actual - expected) <= tolerance,
		"\(message): expected \(expected), got \(actual)"
	)
}

private func assertNoOverlap<ID: Hashable>(
	_ frames: [ID: LayoutRect],
	_ message: String
) throws {
	let values: [(ID, LayoutRect)] = frames.map { ($0.key, $0.value) }
	for firstIndex: Int in values.indices {
		for secondIndex: Int in values.indices where secondIndex > firstIndex {
			try expect(
				!values[firstIndex].1.intersects(values[secondIndex].1),
				message
			)
		}
	}
}

private func panelDescriptor(
	_ panelID: PanelID,
	in presentation: WorkspacePresentation
) throws -> PanelDescriptor {
	guard let panel: PanelDescriptor = presentation.workspaces.values
		.lazy
		.compactMap({ $0.panels[panelID] })
		.first
	else {
		throw TestFailure.assertion("missing Panel descriptor \(panelID.rawValue)")
	}
	return panel
}

private func testShowcaseFillsWithoutOverlap() throws {
	let displayID: DisplayID = .init("display-1")
	let displayFrame: LayoutRect = .init(
		x: -160,
		y: 24,
		width: 2_560,
		height: 1_400
	)
	let presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: displayID
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [displayID: displayFrame]
	)

	try expect(layout.workspaceFrames.count == 6, "showcase must contain six Workspaces")
	try expect(layout.panelFrames.count == 9, "showcase must contain nine Panels")
	try expect(layout.dividers.count == 8, "all slicing-tree dividers must be exposed")
	try assertNoOverlap(layout.workspaceFrames, "Workspace frames must not overlap")

	let workspaceArea: Double = layout.workspaceFrames.values.reduce(0) {
		$0 + $1.size.area
	}
	let workspaceDividerArea: Double = layout.dividers
		.filter { $0.scope == .display(displayID) }
		.reduce(0) { $0 + $1.frame.size.area }
	try expectApproximatelyEqual(
		workspaceArea + workspaceDividerArea,
		displayFrame.size.area,
		"Workspaces and gutters must exactly fill the display"
	)

	for workspaceID: WorkspaceID in presentation.workspaces.keys {
		guard let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID],
			let workspaceFrame: LayoutRect = layout.workspaceFrames[workspaceID]
		else {
			throw TestFailure.assertion("missing solved Workspace")
		}
		let frames: [PanelID: LayoutRect] = layout.panelFrames.filter {
			workspace.panels[$0.key] != nil
		}
		try assertNoOverlap(frames, "Panels in one Workspace must not overlap")
		let panelArea: Double = frames.values.reduce(0) { $0 + $1.size.area }
		let dividerArea: Double = layout.dividers
			.filter { $0.scope == .workspace(workspaceID) }
			.reduce(0) { $0 + $1.frame.size.area }
		try expectApproximatelyEqual(
			panelArea + dividerArea,
			workspaceFrame.size.area,
			"Panels and gutters must exactly fill Workspace \(workspaceID.rawValue)"
		)
		for (panelID, frame): (PanelID, LayoutRect) in frames {
			let panel: PanelDescriptor = try panelDescriptor(panelID, in: presentation)
			let profile: LayoutProfile = panel.profileOverride
				?? presentation.panelKinds.definition(for: panel.kindID)!.defaultProfile
			try expect(
				frame.size.width + 0.000_001 >= profile.minimumSize.width,
				"Panel minimum width must be enforced"
			)
			try expect(
				frame.size.height + 0.000_001 >= profile.minimumSize.height,
				"Panel minimum height must be enforced"
			)
		}
	}

	let zedFrame: LayoutRect = layout.panelFrames[ShowcasePreset.zedPanelID]!
	let linearFrame: LayoutRect = layout.panelFrames[ShowcasePreset.linearPanelID]!
	try expect(
		zedFrame.size.width != linearFrame.size.width,
		"heterogeneous Panel profiles must not collapse to equal columns"
	)
	try expect(layout.quality.totalAspectRatioDeviation.isFinite, "quality must be finite")
}

private func testLayoutIsDeterministic() throws {
	let displayID: DisplayID = .init("display")
	let presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: displayID
	)
	let frames: [DisplayID: LayoutRect] = [
		displayID: .init(x: 0, y: 0, width: 2_560, height: 1_400),
	]
	let first: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: frames
	)
	let second: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: frames
	)
	try expect(first == second, "identical inputs must produce identical layouts")
}

private func testEdgeInsertionAndLongAxisSplit() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	let panel: PanelDescriptor = .init(
		id: .init("foch-shell"),
		title: "Shell",
		kindID: .generic,
		providerHint: .init(
			displayName: "Terminal",
			bundleIdentifier: "com.apple.Terminal",
			context: nil
		),
		profileOverride: nil,
		nativeContent: .none
	)
	try presentation.splitPanel(
		ShowcasePreset.claudePanelID,
		with: panel,
		in: ShowcasePreset.fochWorkspaceID,
		targetFrame: .init(x: 0, y: 0, width: 900, height: 400),
		splitID: .init("foch-shell-split")
	)
	let tree: LayoutTree<PanelID> = presentation.workspaces[
		ShowcasePreset.fochWorkspaceID
	]!.panelTree
	guard case .split(_, let axis, _, let first, let second) = tree else {
		throw TestFailure.assertion("splitPanel must replace the target leaf")
	}
	try expect(axis == .horizontal, "Ctrl+D defaults to the target's long axis")
	try expect(first.leaves == [ShowcasePreset.claudePanelID], "old Panel stays first")
	try expect(second.leaves == [panel.id], "new empty Panel is inserted second")

	// A tall Panel splits on the other axis, which routes through the same
	// first-is-lower convention: the new Panel takes the lower half.
	var tall: WorkspacePresentation = ShowcasePreset.presentation()
	let tallPanel: PanelDescriptor = .init(
		id: .init("foch-tall"),
		title: "Tall",
		kindID: .generic,
		providerHint: nil,
		profileOverride: nil,
		nativeContent: .none
	)
	try tall.splitPanel(
		ShowcasePreset.claudePanelID,
		with: tallPanel,
		in: ShowcasePreset.fochWorkspaceID,
		targetFrame: .init(x: 0, y: 0, width: 400, height: 900),
		splitID: .init("foch-tall-split")
	)
	guard case .split(_, let tallAxis, _, let tallFirst, let tallSecond) = tall
		.workspaces[ShowcasePreset.fochWorkspaceID]!.panelTree
	else {
		throw TestFailure.assertion("splitPanel must replace the target leaf")
	}
	try expect(tallAxis == .vertical, "a tall Panel splits on its long axis")
	try expect(
		tallFirst.leaves == [tallPanel.id],
		"the new Panel takes the lower half of a tall split"
	)
	try expect(
		tallSecond.leaves == [ShowcasePreset.claudePanelID],
		"the target keeps the upper half of a tall split"
	)

	var edgeTree: LayoutTree<String> = .leaf("target")
	try edgeTree.insert(
		"new",
		at: .top,
		of: "target",
		splitID: .init("top")
	)
	guard case .split(_, let edgeAxis, _, let edgeFirst, let edgeSecond) = edgeTree
	else {
		throw TestFailure.assertion("edge insertion must create a split")
	}
	// The solver lays a split's first child at the lower coordinate on its axis,
	// so a top insertion follows the target rather than preceding it.
	try expect(edgeAxis == .vertical, "top insertion must use a vertical split")
	try expect(edgeFirst.leaves == ["target"], "target keeps the lower half")
	try expect(edgeSecond.leaves == ["new"], "top insertion places the new leaf second")

	try assertEdgeInsertionLandsWhereItWasAimed()
}

/// Tree order is only half the contract: an edge insertion has to occupy the
/// half of the target the user aimed at once the layout is solved.
private func assertEdgeInsertionLandsWhereItWasAimed() throws {
	let displayFrames: [DisplayID: LayoutRect] = [
		ShowcasePreset.mainDisplayID: .init(x: 0, y: 0, width: 2_560, height: 1_440),
	]
	for edge: LayoutEdge in [.leading, .trailing, .top, .bottom] {
		var presentation: WorkspacePresentation = ShowcasePreset.presentation()
		let before: PresentationLayout = try ConstrainedLayoutSolver.solve(
			presentation: presentation,
			displayFrames: displayFrames
		)
		let targetFrame: LayoutRect = try unwrap(
			before.panelFrames[ShowcasePreset.claudePanelID],
			"missing solved target Panel"
		)
		let insertedID: PanelID = .init("inserted-\(edge.rawValue)")
		let target: PanelDescriptor = try panelDescriptor(
			ShowcasePreset.claudePanelID,
			in: presentation
		)
		try presentation.insertPanel(
			.init(
				id: insertedID,
				title: target.title,
				kindID: target.kindID,
				providerHint: target.providerHint,
				profileOverride: target.profileOverride,
				nativeContent: .none
			),
			in: ShowcasePreset.fochWorkspaceID,
			at: edge,
			of: ShowcasePreset.claudePanelID,
			splitID: .init("split-\(edge.rawValue)")
		)
		let after: PresentationLayout = try ConstrainedLayoutSolver.solve(
			presentation: presentation,
			displayFrames: displayFrames
		)
		let inserted: LayoutRect = try unwrap(
			after.panelFrames[insertedID],
			"missing solved inserted Panel"
		)
		switch edge {
		case .leading:
			try expect(
				inserted.maxX <= targetFrame.midX + 1,
				"a leading insertion must take the leading half, got \(inserted)"
			)
		case .trailing:
			try expect(
				inserted.minX >= targetFrame.midX - 1,
				"a trailing insertion must take the trailing half, got \(inserted)"
			)
		case .top:
			try expect(
				inserted.minY >= targetFrame.midY - 1,
				"a top insertion must take the upper half, got \(inserted)"
			)
		case .bottom:
			try expect(
				inserted.maxY <= targetFrame.midY + 1,
				"a bottom insertion must take the lower half, got \(inserted)"
			)
		}
	}
}

private func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
	guard let value else { throw TestFailure.assertion(message) }
	return value
}

private func testVirtualFocusSurvivesPresentationRoundTrip() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	let initialFocus: VirtualFocusState = presentation.virtualFocus
	try presentation.focusWorkspace(ShowcasePreset.researchWorkspaceID)
	let focused: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			ShowcasePreset.mainDisplayID: .init(
				x: 0,
				y: 0,
				width: 1_400,
				height: 900
			),
		]
	)
	try expect(focused.workspaceFrames.count == 1, "focus mode solves one Workspace")
	try expect(
		focused.workspaceFrames[ShowcasePreset.researchWorkspaceID]
			== .init(x: 0, y: 0, width: 1_400, height: 900),
		"focused Workspace must fill its display"
	)
	try expect(
		presentation.virtualFocus == initialFocus,
		"layout focus must not steal or rewrite virtual focus"
	)
	presentation.showTiled()
	try expect(presentation.mode == .tiled, "showTiled must restore tiled presentation")
	try expect(
		presentation.virtualFocus == initialFocus,
		"tiled round trip must retain virtual focus"
	)
}

private func testMultiDisplayAffinity() throws {
	let main: DisplayID = .init("main-display")
	let secondary: DisplayID = .init("secondary-display")
	var presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: main
	)
	try presentation.displayLayouts[main]!.workspaceTree.remove(
		ShowcasePreset.sortAndPourWorkspaceID
	)
	presentation.displayLayouts[secondary] = .init(
		displayID: secondary,
		workspaceTree: .leaf(ShowcasePreset.sortAndPourWorkspaceID)
	)
	presentation.workspaces[
		ShowcasePreset.sortAndPourWorkspaceID
	]!.displayAffinity = secondary

	let mainFrame: LayoutRect = .init(x: 0, y: 0, width: 2_560, height: 1_400)
	let secondaryFrame: LayoutRect = .init(
		x: -1_440,
		y: 100,
		width: 1_440,
		height: 900
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [main: mainFrame, secondary: secondaryFrame]
	)
	let sortFrame: LayoutRect = layout.workspaceFrames[
		ShowcasePreset.sortAndPourWorkspaceID
	]!
	try expect(
		secondaryFrame.contains(sortFrame),
		"Workspace must remain on its affine display"
	)
	for workspaceID: WorkspaceID in presentation.workspaces.keys
		where workspaceID != ShowcasePreset.sortAndPourWorkspaceID
	{
		try expect(
			mainFrame.contains(layout.workspaceFrames[workspaceID]!),
			"other Workspaces must stay on the primary display"
		)
	}
}

/// Every open canvas is one display, so focus has to be scoped to the canvas it
/// happens on. The focused Workspace takes over its own display, and every other
/// display must be solved exactly as the tiled mode would solve it — otherwise
/// focusing on one canvas blanks the rest.
private func testFocusIsScopedToItsOwnDisplay() throws {
	let main: DisplayID = .init("main-display")
	let secondary: DisplayID = .init("secondary-display")
	let secondarySplitID: LayoutSplitID = .init("secondary-workspaces")
	let secondaryWorkspaceIDs: [WorkspaceID] = [
		ShowcasePreset.paperWorkspaceID,
		ShowcasePreset.sortAndPourWorkspaceID,
	]
	var presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: main
	)
	for workspaceID: WorkspaceID in secondaryWorkspaceIDs {
		try presentation.displayLayouts[main]!.workspaceTree.remove(workspaceID)
		presentation.workspaces[workspaceID]!.displayAffinity = secondary
	}
	// Two Workspaces on the second display, so it owns a display-scope divider
	// and ratio that the focused solve has something to preserve.
	presentation.displayLayouts[secondary] = .init(
		displayID: secondary,
		workspaceTree: .split(
			id: secondarySplitID,
			axis: .horizontal,
			preference: .init(desiredRatio: 0.45),
			first: .leaf(ShowcasePreset.paperWorkspaceID),
			second: .leaf(ShowcasePreset.sortAndPourWorkspaceID)
		)
	)

	let mainFrame: LayoutRect = .init(x: 0, y: 0, width: 2_560, height: 1_400)
	let secondaryFrame: LayoutRect = .init(
		x: -1_440,
		y: 100,
		width: 1_440,
		height: 900
	)
	let displayFrames: [DisplayID: LayoutRect] = [
		main: mainFrame,
		secondary: secondaryFrame,
	]
	let tiled: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: displayFrames
	)
	try expect(
		tiled.dividers.filter { $0.scope == .display(main) }.count == 3,
		"the fixture must give the focused display dividers there are to suppress"
	)

	try presentation.focusWorkspace(ShowcasePreset.researchWorkspaceID)
	let focused: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: displayFrames
	)

	try expect(
		focused.workspaceFrames[ShowcasePreset.researchWorkspaceID] == mainFrame,
		"the focused Workspace must fill the display it is placed on"
	)
	try expect(
		focused.workspaceFrames.count == 3,
		"focus must hide only the other Workspaces of its own display"
	)
	try expect(
		focused.panelFrames.count == 4,
		"only the focused Workspace's two Panels plus the other display's two"
	)
	try expect(
		focused.dividers.filter { $0.scope == .display(main) }.isEmpty,
		"the focused display exposes no Workspace dividers"
	)
	try expect(
		!focused.effectiveRatios.keys.contains { $0.scope == .display(main) },
		"the focused display exposes no Workspace split ratios"
	)

	// The other display is untouched: the same solve has to reproduce its tiled
	// slices exactly, not merely keep them somewhere inside its frame.
	for workspaceID: WorkspaceID in secondaryWorkspaceIDs {
		let expected: LayoutRect = try unwrap(
			tiled.workspaceFrames[workspaceID],
			"missing tiled Workspace \(workspaceID.rawValue)"
		)
		let actual: LayoutRect = try unwrap(
			focused.workspaceFrames[workspaceID],
			"focus dropped Workspace \(workspaceID.rawValue) from another display"
		)
		try expect(
			actual == expected,
			"Workspace \(workspaceID.rawValue) must keep its tiled frame, got \(actual)"
		)
		try expect(
			secondaryFrame.contains(actual),
			"Workspace \(workspaceID.rawValue) must stay on its own display"
		)
	}
	for panelID: PanelID in [
		ShowcasePreset.previewPanelID,
		ShowcasePreset.chromePanelID,
	] {
		let expected: LayoutRect = try unwrap(
			tiled.panelFrames[panelID],
			"missing tiled Panel \(panelID.rawValue)"
		)
		let actual: LayoutRect = try unwrap(
			focused.panelFrames[panelID],
			"focus dropped Panel \(panelID.rawValue) from another display"
		)
		try expect(
			actual == expected,
			"Panel \(panelID.rawValue) must keep its tiled frame, got \(actual)"
		)
	}

	let secondaryDividers: [LayoutDivider] = focused.dividers.filter {
		$0.scope == .display(secondary)
	}
	try expect(
		secondaryDividers.count == 1,
		"the unfocused display's Workspace divider must survive the focused solve"
	)
	try expect(
		secondaryDividers == tiled.dividers.filter { $0.scope == .display(secondary) },
		"the unfocused display's dividers must match the tiled solve"
	)
	let secondaryReference: LayoutSplitReference = .init(
		scope: .display(secondary),
		splitID: secondarySplitID
	)
	let tiledRatio: Double = try unwrap(
		tiled.effectiveRatios[secondaryReference],
		"missing tiled Workspace ratio on the unfocused display"
	)
	let focusedRatio: Double = try unwrap(
		focused.effectiveRatios[secondaryReference],
		"focus dropped the Workspace ratio of another display"
	)
	// Same code path and same inputs, so this is bit-identical, not merely close.
	try expect(
		focusedRatio == tiledRatio,
		"the unfocused display must keep its effective Workspace ratio"
	)
}

/// One canvas is still the common case, and the per-display branch must leave it
/// alone: with a single display there is no other display to tile, so focus
/// solves the focused Workspace and nothing else.
private func testSingleDisplayFocusIsUnchanged() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	try presentation.focusWorkspace(ShowcasePreset.teaserWorkspaceID)
	let displayFrame: LayoutRect = .init(x: 12, y: -40, width: 1_512, height: 900)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [ShowcasePreset.mainDisplayID: displayFrame]
	)
	try expect(
		layout.workspaceFrames.count == 1,
		"a single display leaves exactly the focused Workspace"
	)
	try expect(
		layout.workspaceFrames[ShowcasePreset.teaserWorkspaceID] == displayFrame,
		"the focused Workspace must fill its only display"
	)
	try expect(
		layout.panelFrames.count == 3,
		"only the focused Workspace's Panels are solved"
	)
	try expect(
		layout.dividers.allSatisfy {
			$0.scope == .workspace(ShowcasePreset.teaserWorkspaceID)
		},
		"a single-display focus exposes no Workspace dividers"
	)
}

private func testCodableRoundTripsPresentationAndCustomKinds() throws {
	let customKind: PanelKindDefinition = .init(
		id: .init("custom.timeline"),
		displayName: "Timeline",
		defaultProfile: .init(
			minimumSize: .init(width: 500, height: 180),
			preferredAspectRatio: .init(2.0, 4.0),
			growthWeight: 1.4
		)
	)
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	try presentation.panelKinds.register(customKind)
	let data: Data = try JSONEncoder().encode(presentation)
	let decoded: WorkspacePresentation = try JSONDecoder().decode(
		WorkspacePresentation.self,
		from: data
	)
	try expect(decoded == presentation, "presentation must survive a Codable round trip")
	try expect(
		decoded.panelKinds.definition(for: customKind.id) == customKind,
		"custom Panel definitions must be persisted"
	)
}

private func testUndersizedRegionAdaptsInsteadOfFailing() throws {
	// The six-Workspace preset wants about 1968×812 pt. Smaller canvases, down to
	// a tiny one, must still lay out every Panel rather than refuse.
	let presentation: WorkspacePresentation = ShowcasePreset.presentation()
	for size: LayoutSize in [
		.init(width: 1_200, height: 800), .init(width: 1_000, height: 700),
		.init(width: 300, height: 200),
	] {
		let display: LayoutRect = .init(x: 0, y: 0, width: size.width, height: size.height)
		let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
			presentation: presentation,
			displayFrames: [ShowcasePreset.mainDisplayID: display]
		)
		try expect(
			layout.panelFrames.count == 9,
			"a \(size.width)×\(size.height) region must still place every Panel"
		)
		try assertNoOverlap(layout.panelFrames, "adapted Panels must not overlap")
		for (panelID, frame): (PanelID, LayoutRect) in layout.panelFrames {
			try expect(
				frame.origin.x >= -0.001 && frame.origin.y >= -0.001
					&& frame.origin.x + frame.size.width <= size.width + 0.001
					&& frame.origin.y + frame.size.height <= size.height + 0.001,
				"Panel \(panelID.rawValue) must stay inside the \(size.width)×\(size.height) region"
			)
		}
	}
}

private func testShowcaseFitsLaptopDisplays() throws {
	let presentation: WorkspacePresentation = ShowcasePreset.presentation()
	for size: LayoutSize in [
		.init(width: 1_440, height: 800), .init(width: 1_512, height: 900),
		.init(width: 1_600, height: 900), .init(width: 1_728, height: 1_000),
	] {
		let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
			presentation: presentation,
			displayFrames: [ShowcasePreset.mainDisplayID: .init(x: 0, y: 0, width: size.width, height: size.height)]
		)
		try expect(layout.workspaceFrames.count == 6 && layout.panelFrames.count == 9,
			"laptop displays must expose all six workspaces and nine drop targets")
		try assertNoOverlap(layout.panelFrames, "laptop targets must not overlap")
	}
}

private func run() throws {
	try testShowcaseFitsLaptopDisplays()
	try testShowcaseFillsWithoutOverlap()
	try testLayoutIsDeterministic()
	try testEdgeInsertionAndLongAxisSplit()
	try testVirtualFocusSurvivesPresentationRoundTrip()
	try testMultiDisplayAffinity()
	try testFocusIsScopedToItsOwnDisplay()
	try testSingleDisplayFocusIsUnchanged()
	try testCodableRoundTripsPresentationAndCustomKinds()
	try testUndersizedRegionAdaptsInsteadOfFailing()
}

do {
	try run()
	print("Teaser layout tests passed")
} catch {
	fputs("Teaser layout tests failed: \(error)\n", stderr)
	exit(1)
}
