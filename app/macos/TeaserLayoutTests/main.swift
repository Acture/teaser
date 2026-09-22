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

// MARK: - Workspace contours

/// The gutters the solver will use. A same-group pair sits `panelGap` apart and
/// their inflated rectangles meet exactly; a between-group pair sits `groupGap`
/// apart and stays two fragments.
private let panelGap: Double = 4
private let groupGap: Double = 16
private let contourInflation: Double = panelGap / 2

private func contourInput(
	_ panelID: String,
	_ workspaceID: String,
	_ displayID: String = "canvas-1",
	x: Double,
	y: Double,
	width: Double = 100,
	height: Double = 100
) -> ContourInput {
	.init(
		panelID: .init(panelID),
		workspaceID: .init(workspaceID),
		displayID: .init(displayID),
		frame: .init(x: x, y: y, width: width, height: height)
	)
}

private func contour(
	_ contours: [WorkspaceContour],
	_ workspaceID: String
) throws -> WorkspaceContour {
	try unwrap(
		contours.first { $0.workspaceID == .init(workspaceID) },
		"missing contour for \(workspaceID)"
	)
}

private func solveContours(_ inputs: [ContourInput]) -> [WorkspaceContour] {
	WorkspaceContourGeometry.contours(
		inputs,
		canvasOrder: [.init("canvas-1"), .init("canvas-2")],
		inflation: contourInflation
	)
}

/// Two Panels of one Workspace across a `panelGap` gutter are one continuous
/// boundary, not two boxes: the whole point of a group contour.
private func testAdjacentMembersTraceOneLoop() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("a2", "alpha", x: 100 + panelGap, y: 0),
	])
	try expect(contours.count == 1, "one Workspace must yield one contour")
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "adjacent members are one fragment")
	let outer: ContourLoop = alpha.fragments[0].outer
	try expect(
		outer.vertices.count == 4,
		"an adjacent pair is a rectangle, got \(outer.vertices.count) vertices"
	)
	try expect(!outer.isHole, "an outer boundary must wind counter-clockwise")
	try expect(
		alpha.fragments[0].panelIDs == [.init("a1"), .init("a2")],
		"both members belong to the fragment"
	)
	let xs: [Double] = outer.vertices.map(\.x).sorted()
	try expectApproximatelyEqual(xs.first ?? 0, -contourInflation, "left edge")
	try expectApproximatelyEqual(
		xs.last ?? 0,
		100 + panelGap + 100 + contourInflation,
		"right edge"
	)
}

/// An L is six vertices. A naive bounding box would report four and swallow the
/// corner the group does not occupy.
private func testLShapedFragmentKeepsItsConcaveCorner() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("a2", "alpha", x: 100 + panelGap, y: 0),
		contourInput("a3", "alpha", x: 0, y: 100 + panelGap),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "an L is one fragment")
	try expect(
		alpha.fragments[0].outer.vertices.count == 6,
		"an L has six corners, got \(alpha.fragments[0].outer.vertices.count)"
	)
}

/// A tall Panel facing two shorter ones is the case naive edge cancellation
/// gets wrong: its right edge equals neither neighbour's left edge, so a
/// divider line survives down the middle of one group.
private func testPartialEdgeOverlapLeavesNoInternalSegment() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("tall", "alpha", x: 0, y: 0, height: 100 + panelGap + 100),
		contourInput("low", "alpha", x: 100 + panelGap, y: 0),
		contourInput("high", "alpha", x: 100 + panelGap, y: 100 + panelGap),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "the three members are one fragment")
	try expect(
		alpha.fragments[0].outer.vertices.count == 4,
		"the union is a rectangle, got \(alpha.fragments[0].outer.vertices.count)"
	)
	try expect(alpha.fragments[0].holes.isEmpty, "a filled rectangle has no hole")
}

/// The case where partial overlap and a group boundary land on the same edge: a
/// tall member faced by one member above and one other-group Panel below, so
/// half of its right edge is interior and half is the group's outer edge. Edge
/// cancellation gets this wrong even with interval splitting, because an
/// interval has to cancel against membership rather than against geometry.
private func testOneEdgeIsHalfInteriorHalfBoundary() throws {
	let span: Double = 100 + panelGap + 100
	let contours: [WorkspaceContour] = solveContours([
		contourInput("tall", "alpha", x: 0, y: 0, height: span),
		contourInput("above", "alpha", x: 100 + panelGap, y: 100 + panelGap),
		contourInput("below", "beta", x: 100 + panelGap, y: 0),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "the two members stay one fragment")
	let outer: ContourLoop = alpha.fragments[0].outer
	// Spelled out, because the whole question is which half of the tall Panel's
	// right edge survives: the lower half at x = 102 does, the upper half does
	// not, and the boundary steps out to x = 206 only above y = 102.
	let expected: [LayoutPoint] = [
		.init(x: -contourInflation, y: -contourInflation),
		.init(x: 100 + contourInflation, y: -contourInflation),
		.init(x: 100 + contourInflation, y: 100 + contourInflation),
		.init(x: span + contourInflation, y: 100 + contourInflation),
		.init(x: span + contourInflation, y: span + contourInflation),
		.init(x: -contourInflation, y: span + contourInflation),
	]
	try expect(
		outer.vertices == expected,
		"expected \(expected), got \(outer.vertices)"
	)
	let beta: WorkspaceContour = try contour(contours, "beta")
	try expect(
		beta.fragments.count == 1 && beta.fragments[0].outer.vertices.count == 4,
		"the other group keeps its own rectangle"
	)
}

/// A group interrupted by another group is two fragments of one identity, not
/// one loop drawn around the intervening Panel.
private func testInterruptedGroupSplitsIntoFragments() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("b1", "beta", x: 100 + groupGap, y: 0),
		contourInput("a2", "alpha", x: 200 + 2 * groupGap, y: 0),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	let beta: WorkspaceContour = try contour(contours, "beta")
	try expect(alpha.fragments.count == 2, "the interrupted group has two fragments")
	try expect(beta.fragments.count == 1, "the intervening group has one")
	try expect(
		alpha.fragments.map(\.ordinal) == [1, 2],
		"fragments of one group are numbered across the whole group"
	)
	// The proof that no fragment swallows the other group: beta's Panel is
	// outside both of alpha's loops.
	for fragment: WorkspaceContourFragment in alpha.fragments {
		let xs: [Double] = fragment.outer.vertices.map(\.x)
		let minimum: Double = xs.min() ?? 0
		let maximum: Double = xs.max() ?? 0
		try expect(
			maximum <= 100 + groupGap || minimum >= 100 + groupGap + 100,
			"an alpha fragment must not span beta's Panel"
		)
	}
}

/// A same-group pair facing each other across the wider between-group gutter
/// stays two fragments. Deliberate: one loop there would have to swallow the
/// gutter that marks a group boundary. Pinned so it is on record.
private func testGroupGapSeparatesEvenSameGroupMembers() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("a2", "alpha", x: 100 + groupGap, y: 0),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(
		alpha.fragments.count == 2,
		"a group-width gutter does not merge two members"
	)
}

/// A group ringing another group's Panel strokes the inner edge too: leaving it
/// bare reads as if the enclosed Panel were a member.
private func testEnclosedOtherGroupBecomesAHole() throws {
	var inputs: [ContourInput] = []
	for column: Int in 0 ..< 3 {
		for row: Int in 0 ..< 3 {
			let isCentre: Bool = column == 1 && row == 1
			inputs.append(
				contourInput(
					"p\(column)\(row)",
					isCentre ? "beta" : "alpha",
					x: Double(column) * (100 + panelGap),
					y: Double(row) * (100 + panelGap)
				)
			)
		}
	}
	let contours: [WorkspaceContour] = solveContours(inputs)
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "the ring is one fragment")
	let fragment: WorkspaceContourFragment = alpha.fragments[0]
	try expect(fragment.outer.vertices.count == 4, "the ring's outside is a rectangle")
	try expect(fragment.holes.count == 1, "the enclosed Panel is one hole")
	try expect(fragment.holes[0].isHole, "a hole must wind clockwise")
	try expect(
		fragment.holes[0].vertices.count == 4,
		"the hole around one Panel is a rectangle"
	)
}

/// Two members touching only at a corner are two fragments sharing a vertex,
/// never one pinched loop. A diagonal neighbour is not a neighbour.
private func testDiagonalTouchIsNotAdjacency() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("a2", "alpha", x: 100 + panelGap, y: 100 + panelGap),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(
		alpha.fragments.count == 2,
		"a corner touch is not adjacency"
	)
}

/// The contour is drawn in the gutter, so it can never cover a Panel's content
/// and can never be mistaken for the Panel's own edge.
private func testContoursStayOutOfEveryPanel() throws {
	let inputs: [ContourInput] = [
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("a2", "alpha", x: 100 + panelGap, y: 0),
		contourInput("b1", "beta", x: 0, y: 100 + groupGap),
		contourInput("b2", "beta", x: 100 + panelGap, y: 100 + groupGap),
	]
	for loop: ContourLoop in solveContours(inputs).flatMap({
		$0.fragments.flatMap { [$0.outer] + $0.holes }
	}) {
		for vertex: LayoutPoint in loop.vertices {
			for input: ContourInput in inputs {
				let frame: LayoutRect = input.frame
				try expect(
					!(vertex.x > frame.minX && vertex.x < frame.maxX
						&& vertex.y > frame.minY && vertex.y < frame.maxY),
					"a contour vertex landed inside \(input.panelID.rawValue)"
				)
			}
		}
	}
}

/// One Workspace split over two canvases is one identity with numbered
/// fragments, in canvas order.
private func testOneGroupAcrossTwoCanvases() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", "canvas-1", x: 0, y: 0),
		contourInput("a2", "alpha", "canvas-2", x: 0, y: 0),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 2, "one group, two canvases, two fragments")
	try expect(
		alpha.fragments.map(\.displayID) == [.init("canvas-1"), .init("canvas-2")],
		"fragments follow canvas order"
	)
	try expect(alpha.fragments.map(\.ordinal) == [1, 2], "ordinals run group-wide")
}

private func testContoursAreDeterministic() throws {
	let inputs: [ContourInput] = [
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("b1", "beta", x: 100 + groupGap, y: 0),
		contourInput("a2", "alpha", x: 0, y: 100 + panelGap),
	]
	try expect(
		solveContours(inputs) == solveContours(inputs.reversed()),
		"contours must not depend on input order"
	)
}

private func testDegenerateFramesAreDropped() throws {
	let contours: [WorkspaceContour] = solveContours([
		contourInput("a1", "alpha", x: 0, y: 0),
		contourInput("zero", "alpha", x: 200, y: 0, width: 0),
		contourInput("nan", "alpha", x: .nan, y: 0),
	])
	let alpha: WorkspaceContour = try contour(contours, "alpha")
	try expect(alpha.fragments.count == 1, "a degenerate frame draws nothing")
	try expect(
		alpha.fragments[0].panelIDs == [.init("a1")],
		"a degenerate frame joins no fragment"
	)
}

/// The palette exists to be told apart from the focus ring and the drop
/// highlight, which are both systemBlue.
private func testPaletteStaysClearOfTheFocusBlue() throws {
	let focusBlue: WorkspaceContourColor = .init(red: 0, green: 0.478, blue: 1)
	try expect(WorkspaceContourPalette.colors.count == 10, "ten hues")
	for color: WorkspaceContourColor in WorkspaceContourPalette.colors {
		let distance: Double = (
			pow(color.red - focusBlue.red, 2)
				+ pow(color.green - focusBlue.green, 2)
				+ pow(color.blue - focusBlue.blue, 2)
		).squareRoot()
		try expect(
			distance >= 0.6,
			"\(color) is only \(distance) from the focus blue"
		)
	}
}

/// A Workspace keeps its colour across launches and across clients, so the
/// hash cannot be Swift's per-process-seeded one.
private func testColourAssignmentIsStableAndOrderIndependent() throws {
	let ids: [WorkspaceID] = ["alpha", "beta", "gamma", "delta"].map {
		WorkspaceID($0)
	}
	let assignment: [WorkspaceID: WorkspaceContourColor] =
		WorkspaceContourPalette.assignment(for: ids)
	try expect(
		assignment == WorkspaceContourPalette.assignment(for: ids.reversed()),
		"assignment must not depend on input order"
	)
	try expect(
		Set(assignment.values).count == ids.count,
		"four Workspaces must not share a hue"
	)
	// FNV-1a over the ID's own bytes. Recomputing the constant here is the guard
	// against the primitive being swapped for a seeded hash, which would repaint
	// every canvas on each launch and never agree between two clients.
	var expected: UInt64 = 0xcbf2_9ce4_8422_2325
	for byte: UInt8 in Array("alpha".utf8) {
		expected ^= UInt64(byte)
		expected = expected &* 0x0000_0100_0000_01b3
	}
	expected ^= expected >> 32
	try expect(
		WorkspaceContourPalette.hash(.init("alpha")) == expected,
		"the palette hash must stay FNV-1a over the ID's bytes"
	)
	for id: WorkspaceID in ids {
		try expect(
			WorkspaceContourPalette.baseIndex(id)
				< WorkspaceContourPalette.colors.count,
			"a base index must land inside the palette"
		)
	}
}

private func run() throws {
	try testAdjacentMembersTraceOneLoop()
	try testLShapedFragmentKeepsItsConcaveCorner()
	try testPartialEdgeOverlapLeavesNoInternalSegment()
	try testOneEdgeIsHalfInteriorHalfBoundary()
	try testInterruptedGroupSplitsIntoFragments()
	try testGroupGapSeparatesEvenSameGroupMembers()
	try testEnclosedOtherGroupBecomesAHole()
	try testDiagonalTouchIsNotAdjacency()
	try testContoursStayOutOfEveryPanel()
	try testOneGroupAcrossTwoCanvases()
	try testContoursAreDeterministic()
	try testDegenerateFramesAreDropped()
	try testPaletteStaysClearOfTheFocusBlue()
	try testColourAssignmentIsStableAndOrderIndependent()
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
