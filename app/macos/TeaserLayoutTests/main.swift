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
	guard let panel: PanelDescriptor = presentation.panels[panelID] else {
		throw TestFailure.assertion("missing Panel descriptor \(panelID.rawValue)")
	}
	return panel
}

private func testShowcaseFillsWithoutOverlap() throws {
	let displayID: DisplayID = .init("display-1")
	let displayFrame: LayoutRect = .init(x: -160, y: 24, width: 2_560, height: 1_400)
	let presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: displayID
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [displayID: displayFrame]
	)

	try expect(layout.panelFrames.count == 9, "showcase must contain nine Panels")
	try expect(layout.dividers.count == 8, "all slicing-tree dividers must be exposed")
	try assertNoOverlap(layout.panelFrames, "Panels must not overlap")

	// One flat tree per canvas: Panels plus their gutters account for the whole
	// canvas, with no Workspace rectangle in between.
	let panelArea: Double = layout.panelFrames.values.reduce(0) { $0 + $1.size.area }
	let dividerArea: Double = layout.dividers.reduce(0) { $0 + $1.frame.size.area }
	try expectApproximatelyEqual(
		panelArea + dividerArea,
		ConstrainedLayoutSolver().layoutFrame(inCanvas: displayFrame).size.area,
		"Panels and gutters must exactly fill the canvas inside its gutter"
	)

	for (panelID, frame): (PanelID, LayoutRect) in layout.panelFrames {
		let panel: PanelDescriptor = try unwrap(
			presentation.panels[panelID],
			"missing Panel descriptor \(panelID.rawValue)"
		)
		let profile: LayoutProfile = try unwrap(
			panel.profileOverride
				?? presentation.panelKinds.definition(for: panel.kindID)?.defaultProfile,
			"missing profile"
		)
		try expect(
			frame.size.width + 0.000_001 >= profile.minimumSize.width,
			"Panel minimum width must be enforced"
		)
		try expect(
			frame.size.height + 0.000_001 >= profile.minimumSize.height,
			"Panel minimum height must be enforced"
		)
	}

	// Several groups share one canvas without any of them owning a rectangle.
	let groups: Set<WorkspaceID> = .init(
		layout.panelFrames.keys.compactMap { presentation.workspaceID(of: $0) }
	)
	try expect(groups.count == 6, "the showcase places six groups on one canvas")
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
		presentation: presentation, displayFrames: frames
	)
	let second: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: frames
	)
	try expect(first == second, "identical inputs must produce identical layouts")
}

private func testEdgeInsertionAndLongAxisSplit() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	let panel: PanelDescriptor = .init(
		id: .init("foch-shell"),
		title: "Shell",
		workspaceID: ShowcasePreset.fochWorkspaceID,
		kindID: .generic,
		providerHint: nil,
		profileOverride: nil,
		nativeContent: .none
	)
	try presentation.splitPanel(
		ShowcasePreset.claudePanelID,
		with: panel,
		onCanvas: ShowcasePreset.mainDisplayID,
		targetFrame: .init(x: 0, y: 0, width: 900, height: 400),
		splitID: .init("foch-shell-split")
	)
	let tree: LayoutTree<PanelID> = try unwrap(
		presentation.canvases[ShowcasePreset.mainDisplayID]?.panelTree,
		"the canvas must have a tree"
	)
	try expect(
		tree.contains(panel.id) && tree.contains(ShowcasePreset.claudePanelID),
		"a split keeps the target and adds the new Panel to the same canvas"
	)
	try expect(
		presentation.workspaceID(of: panel.id) == ShowcasePreset.fochWorkspaceID,
		"a Panel split off another starts in the same group"
	)

	var edgeTree: LayoutTree<String> = .leaf("target")
	try edgeTree.insert("new", at: .top, of: "target", splitID: .init("top"))
	guard case .split(_, let edgeAxis, _, let edgeFirst, let edgeSecond) = edgeTree else {
		throw TestFailure.assertion("edge insertion must create a split")
	}
	try expect(edgeAxis == .vertical, "a top edge splits on the vertical axis")
	try expect(
		edgeFirst.leaves == ["target"] && edgeSecond.leaves == ["new"],
		"the solver lays the first child lower, so a top insert is second"
	)
}

/// Placement and membership are separate: moving a Panel to another canvas must
/// leave its group alone, and a regroup must leave the trees alone.
private func testMoveChangesPlacementNotMembership() throws {
	let canvasA: DisplayID = .init("canvas-a")
	let canvasB: DisplayID = .init("canvas-b")
	var presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1
	)
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	let moved: PanelID = .init("second")
	let groupBefore: WorkspaceID? = presentation.workspaceID(of: moved)

	try presentation.movePanel(
		moved,
		toCanvas: canvasB,
		at: nil,
		of: nil,
		splitID: .init("moved")
	)
	try expect(
		presentation.canvasID(containing: moved) == canvasB,
		"a move must change which canvas holds the Panel"
	)
	try expect(
		presentation.workspaceID(of: moved) == groupBefore,
		"a move must never change the Panel's group"
	)
	try expect(
		presentation.panelIDs(onCanvas: weightedDisplayID) == [.init("first")],
		"the source canvas keeps exactly what is left"
	)

	// A regroup is the other half: membership changes, placement does not.
	let treeBefore: LayoutTree<PanelID>? = presentation.canvases[canvasB]?.panelTree
	presentation.panels[moved]?.workspaceID = .init("elsewhere")
	try expect(
		presentation.canvases[canvasB]?.panelTree == treeBefore,
		"a regroup must not move anything"
	)
	_ = canvasA
}

/// Moving the last Panel off a canvas leaves it blank rather than refusing.
/// `LayoutTree.remove` rejects removing an only leaf, which is exactly the case
/// a canvas holding its first Panel hits.
private func testMovingTheLastPanelLeavesTheCanvasBlank() throws {
	let canvasB: DisplayID = .init("canvas-b")
	var presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1
	)
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	try presentation.movePanel(.init("first"), toCanvas: canvasB, at: nil, of: nil,
		splitID: .init("m1"))
	try presentation.movePanel(.init("second"), toCanvas: canvasB, at: nil, of: nil,
		splitID: .init("m2"))
	try expect(
		presentation.canvases[weightedDisplayID]?.panelTree == nil,
		"a canvas emptied by moves must become blank, not refuse the move"
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 800, height: 600),
			canvasB: .init(x: 800, y: 0, width: 800, height: 600),
		]
	)
	try expect(layout.panelFrames.count == 2, "both Panels are still placed")
}

/// Each canvas is solved inside its own rectangle, so a Panel never straddles
/// two canvases and a closed canvas's Panels are simply not placed.
private func testEachCanvasSolvesInsideItsOwnRectangle() throws {
	let canvasA: DisplayID = .init("canvas-a")
	let canvasB: DisplayID = .init("canvas-b")
	var presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1
	)
	presentation.canvases = [
		canvasA: .init(displayID: canvasA, panelTree: .leaf(.init("first"))),
		canvasB: .init(displayID: canvasB, panelTree: .leaf(.init("second"))),
	]
	let frameA: LayoutRect = .init(x: 0, y: 0, width: 800, height: 600)
	let frameB: LayoutRect = .init(x: 2_000, y: 100, width: 900, height: 700)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [canvasA: frameA, canvasB: frameB]
	)
	let solver: ConstrainedLayoutSolver = .init()
	try expect(
		layout.panelFrames[.init("first")] == solver.layoutFrame(inCanvas: frameA),
		"canvas A fills its own rectangle inside the gutter"
	)
	try expect(
		layout.panelFrames[.init("second")] == solver.layoutFrame(inCanvas: frameB),
		"canvas B fills its own rectangle inside the gutter"
	)

	// A Panel the presentation still knows but no open canvas places is not an
	// error: its canvas is closed.
	presentation.canvases.removeValue(forKey: canvasB)
	let partial: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [canvasA: frameA]
	)
	try expect(
		partial.panelFrames.count == 1
			&& partial.panelFrames[.init("first")] == solver.layoutFrame(inCanvas: frameA),
		"a Panel on a closed canvas must not fail the solve"
	)
}

private func testVirtualFocusSurvivesPresentationRoundTrip() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	try presentation.setVirtualFocus(ShowcasePreset.notesPanelID)
	let data: Data = try JSONEncoder().encode(presentation)
	let restored: WorkspacePresentation = try JSONDecoder().decode(
		WorkspacePresentation.self, from: data
	)
	try expect(
		restored.virtualFocus.panelID == ShowcasePreset.notesPanelID,
		"Virtual Focus must survive a round trip"
	)
	try expect(restored == presentation, "a round trip must preserve the presentation")
}

private func testCodableRoundTripsPresentationAndCustomKinds() throws {
	var registry: PanelKindRegistry = try .init()
	try registry.register(.init(
		id: .init("custom"),
		displayName: "Custom",
		defaultProfile: .init(
			minimumSize: .init(width: 100, height: 100),
			preferredAspectRatio: .init(0.5, 2),
			growthWeight: 2
		)
	))
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	presentation.panelKinds = registry
	let data: Data = try JSONEncoder().encode(presentation)
	let restored: WorkspacePresentation = try JSONDecoder().decode(
		WorkspacePresentation.self, from: data
	)
	try expect(restored == presentation, "custom kinds must survive a round trip")
	try expect(
		restored.panelKinds.definition(for: .init("custom")) != nil,
		"a custom kind must still be registered after decoding"
	)
}

private func testUndersizedRegionAdaptsInsteadOfFailing() throws {
	// The six-group preset wants a lot of room. Smaller canvases, down to a tiny
	// one, must still lay out every Panel rather than refuse.
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
				"Panel \(panelID.rawValue) must stay inside the region"
			)
		}
	}
}

private func testShowcaseFitsLaptopDisplays() throws {
	for size: LayoutSize in [
		.init(width: 1_440, height: 900), .init(width: 1_512, height: 982),
	] {
		let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
			presentation: ShowcasePreset.presentation(),
			displayFrames: [
				ShowcasePreset.mainDisplayID:
					.init(x: 0, y: 0, width: size.width, height: size.height),
			]
		)
		try assertNoOverlap(layout.panelFrames, "laptop targets must not overlap")
	}
}

private func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
	guard let value else { throw TestFailure.assertion(message) }
	return value
}

// MARK: - Unequal sizing

private let weightedDisplayID: DisplayID = .init("canvas-1")
private let weightedWorkspaceID: WorkspaceID = .init("alpha")
private let weightedRootReference: LayoutSplitReference = .init(
	displayID: weightedDisplayID,
	splitID: .init("root")
)

/// Two Panels whose kinds ask to grow by different amounts, in one split whose
/// proportion the caller chooses. Minimums are deliberately tiny unless a case
/// wants them to bite, so a test about weights is not really a test about
/// minimums.
private func weightedPresentation(
	firstWeight: Double,
	secondWeight: Double,
	preference: SplitPreference = .derived,
	secondMinimum: LayoutSize = .init(width: 10, height: 10)
) throws -> WorkspacePresentation {
	func panel(_ id: String, _ weight: Double, _ minimum: LayoutSize) -> PanelDescriptor {
		.init(
			id: .init(id),
			title: id,
			workspaceID: weightedWorkspaceID,
			kindID: .generic,
			providerHint: nil,
			profileOverride: .init(
				minimumSize: minimum,
				preferredAspectRatio: .init(0.1, 10),
				growthWeight: weight
			),
			nativeContent: .none
		)
	}
	let first: PanelDescriptor = panel("first", firstWeight, .init(width: 10, height: 10))
	let second: PanelDescriptor = panel("second", secondWeight, secondMinimum)
	return .init(
		canvases: [
			weightedDisplayID: .init(
				displayID: weightedDisplayID,
				panelTree: .split(
					id: .init("root"),
					axis: .horizontal,
					preference: preference,
					first: .leaf(first.id),
					second: .leaf(second.id)
				)
			),
		],
		workspaces: [
			weightedWorkspaceID: .init(
				id: weightedWorkspaceID,
				title: "Alpha",
				detail: ""
			),
		],
		panels: [first.id: first, second.id: second],
		panelKinds: try .init()
	)
}

private func solvedRootRatio(
	_ presentation: WorkspacePresentation,
	width: Double = 1_000,
	height: Double = 500
) throws -> Double {
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: width, height: height),
		]
	)
	return try unwrap(
		layout.effectiveRatios[weightedRootReference],
		"the root split must be solved"
	)
}

/// The behaviour the ticket asks for: a split nobody has dragged is sized by the
/// Panels inside it. Before this, every split was created at exactly one half
/// and `growthWeight` was computed and discarded, which is what produced the
/// equal-width dashboard.
private func testDerivedRatioFollowsGrowthWeight() throws {
	let ratio: Double = try solvedRootRatio(
		try weightedPresentation(firstWeight: 1, secondWeight: 3)
	)
	try expectApproximatelyEqual(ratio, 0.25, "one against three must take a quarter")
	try expect(abs(ratio - 0.5) > 0.2, "a derived split must not fall back to halves")

	let even: Double = try solvedRootRatio(
		try weightedPresentation(firstWeight: 2, secondWeight: 2)
	)
	try expectApproximatelyEqual(even, 0.5, "equal weights still split evenly")
}

private func testUserRatioBeatsWeights() throws {
	let ratio: Double = try solvedRootRatio(
		try weightedPresentation(
			firstWeight: 1,
			secondWeight: 3,
			preference: .user(0.8)
		)
	)
	try expectApproximatelyEqual(ratio, 0.8, "a dragged divider outranks the weights")
}

/// Adding a Panel elsewhere must not disturb a proportion the person chose.
private func testUserRatioSurvivesInsertElsewhere() throws {
	var presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1,
		preference: .user(0.8)
	)
	try presentation.insertPanel(
		.init(
			id: .init("third"),
			title: "third",
			workspaceID: weightedWorkspaceID,
			kindID: .generic,
			providerHint: nil,
			profileOverride: .init(
				minimumSize: .init(width: 10, height: 10),
				preferredAspectRatio: .init(0.1, 10),
				growthWeight: 5
			),
			nativeContent: .none
		),
		onCanvas: weightedDisplayID,
		at: .trailing,
		of: .init("second"),
		splitID: .init("added")
	)
	try expectApproximatelyEqual(
		try solvedRootRatio(presentation),
		0.8,
		"an insert below a dragged divider must not move it"
	)
}

/// The mirror image: a split nobody has touched is allowed to re-proportion when
/// the Panels under it change, which is what "adjacency is a preference" needs.
private func testDerivedAncestorReproportionsOnInsert() throws {
	var presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1
	)
	try expectApproximatelyEqual(
		try solvedRootRatio(presentation),
		0.5,
		"two equal Panels start even"
	)
	try presentation.insertPanel(
		.init(
			id: .init("third"),
			title: "third",
			workspaceID: weightedWorkspaceID,
			kindID: .generic,
			providerHint: nil,
			profileOverride: .init(
				minimumSize: .init(width: 10, height: 10),
				preferredAspectRatio: .init(0.1, 10),
				growthWeight: 1
			),
			nativeContent: .none
		),
		onCanvas: weightedDisplayID,
		at: .trailing,
		of: .init("second"),
		splitID: .init("added")
	)
	try expectApproximatelyEqual(
		try solvedRootRatio(presentation),
		1.0 / 3.0,
		"a derived root follows the Panels that arrived under it"
	)
}

/// A proportion the canvas is currently too small to honour must survive in the
/// model. Writing the clamped value back would quietly make the person's choice
/// permanent at whatever the smallest window happened to allow.
private func testClampedUserRatioIsNotWrittenBack() throws {
	let presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1,
		preference: .user(0.95),
		secondMinimum: .init(width: 400, height: 10)
	)
	let solved: Double = try solvedRootRatio(presentation)
	try expect(
		solved < 0.95,
		"a minimum must clamp the solve, got \(solved)"
	)
	guard case .split(_, _, let preference, _, _) = presentation
		.canvases[weightedDisplayID]?.panelTree
	else {
		throw TestFailure.assertion("the fixture must have a root split")
	}
	try expect(
		preference.userRatio == 0.95,
		"the clamped solve must not overwrite the stored proportion"
	)
}

// MARK: - Contours in the solved layout

/// The solver is the one place that sees every canvas, so it is where the
/// contours and the session-wide colour assignment come from.
private func testSolvedLayoutCarriesContours() throws {
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: try focusPresentation(), displayFrames: focusFrames()
	)
	let alpha: WorkspaceContour = try unwrap(
		layout.contours.first { $0.workspaceID == .init("alpha") },
		"alpha must have a contour"
	)
	// alpha holds a1 and a2 adjacent on one canvas, plus b-solo on the other.
	try expect(
		alpha.fragments.count == 2,
		"one group across two canvases is two fragments, got \(alpha.fragments.count)"
	)
	try expect(
		Set(alpha.fragments.map(\.displayID))
			== [weightedDisplayID, .init("canvas-b")],
		"the fragments must name the canvases they are on"
	)
	try expect(alpha.fragments.map(\.ordinal) == [1, 2], "ordinals run group-wide")
	try expect(
		layout.contourColors[.init("alpha")] != layout.contourColors[.init("beta")],
		"two groups must not share a colour"
	)
}

/// The contour is drawn in the gutter. If a vertex landed inside a Panel it
/// would cover that Panel's content — and, under a real adopted window, be
/// invisible anyway.
private func testSolvedContoursStayOutOfEveryPanel() throws {
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: try focusPresentation(), displayFrames: focusFrames()
	)
	for loop: ContourLoop in layout.contours.flatMap({
		$0.fragments.flatMap { [$0.outer] + $0.holes }
	}) {
		for vertex: LayoutPoint in loop.vertices {
			for (panelID, frame): (PanelID, LayoutRect) in layout.panelFrames {
				try expect(
					!(vertex.x > frame.minX && vertex.x < frame.maxX
						&& vertex.y > frame.minY && vertex.y < frame.maxY),
					"a contour vertex landed inside \(panelID.rawValue)"
				)
			}
		}
	}
}

/// Adjacent members of one group produce a single loop rather than one box per
/// Panel — the whole point of a group contour.
private func testAdjacentMembersShareOneSolvedLoop() throws {
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: try gapPresentation(),
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 1_000, height: 400),
		]
	)
	let alpha: WorkspaceContour = try unwrap(
		layout.contours.first { $0.workspaceID == .init("alpha") },
		"alpha must have a contour"
	)
	try expect(alpha.fragments.count == 1, "a1 and a2 are adjacent, so one fragment")
	try expect(
		alpha.fragments[0].outer.vertices.count == 4,
		"two adjacent Panels in a row outline one rectangle"
	)
	try expect(
		alpha.fragments[0].panelIDs == [.init("a1"), .init("a2")],
		"the fragment must name both members"
	)
}

/// An exclusive focus leaves the other group unframed, so it has no contour
/// either: an outline with nothing inside it would be a lie.
private func testExclusiveFocusLeavesNoContourForHiddenGroups() throws {
	var presentation: WorkspacePresentation = try gapPresentation()
	presentation.focusWorkspace(
		.init("alpha"), onCanvas: weightedDisplayID, exclusive: true
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 1_000, height: 400),
		]
	)
	try expect(
		!layout.contours.contains { $0.workspaceID == .init("beta") },
		"a group with no framed Panel must not be outlined"
	)
	try expect(
		layout.contours.contains { $0.workspaceID == .init("alpha") },
		"the focused group is still outlined"
	)
}

// MARK: - Focus

private func focusPresentation() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = try gapPresentation()
	presentation.canvases[.init("canvas-b")] = .init(
		displayID: .init("canvas-b"),
		panelTree: .leaf(.init("b-solo"))
	)
	presentation.panels[.init("b-solo")] = .init(
		id: .init("b-solo"),
		title: "b-solo",
		workspaceID: .init("alpha"),
		kindID: .generic,
		providerHint: nil,
		profileOverride: .init(
			minimumSize: .init(width: 10, height: 10),
			preferredAspectRatio: .init(0.1, 10),
			growthWeight: 1
		),
		nativeContent: .none
	)
	return presentation
}

private func focusFrames() -> [DisplayID: LayoutRect] {
	[
		weightedDisplayID: .init(x: 0, y: 0, width: 1_000, height: 400),
		.init("canvas-b"): .init(x: 1_000, y: 0, width: 1_000, height: 400),
	]
}

/// The first stage is weight, not a takeover: the emphasised group grows and
/// everything else stays placed and usable. Teaser cannot lower another
/// application's window, so a Panel removed from the layout would strand its
/// window on top of the layout rather than behind it.
private func testEmphasisGrowsWithoutHidingAnything() throws {
	var presentation: WorkspacePresentation = try focusPresentation()
	let before: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	presentation.focusWorkspace(.init("beta"), onCanvas: weightedDisplayID)
	let after: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	try expect(
		after.panelFrames.count == before.panelFrames.count,
		"emphasis must not remove a Panel from the layout"
	)
	let beta: LayoutRect = try unwrap(after.panelFrames[.init("b1")], "beta Panel")
	let betaBefore: LayoutRect = try unwrap(before.panelFrames[.init("b1")], "beta before")
	try expect(
		beta.size.width > betaBefore.size.width,
		"the emphasised group must actually grow"
	)
	try expect(
		(after.panelFrames[.init("a1")]?.size.width ?? 0) > 0,
		"an unfocused Panel must keep a usable rectangle"
	)
}

/// The second stage gives the group the canvas. It prunes the solve only: the
/// stored tree, its split IDs and every chosen proportion are untouched, which
/// is what lets clearing focus restore the canvas exactly.
private func testExclusivePrunesTheSolveNotTheTree() throws {
	var presentation: WorkspacePresentation = try focusPresentation()
	let storedBefore: LayoutTree<PanelID>? = presentation
		.canvases[weightedDisplayID]?.panelTree
	let tiled: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	presentation.focusWorkspace(
		.init("alpha"), onCanvas: weightedDisplayID, exclusive: true
	)
	let exclusive: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	try expect(
		exclusive.panelFrames[.init("b1")] == nil,
		"an exclusive focus must leave the other group unframed"
	)
	try expect(
		exclusive.panelFrames[.init("a1")] != nil
			&& exclusive.panelFrames[.init("a2")] != nil,
		"the focused group keeps every member"
	)
	try expect(
		presentation.canvases[weightedDisplayID]?.panelTree == storedBefore,
		"focus must not touch the stored tree"
	)

	presentation.clearFocus(onCanvas: weightedDisplayID)
	let restored: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	try expect(restored == tiled, "clearing focus must restore the canvas exactly")
}

/// Focus is per canvas and can only emphasise what the canvas already holds, so
/// it never reaches across to recall a member placed elsewhere.
private func testFocusOnlyChangesItsOwnCanvas() throws {
	var presentation: WorkspacePresentation = try focusPresentation()
	let before: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	presentation.focusWorkspace(
		.init("alpha"), onCanvas: weightedDisplayID, exclusive: true
	)
	let after: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	try expect(
		after.panelFrames[.init("b-solo")] == before.panelFrames[.init("b-solo")],
		"the other canvas must be byte-identical"
	)
	try expect(
		presentation.canvasID(containing: .init("b-solo")) == .init("canvas-b"),
		"focus must never recall a member from another canvas"
	)
}

/// A canvas can only focus a group it holds. Refusing keeps the promise that
/// focus never pulls members in from elsewhere.
private func testFocusOnAnAbsentGroupIsRefused() throws {
	var presentation: WorkspacePresentation = try focusPresentation()
	try expect(
		!presentation.focusWorkspace(.init("beta"), onCanvas: .init("canvas-b")),
		"a canvas with no member of that group must refuse"
	)
	try expect(
		presentation.canvases[.init("canvas-b")]?.focus == nil,
		"a refused focus must change nothing"
	)
}

/// Emphasis moves only the dividers that separate the focused group. A
/// proportion the person chose *inside* that group is theirs and stays put.
private func testFocusMovesOnlyBoundaryDividers() throws {
	var presentation: WorkspacePresentation = try focusPresentation()
	presentation.focusWorkspace(.init("alpha"), onCanvas: weightedDisplayID)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation, displayFrames: focusFrames()
	)
	let inner: Double = try unwrap(
		layout.effectiveRatios[
			.init(displayID: weightedDisplayID, splitID: .init("inner"))
		],
		"the within-group divider must be solved"
	)
	try expectApproximatelyEqual(
		inner, 0.5, "a divider inside the focused group keeps its chosen ratio"
	)
	let root: Double = try unwrap(
		layout.effectiveRatios[
			.init(displayID: weightedDisplayID, splitID: .init("root"))
		],
		"the boundary divider must be solved"
	)
	try expect(root > 0.5, "the boundary divider must move for the focused group")
}

// MARK: - Degradation

/// A canvas too small to honour a Panel's minimum still lays every Panel out —
/// refusing would leave the person with nothing — but it says which Panels it
/// could not satisfy and what they need.
private func testShortfallsAreReportedNotThrown() throws {
	let presentation: WorkspacePresentation = try weightedPresentation(
		firstWeight: 1,
		secondWeight: 1,
		secondMinimum: .init(width: 600, height: 400)
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 300, height: 200),
		]
	)
	try expect(layout.panelFrames.count == 2, "every Panel is still placed")
	let needed: LayoutSize = try unwrap(
		layout.quality.shortfalls[.init("second")],
		"the Panel that could not fit must be reported"
	)
	try expect(
		needed == .init(width: 600, height: 400),
		"the report must state the size the Panel actually needs"
	)
}

private func testNoShortfallOnAGenerousCanvas() throws {
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: try weightedPresentation(firstWeight: 1, secondWeight: 1),
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 2_000, height: 1_200),
		]
	)
	try expect(
		layout.quality.shortfalls.isEmpty,
		"a canvas with room to spare must report nothing"
	)
}

/// A Panel given exactly its minimum must not be reported: the split arithmetic
/// can land a fraction of a point under, and a warning that never clears is
/// noise rather than an explanation.
private func testExactFitIsNotAShortfall() throws {
	let solver: ConstrainedLayoutSolver = .init()
	let layout: PresentationLayout = try solver.solve(
		presentation: try gapPresentation(),
		displayFrames: [
			weightedDisplayID: .init(
				x: 0,
				y: 0,
				width: 30 + solver.panelGap + solver.groupGap + 2 * solver.groupGap,
				height: 200
			),
		]
	)
	try expect(
		layout.quality.shortfalls.isEmpty,
		"an exact fit is satisfied, not short: \(layout.quality.shortfalls)"
	)
}

// MARK: - Gap hierarchy

/// Three Panels in a row where only the outer two share a group, so one split
/// is inside a group and the other crosses one.
private func gapPresentation() throws -> WorkspacePresentation {
	func panel(_ id: String, _ group: String) -> PanelDescriptor {
		.init(
			id: .init(id),
			title: id,
			workspaceID: .init(group),
			kindID: .generic,
			providerHint: nil,
			profileOverride: .init(
				minimumSize: .init(width: 10, height: 10),
				preferredAspectRatio: .init(0.1, 10),
				growthWeight: 1
			),
			nativeContent: .none
		)
	}
	let members: [PanelDescriptor] = [
		panel("a1", "alpha"), panel("a2", "alpha"), panel("b1", "beta"),
	]
	return .init(
		canvases: [
			weightedDisplayID: .init(
				displayID: weightedDisplayID,
				panelTree: .split(
					id: .init("root"),
					axis: .horizontal,
					preference: .user(0.5),
					first: .split(
						id: .init("inner"),
						axis: .horizontal,
						preference: .user(0.5),
						first: .leaf(.init("a1")),
						second: .leaf(.init("a2"))
					),
					second: .leaf(.init("b1"))
				)
			),
		],
		workspaces: [
			.init("alpha"): .init(id: .init("alpha"), title: "Alpha", detail: ""),
			.init("beta"): .init(id: .init("beta"), title: "Beta", detail: ""),
		],
		panels: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) }),
		panelKinds: try .init()
	)
}

/// Spacing carries the hierarchy: tight inside a group, open between groups.
/// Without this every gutter is the same width and the only thing separating
/// two groups is the contour itself.
private func testGroupGapAppliesOnlyBetweenGroups() throws {
	let solver: ConstrainedLayoutSolver = .init()
	let layout: PresentationLayout = try solver.solve(
		presentation: try gapPresentation(),
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 1_000, height: 400),
		]
	)
	let inner: LayoutDivider = try unwrap(
		layout.dividers.first { $0.splitID == .init("inner") },
		"the within-group divider must be solved"
	)
	let root: LayoutDivider = try unwrap(
		layout.dividers.first { $0.splitID == .init("root") },
		"the cross-group divider must be solved"
	)
	try expect(!inner.crossesGroups, "a split inside one group must not be marked")
	try expect(root.crossesGroups, "a split between two groups must be marked")
	try expectApproximatelyEqual(
		inner.frame.size.width, solver.panelGap, "within-group gutter"
	)
	try expectApproximatelyEqual(
		root.frame.size.width, solver.groupGap, "between-group gutter"
	)
	try expect(
		solver.groupGap > solver.panelGap,
		"the hierarchy only reads if the gutters actually differ"
	)
}

/// A subtree holding more than one group takes the wide gutter, because there
/// is no single group for it to be "inside".
private func testMixedSubtreeTakesTheWideGutter() throws {
	var presentation: WorkspacePresentation = try gapPresentation()
	presentation.panels[.init("a2")]?.workspaceID = .init("beta")
	let solver: ConstrainedLayoutSolver = .init()
	let layout: PresentationLayout = try solver.solve(
		presentation: presentation,
		displayFrames: [
			weightedDisplayID: .init(x: 0, y: 0, width: 1_000, height: 400),
		]
	)
	try expect(
		layout.dividers.allSatisfy(\.crossesGroups),
		"every divider here separates groups once a2 changes group"
	)
}

/// The measuring pass and the placing pass must agree on each gutter, or a
/// Panel's minimum is computed against a gap it is never actually given.
private func testGapAgreesWithMinimums() throws {
	let solver: ConstrainedLayoutSolver = .init()
	let layout: PresentationLayout = try solver.solve(
		presentation: try gapPresentation(),
		// Exactly the width three 10 pt minimums plus one narrow and one wide
		// gutter need, so any disagreement overflows or underfills visibly.
		displayFrames: [
			weightedDisplayID: .init(
				x: 0,
				y: 0,
				width: 30 + solver.panelGap + solver.groupGap + 2 * solver.groupGap,
				height: 200
			),
		]
	)
	try assertNoOverlap(layout.panelFrames, "a tight canvas must not overlap Panels")
	let total: Double = layout.panelFrames.values.reduce(0) { $0 + $1.size.width }
		+ layout.dividers.reduce(0) { $0 + $1.frame.size.width }
	try expectApproximatelyEqual(
		total,
		30 + solver.panelGap + solver.groupGap,
		"Panels and both gutters must exactly fill the laid-out width"
	)
}

/// A canvas too small for the inset keeps its whole rectangle rather than
/// collapsing, so a tiny canvas still lays every Panel out.
private func testUndersizedCanvasSkipsTheInset() throws {
	let solver: ConstrainedLayoutSolver = .init()
	let tiny: LayoutRect = .init(x: 0, y: 0, width: 20, height: 20)
	try expect(
		solver.layoutFrame(inCanvas: tiny) == tiny,
		"a canvas narrower than two gutters must not be inset away"
	)
	let roomy: LayoutRect = .init(x: 0, y: 0, width: 400, height: 300)
	try expect(
		solver.layoutFrame(inCanvas: roomy)
			== roomy.insetBy(dx: solver.groupGap, dy: solver.groupGap),
		"a roomy canvas is inset by exactly one group gutter"
	)
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
	try testSolvedLayoutCarriesContours()
	try testSolvedContoursStayOutOfEveryPanel()
	try testAdjacentMembersShareOneSolvedLoop()
	try testExclusiveFocusLeavesNoContourForHiddenGroups()
	try testEmphasisGrowsWithoutHidingAnything()
	try testExclusivePrunesTheSolveNotTheTree()
	try testFocusOnlyChangesItsOwnCanvas()
	try testFocusOnAnAbsentGroupIsRefused()
	try testFocusMovesOnlyBoundaryDividers()
	try testShortfallsAreReportedNotThrown()
	try testNoShortfallOnAGenerousCanvas()
	try testExactFitIsNotAShortfall()
	try testGroupGapAppliesOnlyBetweenGroups()
	try testMixedSubtreeTakesTheWideGutter()
	try testGapAgreesWithMinimums()
	try testUndersizedCanvasSkipsTheInset()
	try testMoveChangesPlacementNotMembership()
	try testMovingTheLastPanelLeavesTheCanvasBlank()
	try testEachCanvasSolvesInsideItsOwnRectangle()
	try testDerivedRatioFollowsGrowthWeight()
	try testUserRatioBeatsWeights()
	try testUserRatioSurvivesInsertElsewhere()
	try testDerivedAncestorReproportionsOnInsert()
	try testClampedUserRatioIsNotWrittenBack()
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
