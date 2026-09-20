import CoreGraphics
import Foundation
@testable import TeaserKit

// Canvas isolation: what one canvas does must not reach another. Each open
// canvas is one orchestrator display, so "two canvases" here is two
// `DesktopStageDisplay`s keyed by `DisplayID(canvas:)` — the same identity the
// canvas window carries — and the assertions are about leases, assignments,
// solved frames, drop targets, Workspace placement and focus staying on the
// canvas they belong to.
//
// Nothing here creates a window, installs a global event monitor or asks for
// Accessibility: the substituted window world, pointer source, clock and host
// are the adoption fixtures this target links as `AdoptionFixtures.swift`, and
// the orchestrator runs exactly as the App runs it.

// MARK: - Two canvases, side by side

private let canvasAID: CanvasID = .init("isolation-a")
private let canvasBID: CanvasID = .init("isolation-b")
private let displayA: DisplayID = .init(canvas: canvasAID)
private let displayB: DisplayID = .init(canvas: canvasBID)

/// The canvases are separated by a wide gap on purpose. A drop falls back to
/// the Panel under the dragged window's centre when the pointer is over none,
/// and a dragged window hangs below the pointer, so overlapping canvases would
/// let a pointer over canvas A resolve a Panel on canvas B by that fallback and
/// hide the very filtering these cases are about.
private let canvasAFrame: CGRect = .init(x: 0, y: 0, width: 1_200, height: 900)
private let canvasBFrame: CGRect = .init(
	x: 1_600,
	y: 0,
	width: 1_200,
	height: 900
)

private let canvasADisplay: DesktopStageDisplay = .init(
	id: displayA,
	frame: layoutRect(canvasAFrame)
)
private let canvasBDisplay: DesktopStageDisplay = .init(
	id: displayB,
	frame: layoutRect(canvasBFrame)
)

// Canvas A deliberately holds two Workspaces: a canvas groups Workspaces and is
// never one of them, so per-canvas release has to reach every Workspace placed
// on it rather than the first one it finds.
private let alphaWorkspaceID: WorkspaceID = .init("canvas-a-alpha")
private let gammaWorkspaceID: WorkspaceID = .init("canvas-a-gamma")
private let deltaWorkspaceID: WorkspaceID = .init("canvas-b-delta")
private let aLeftPanelID: PanelID = .init("a-left")
private let aRightPanelID: PanelID = .init("a-right")
private let aSoloPanelID: PanelID = .init("a-solo")
private let bLeftPanelID: PanelID = .init("b-left")
private let bRightPanelID: PanelID = .init("b-right")

/// Two canvases, three Workspaces: Alpha and Gamma on canvas A, Delta on
/// canvas B. Every Workspace names its own canvas as its display affinity and
/// every canvas has its own display layout, which is the shape the canvas host
/// produces and the shape non-shared `setDisplays` must accept unchanged.
private func twoCanvasPresentation(
	mode: WorkspacePresentationMode = .tiled
) throws -> WorkspacePresentation {
	let alpha: WorkspaceDescriptor = .init(
		id: alphaWorkspaceID,
		title: "Alpha",
		detail: "Canvas A, first Workspace",
		displayAffinity: displayA,
		panelTree: .split(
			id: .init("alpha-root"),
			axis: .horizontal,
			preference: .init(desiredRatio: 0.5),
			first: .leaf(aLeftPanelID),
			second: .leaf(aRightPanelID)
		),
		panels: [
			aLeftPanelID: fixturePanel(aLeftPanelID, "A Left"),
			aRightPanelID: fixturePanel(aRightPanelID, "A Right"),
		]
	)
	let gamma: WorkspaceDescriptor = .init(
		id: gammaWorkspaceID,
		title: "Gamma",
		detail: "Canvas A, second Workspace",
		displayAffinity: displayA,
		panelTree: .leaf(aSoloPanelID),
		panels: [aSoloPanelID: fixturePanel(aSoloPanelID, "A Solo")]
	)
	let delta: WorkspaceDescriptor = .init(
		id: deltaWorkspaceID,
		title: "Delta",
		detail: "Canvas B",
		displayAffinity: displayB,
		panelTree: .split(
			id: .init("delta-root"),
			axis: .horizontal,
			preference: .init(desiredRatio: 0.5),
			first: .leaf(bLeftPanelID),
			second: .leaf(bRightPanelID)
		),
		panels: [
			bLeftPanelID: fixturePanel(bLeftPanelID, "B Left"),
			bRightPanelID: fixturePanel(bRightPanelID, "B Right"),
		]
	)
	return .init(
		mode: mode,
		virtualFocus: .none,
		displayLayouts: [
			displayA: .init(
				displayID: displayA,
				workspaceTree: .split(
					id: .init("canvas-a-root"),
					axis: .vertical,
					preference: .init(desiredRatio: 0.5),
					first: .leaf(alphaWorkspaceID),
					second: .leaf(gammaWorkspaceID)
				)
			),
			displayB: .init(
				displayID: displayB,
				workspaceTree: .leaf(deltaWorkspaceID)
			),
		],
		workspaces: [
			alphaWorkspaceID: alpha,
			gammaWorkspaceID: gamma,
			deltaWorkspaceID: delta,
		],
		panelKinds: try .init()
	)
}

/// Both Workspaces on canvas A. With one canvas open this is what the shared
/// projection produces; with two canvases open, display-topology rebalancing
/// would split them across the canvases, which shared mode must never do.
private func oneCanvasPresentation() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = try twoCanvasPresentation()
	presentation.workspaces.removeValue(forKey: deltaWorkspaceID)
	presentation.displayLayouts.removeValue(forKey: displayB)
	return presentation
}

/// No canvas is open and nothing is placed: what the app holds before the first
/// canvas window exists, and what it returns to when the last one closes.
private func emptyCanvasPresentation() throws -> WorkspacePresentation {
	.init(
		mode: .tiled,
		virtualFocus: .none,
		displayLayouts: [:],
		workspaces: [:],
		panelKinds: try .init()
	)
}

// MARK: - Two-canvas world

/// The adoption harness pins itself to one fixture display and adapts the
/// presentation to it, which would rebalance a two-canvas presentation onto a
/// single canvas before a case began. This composes the same substituted world
/// — `PointerDriver`, `RecordingStageHost`, `CountingIdentifierSource` — around
/// an orchestrator that starts with the canvases the case opens.
@MainActor
private final class CanvasWorld {
	let driver: PointerDriver = .init()
	/// `DesktopStageOrchestrator.host` is weak, so the world owns the host.
	let host: RecordingStageHost
	let orchestrator: DesktopStageOrchestrator

	var log: FakeOperationLog { driver.log }
	var service: FakeExternalWindowService { driver.service }

	init(
		presentation: WorkspacePresentation,
		displays: [DesktopStageDisplay] = [canvasADisplay, canvasBDisplay]
	) {
		host = .init(log: driver.log)
		orchestrator = .init(
			presentation: presentation,
			notes: [:],
			service: driver.service,
			clock: driver.clock,
			pointerSource: driver.pointer,
			identifiers: CountingIdentifierSource()
		)
		orchestrator.host = host
		orchestrator.setDisplays(displays)
	}

	func panelFrame(_ panelID: PanelID) throws -> CGRect {
		nsRect(
			try unwrap(
				orchestrator.layout?.panelFrames[panelID],
				"missing solved Panel \(panelID.rawValue)"
			)
		)
	}

	func center(of panelID: PanelID) throws -> CGPoint {
		let frame: CGRect = try panelFrame(panelID)
		return .init(x: frame.midX, y: frame.midY)
	}

	/// What the window world reports for an identity, rather than what Teaser
	/// believes about it.
	func readBackFrame(_ identity: ExternalWindowIdentity) throws -> CGRect {
		try service.window(identity).appKitScreenFrame
	}
}

/// Every operation that ends a lease or puts a window back where its provider
/// had it. A canvas that closes must produce none of these for a window another
/// canvas is still tiling.
@MainActor
private func leaseEndingOperations(
	_ log: FakeOperationLog,
	for identity: ExternalWindowIdentity
) -> [FakeWindowOperation] {
	log.operations.filter { operation in
		switch operation {
		case .release(let value, _), .releaseRefused(let value),
			.restoreOriginal(let value, _):
			return value == identity
		default:
			return false
		}
	}
}

// MARK: - Cases

@MainActor
private func testClosingACanvasReleasesOnlyItsOwnWindows() throws {
	let world: CanvasWorld = .init(presentation: try twoCanvasPresentation())
	try world.orchestrator.startStage()
	let windowA: FakeWindow = world.driver.addWindow()
	let windowB: FakeWindow = world.driver.addSecondWindow()
	let originalA: CGRect = windowA.appKitScreenFrame

	// The canvas-A window goes into Gamma, the second Workspace on that canvas,
	// so the release has to resolve Panels through Workspace membership rather
	// than stopping at the canvas's first Workspace.
	try expect(
		world.orchestrator.adoptWindow(
			identity: windowA.identity,
			into: aSoloPanelID
		),
		"the canvas-A window must adopt into its Panel"
	)
	try expect(
		world.orchestrator.adoptWindow(
			identity: windowB.identity,
			into: bLeftPanelID
		),
		"the canvas-B window must adopt into its Panel"
	)
	let canvasBPanelFrame: CGRect = try world.panelFrame(bLeftPanelID)
	let solvedFrames: [PanelID: LayoutRect] = try unwrap(
		world.orchestrator.layout?.panelFrames,
		"two open canvases must solve a layout"
	)

	try expect(
		world.orchestrator.releaseWindows(onDisplay: displayA),
		"every canvas-A window cooperated, so its close reports success"
	)

	try expect(
		world.orchestrator.panelAssignments == [bLeftPanelID: windowB.identity],
		"closing canvas A must leave only canvas B's assignment: "
			+ "\(world.orchestrator.panelAssignments)"
	)
	try expect(
		world.log.contains(.restoreOriginal(windowA.identity, originalA))
			&& world.log.contains(
				.release(windowA.identity, restoringOriginalFrame: true)
			),
		"the closing canvas must give its window back at its original frame"
	)
	try expect(
		try world.readBackFrame(windowA.identity) == originalA,
		"the released window must read back where its provider had it"
	)
	try expect(
		leaseEndingOperations(world.log, for: windowB.identity).isEmpty,
		"canvas B's lease must survive its neighbour closing: "
			+ "\(leaseEndingOperations(world.log, for: windowB.identity))"
	)
	try expect(
		try world.readBackFrame(windowB.identity) == canvasBPanelFrame,
		"canvas B's window must still sit in its own Panel"
	)
	try expect(
		world.orchestrator.layout?.panelFrames == solvedFrames,
		"closing a canvas must not re-solve the canvases that stayed open"
	)
	// Organization is server-owned: a closing canvas hides its Workspaces, it
	// never hands them to a canvas that is still open.
	try expect(
		world.orchestrator.presentation.workspaces[alphaWorkspaceID]?
			.displayAffinity == displayA
			&& world.orchestrator.presentation.workspaces[gammaWorkspaceID]?
				.displayAffinity == displayA,
		"a closed canvas keeps its Workspaces; they are never redistributed"
	)
}

@MainActor
private func testARefusedReleaseRetriesOnlyItsOwnCanvas() throws {
	let world: CanvasWorld = .init(presentation: try twoCanvasPresentation())
	try world.orchestrator.startStage()
	let windowA: FakeWindow = world.driver.addWindow()
	let windowB: FakeWindow = world.driver.addSecondWindow()
	let originalA: CGRect = windowA.appKitScreenFrame
	try expect(
		world.orchestrator.adoptWindow(identity: windowA.identity, into: aLeftPanelID)
			&& world.orchestrator.adoptWindow(
				identity: windowB.identity,
				into: bLeftPanelID
			),
		"both canvases must hold one adopted window"
	)
	let canvasBPanelFrame: CGRect = try world.panelFrame(bLeftPanelID)
	windowA.refusesRelease = true

	try expect(
		!world.orchestrator.releaseWindows(onDisplay: displayA),
		"a refused restoration must be reported, not swallowed"
	)
	try expect(
		world.log.contains(.releaseRefused(windowA.identity)),
		"the refusal must reach the window world"
	)
	try expect(
		world.orchestrator.panelAssignments == [bLeftPanelID: windowB.identity],
		"a refused release still closes the canvas: its Panels are unassigned"
	)
	try expect(
		world.orchestrator.statusMessage
			== "Canvas closed; 1 window(s) could not be restored",
		"the person is told which canvas close left a window behind: "
			+ "\(world.orchestrator.statusMessage ?? "none")"
	)

	try expect(
		!world.orchestrator.releaseRetainedLeases(),
		"a still-refusing window keeps the retry unfinished"
	)
	try expect(
		leaseEndingOperations(world.log, for: windowB.identity).isEmpty,
		"a retry must never reach a window a still-open canvas is tiling: "
			+ "\(leaseEndingOperations(world.log, for: windowB.identity))"
	)
	try expect(
		try world.readBackFrame(windowB.identity) == canvasBPanelFrame,
		"canvas B's window must stay in its Panel across the retry"
	)

	windowA.refusesRelease = false
	try expect(
		world.orchestrator.releaseRetainedLeases(),
		"the retry must succeed once the window cooperates"
	)
	try expect(
		try world.log.contains(.restoreOriginal(windowA.identity, originalA))
			&& world.readBackFrame(windowA.identity) == originalA,
		"the retried window must land back at its original frame"
	)
	try expect(
		leaseEndingOperations(world.log, for: windowB.identity).isEmpty,
		"the successful retry must still leave canvas B's lease alone"
	)
	try expect(
		world.orchestrator.panelAssignments == [bLeftPanelID: windowB.identity],
		"canvas B keeps its assignment through both retries"
	)
}

@MainActor
private func testDropsResolveTheCanvasBeforeItsPanels() throws {
	let world: CanvasWorld = .init(presentation: try twoCanvasPresentation())
	try world.orchestrator.startStage()
	let window: FakeWindow = world.driver.addWindow()
	let canvasAPoint: CGPoint = try world.center(of: aLeftPanelID)
	let canvasBPoint: CGPoint = try world.center(of: bLeftPanelID)

	// Without the hook the pointer alone decides, which is the baseline the two
	// filtered cases below are measured against: this point really is over a
	// Panel, so a later miss is the canvas filter and not the geometry.
	world.driver.beginDrag(window, to: canvasAPoint)
	try expect(
		world.orchestrator.dropHighlight?.panelID == aLeftPanelID,
		"a drag over a Panel must find it when no canvas owns the point"
	)

	// No canvas under the pointer: the window is over the desktop or another
	// application, and there is nothing to adopt it.
	world.orchestrator.canvasDisplayAtScreenPoint = { (_: CGPoint) -> DisplayID? in
		nil
	}
	world.driver.dragWindow(
		window,
		to: .init(x: canvasAPoint.x + 24, y: canvasAPoint.y)
	)
	try expect(
		world.orchestrator.dropHighlight == nil && world.orchestrator.isDragging,
		"with no canvas under the pointer there is no drop target at all"
	)

	// Canvas B owns the point — an overlapping or off-Space canvas A must not
	// answer for it, even though its Panel geometry still contains the pointer.
	world.orchestrator.canvasDisplayAtScreenPoint = { (_: CGPoint) -> DisplayID? in
		displayB
	}
	world.driver.dragWindow(window, to: canvasAPoint)
	try expect(
		world.orchestrator.dropHighlight == nil && world.orchestrator.isDragging,
		"a Panel on another canvas must not answer for the canvas under the pointer"
	)

	world.driver.dragWindow(window, to: canvasBPoint)
	try expect(
		world.orchestrator.dropHighlight?.panelID == bLeftPanelID,
		"inside the owning canvas's own Panel the drop target is that Panel"
	)
	world.driver.releasePointer(at: canvasBPoint)
	try expect(
		world.orchestrator.panelAssignments == [bLeftPanelID: window.identity],
		"the drop must land in the Panel the owning canvas offered"
	)
}

@MainActor
private func testSharedModeNeverRebalancesAcrossCanvases() throws {
	// One canvas open, both Workspaces on it. Opening a second canvas is exactly
	// the topology change display rebalancing would act on: it would move one
	// Workspace to the new canvas and rewrite both display layouts.
	let world: CanvasWorld = .init(
		presentation: try oneCanvasPresentation(),
		displays: [canvasADisplay]
	)
	world.orchestrator.useSharedOrganization()
	let before: WorkspacePresentation = world.orchestrator.presentation

	func expectUnchanged(_ message: String) throws {
		let now: WorkspacePresentation = world.orchestrator.presentation
		try expect(
			now.workspaces == before.workspaces,
			"\(message): a Workspace's canvas or panel tree changed"
		)
		try expect(
			now.displayLayouts == before.displayLayouts,
			"\(message): a canvas's Workspace tree changed"
		)
	}

	world.orchestrator.setDisplays([canvasADisplay, canvasBDisplay])
	try expectUnchanged("opening a second canvas")
	world.orchestrator.screenParametersDidChange(
		displays: [canvasADisplay, canvasBDisplay]
	)
	try expectUnchanged("a screen change with two canvases open")
	world.orchestrator.screenParametersDidChange(displays: [canvasADisplay])
	try expectUnchanged("closing the second canvas")
	world.orchestrator.setDisplays([canvasADisplay])
	try expectUnchanged("settling back to one canvas")

	try expect(
		world.orchestrator.presentation.workspaces.values.allSatisfy {
			$0.displayAffinity == displayA
		},
		"placement is the projection's, so no Workspace may follow a new display"
	)
	try expect(
		Set(world.orchestrator.presentation.displayLayouts.keys) == [displayA],
		"a canvas with no Workspaces must not be given one"
	)
}

@MainActor
private func testFocusFallsBackOnlyOnTheClosingCanvas() throws {
	let closing: CanvasWorld = .init(
		presentation: try twoCanvasPresentation(mode: .focused(alphaWorkspaceID))
	)
	closing.orchestrator.releaseWindows(onDisplay: displayA)
	try expect(
		closing.orchestrator.presentation.mode == .tiled,
		"a focused Workspace whose canvas closes has nowhere to fill, so it tiles"
	)

	let surviving: CanvasWorld = .init(
		presentation: try twoCanvasPresentation(mode: .focused(deltaWorkspaceID))
	)
	let before: WorkspaceDescriptor = try unwrap(
		surviving.orchestrator.presentation.workspaces[deltaWorkspaceID],
		"the fixture must place a Workspace on canvas B"
	)
	surviving.orchestrator.releaseWindows(onDisplay: displayA)
	try expect(
		surviving.orchestrator.presentation.mode == .focused(deltaWorkspaceID),
		"focus fills one canvas, so closing another must not end it"
	)
	try expect(
		surviving.orchestrator.presentation.workspaces[deltaWorkspaceID] == before,
		"the surviving canvas's Workspace must be untouched by the close"
	)
}

@MainActor
private func testClosingTheLastCanvasSolvesAnEmptyLayout() throws {
	// Closing the last canvas keeps the app running with nothing placed. Only a
	// presentation that still places Workspaces needs a canvas to place them on,
	// so an empty one must solve rather than report a missing display.
	let harness: Harness = .init(presentation: try emptyCanvasPresentation())
	harness.orchestrator.setDisplays([])

	try harness.orchestrator.startStage()

	let layout: PresentationLayout = try unwrap(
		harness.orchestrator.layout,
		"an empty presentation with no canvas must still solve"
	)
	try expect(
		layout.panelFrames.isEmpty && layout.workspaceFrames.isEmpty
			&& layout.dividers.isEmpty,
		"nothing placed must solve to nothing drawn"
	)
	try expect(
		harness.orchestrator.isStageActive
			&& harness.orchestrator.statusMessage == nil,
		"the stage stays live with no canvas and reports no failure: "
			+ "\(harness.orchestrator.statusMessage ?? "none")"
	)
}

// MARK: - Projection across two canvases

private let projectionProjectID: String = "canvas-project"
private let workspaceAID: String = "ws-a"
private let workspaceBID: String = "ws-b"

/// A server organization with one Project. The server model carries no canvas:
/// where these Workspaces are shown is the client's placement alone.
private func organizationSnapshot(
	revision: UInt64,
	workspaces: [(id: String, panels: [String])]
) -> OrganizationSnapshot {
	let organizationWorkspaces: [OrganizationWorkspace] = workspaces.map { entry in
		OrganizationWorkspace(
			id: entry.id,
			project_id: projectionProjectID,
			name: "Workspace \(entry.id)",
			task: nil
		)
	}
	let organizationPanels: [OrganizationPanel] = workspaces.flatMap { entry in
		entry.panels.map { panelID in
			OrganizationPanel(
				id: panelID,
				workspace_id: entry.id,
				title: "Panel \(panelID)",
				kind: "generic",
				binding: .unbound,
				size_profile: .standard
			)
		}
	}
	return .init(
		revision: revision,
		projects: [.init(id: projectionProjectID, name: "Canvas Project")],
		workspaces: organizationWorkspaces,
		panels: organizationPanels
	)
}

@MainActor
private func testProjectionKeepsEachCanvasItsOwnWorkspaces() throws {
	// An empty presentation is what the app holds before a connection places
	// anything, so nothing the harness set up can be mistaken for a projection.
	let harness: Harness = .init(presentation: try emptyCanvasPresentation())
	let session: OrganizationSession = .init(
		orchestrator: harness.orchestrator,
		client: .init(),
		archiveDirectory: nil
	)
	// Shared mode is on from the session's initializer, so the canvases the host
	// opens reach the orchestrator without display rebalancing.
	harness.orchestrator.setDisplays([canvasADisplay, canvasBDisplay])
	// The session subscribes to its client's snapshots. Delivering one here is
	// the server telling the client what the organization is, without opening a
	// socket, which `connect` would do.
	let deliver: (OrganizationSnapshot) throws -> Void = try unwrap(
		session.client.onSnapshot,
		"the session must subscribe to its client's snapshots"
	)

	session.setTargetDisplay(displayA)
	try deliver(
		organizationSnapshot(
			revision: 1,
			workspaces: [(id: workspaceAID, panels: ["pa-1", "pa-2"])]
		)
	)
	let workspaceA: WorkspaceID = .init(workspaceAID)
	let workspaceB: WorkspaceID = .init(workspaceBID)
	let treeA: LayoutTree<PanelID> = try unwrap(
		harness.orchestrator.presentation.workspaces[workspaceA]?.panelTree,
		"the first Workspace must be placed on the target canvas"
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceA]?
			.displayAffinity == displayA,
		"a Workspace with no placement yet lands on the canvas the person used"
	)

	// A second Workspace arrives while canvas B is the target: it lands there,
	// and the first one keeps the canvas it already has.
	session.setTargetDisplay(displayB)
	try deliver(
		organizationSnapshot(
			revision: 2,
			workspaces: [
				(id: workspaceAID, panels: ["pa-1", "pa-2"]),
				(id: workspaceBID, panels: ["pb-1", "pb-2"]),
			]
		)
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceA]?
			.displayAffinity == displayA
			&& harness.orchestrator.presentation.workspaces[workspaceA]?
				.panelTree == treeA,
		"a placed Workspace keeps its canvas and its tree across snapshots"
	)
	let treeB: LayoutTree<PanelID> = try unwrap(
		harness.orchestrator.presentation.workspaces[workspaceB]?.panelTree,
		"a new Workspace must land on the target canvas"
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceB]?
			.displayAffinity == displayB,
		"the target canvas receives the Workspace that had no placement"
	)

	// Canvas B closes. The host takes its display away and re-projects; the
	// server is not asked again, because placement is the client's.
	harness.orchestrator.setDisplays([canvasADisplay])
	try session.canvasesDidChange()
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceB] == nil,
		"a Workspace on a closed canvas is left out rather than moved"
	)
	try expect(
		session.workspacePlacement[workspaceB] == displayB,
		"its placement entry survives the close, which is what Reopen restores"
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceA]?
			.displayAffinity == displayA
			&& harness.orchestrator.presentation.workspaces[workspaceA]?
				.panelTree == treeA,
		"closing one canvas must not disturb the other canvas's Workspace"
	)
	try expect(
		Set(harness.orchestrator.presentation.displayLayouts.keys) == [displayA],
		"a closed canvas is no longer a display the solver places anything on"
	)

	// Reopen Closed Canvas: the same canvas ID comes back and its Workspace
	// returns arranged the way it was, from the layouts the session parked.
	harness.orchestrator.setDisplays([canvasADisplay, canvasBDisplay])
	try session.canvasesDidChange()
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceB]?
			.displayAffinity == displayB,
		"reopening a canvas brings back exactly the Workspaces it held"
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceB]?
			.panelTree == treeB,
		"the reopened canvas's Workspace keeps the tree it was arranged with"
	)
	try expect(
		harness.orchestrator.presentation.workspaces[workspaceA]?
			.panelTree == treeA,
		"reopening a canvas must not rearrange the canvas that stayed open"
	)
}

@MainActor
func canvasIsolationCases() -> [TestCase] {
	[
		.init(
			"closing a canvas releases only its own windows",
			testClosingACanvasReleasesOnlyItsOwnWindows
		),
		.init(
			"a refused release retries only its own canvas",
			testARefusedReleaseRetriesOnlyItsOwnCanvas
		),
		.init(
			"drops resolve the owning canvas before its Panels",
			testDropsResolveTheCanvasBeforeItsPanels
		),
		.init(
			"shared mode never rebalances Workspaces across canvases",
			testSharedModeNeverRebalancesAcrossCanvases
		),
		.init(
			"focus falls back only on the canvas that closes",
			testFocusFallsBackOnlyOnTheClosingCanvas
		),
		.init(
			"closing the last canvas solves an empty layout",
			testClosingTheLastCanvasSolvesAnEmptyLayout
		),
		.init(
			"projection keeps each canvas its own Workspaces",
			testProjectionKeepsEachCanvasItsOwnWorkspaces
		),
	]
}
