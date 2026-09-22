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

/// Two canvases, three groups: Alpha and Gamma interleaved in canvas A's one
/// tree, Delta in canvas B's. A canvas holds Panels, not Workspaces, so canvas
/// A proves per-canvas release reaches every group placed on it — and that two
/// groups can share one tree without either owning a rectangle.
private func twoCanvasPresentation(
	focus: CanvasFocus? = nil
) throws -> WorkspacePresentation {
	.init(
		virtualFocus: .none,
		canvases: [
			displayA: .init(
				displayID: displayA,
				panelTree: .split(
					id: .init("canvas-a-root"),
					axis: .vertical,
					preference: .user(0.5),
					first: .split(
						id: .init("alpha-root"),
						axis: .horizontal,
						preference: .user(0.5),
						first: .leaf(aLeftPanelID),
						second: .leaf(aRightPanelID)
					),
					second: .leaf(aSoloPanelID)
				),
				focus: focus
			),
			displayB: .init(
				displayID: displayB,
				panelTree: .split(
					id: .init("delta-root"),
					axis: .horizontal,
					preference: .user(0.5),
					first: .leaf(bLeftPanelID),
					second: .leaf(bRightPanelID)
				)
			),
		],
		workspaces: [
			alphaWorkspaceID: .init(
				id: alphaWorkspaceID,
				title: "Alpha",
				detail: "Canvas A, first group"
			),
			gammaWorkspaceID: .init(
				id: gammaWorkspaceID,
				title: "Gamma",
				detail: "Canvas A, second group"
			),
			deltaWorkspaceID: .init(
				id: deltaWorkspaceID,
				title: "Delta",
				detail: "Canvas B"
			),
		],
		panels: [
			aLeftPanelID: fixturePanel(aLeftPanelID, "A Left", alphaWorkspaceID),
			aRightPanelID: fixturePanel(aRightPanelID, "A Right", alphaWorkspaceID),
			aSoloPanelID: fixturePanel(aSoloPanelID, "A Solo", gammaWorkspaceID),
			bLeftPanelID: fixturePanel(bLeftPanelID, "B Left", deltaWorkspaceID),
			bRightPanelID: fixturePanel(bRightPanelID, "B Right", deltaWorkspaceID),
		],
		panelKinds: try .init()
	)
}

/// Only canvas A. With one canvas open this is what the shared projection
/// produces, and closing canvas B must never redistribute its Panels here.
private func oneCanvasPresentation() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = try twoCanvasPresentation()
	presentation.canvases.removeValue(forKey: displayB)
	presentation.panels.removeValue(forKey: bLeftPanelID)
	presentation.panels.removeValue(forKey: bRightPanelID)
	presentation.workspaces.removeValue(forKey: deltaWorkspaceID)
	return presentation
}

/// No canvas is open and nothing is placed: what the app holds before the first
/// canvas window exists, and what it returns to when the last one closes.
private func emptyCanvasPresentation() throws -> WorkspacePresentation {
	.init(panelKinds: try .init())
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
		world.orchestrator.presentation.canvasID(containing: aLeftPanelID) == displayA
			&& world.orchestrator.presentation.canvasID(containing: aSoloPanelID) == displayA,
		"a closed canvas keeps its Panels; they are never redistributed"
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
			now.workspaces == before.workspaces && now.panels == before.panels,
			"\(message): group membership or a Panel descriptor changed"
		)
		try expect(
			now.canvases == before.canvases,
			"\(message): a canvas's Panel tree changed"
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
		world.orchestrator.presentation.panels.keys.allSatisfy {
			world.orchestrator.presentation.canvasID(containing: $0) == displayA
		},
		"placement is the projection's, so no Panel may follow a new display"
	)
	try expect(
		Set(world.orchestrator.presentation.canvases.keys) == [displayA],
		"a canvas with no Panels must not be given one"
	)
}

@MainActor
private func testFocusFallsBackOnlyOnTheClosingCanvas() throws {
	let closing: CanvasWorld = .init(
		presentation: try twoCanvasPresentation(focus: .emphasised(alphaWorkspaceID))
	)
	closing.orchestrator.releaseWindows(onDisplay: displayA)
	try expect(
		closing.orchestrator.presentation.canvases[displayA]?.focus == nil,
		"a closed canvas stops emphasising anything"
	)

	// Focus belongs to one canvas, so closing a different one cannot end it.
	var focused: WorkspacePresentation = try twoCanvasPresentation()
	focused.focusWorkspace(deltaWorkspaceID, onCanvas: displayB)
	let surviving: CanvasWorld = .init(presentation: focused)
	let before: CanvasLayout = try unwrap(
		surviving.orchestrator.presentation.canvases[displayB],
		"the fixture must place Panels on canvas B"
	)
	surviving.orchestrator.releaseWindows(onDisplay: displayA)
	try expect(
		surviving.orchestrator.presentation.canvases[displayB]?.focus
			== .emphasised(deltaWorkspaceID),
		"focus is per canvas, so closing another must not end it"
	)
	try expect(
		surviving.orchestrator.presentation.canvases[displayB] == before,
		"the surviving canvas must be untouched by the close"
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
		layout.panelFrames.isEmpty && layout.dividers.isEmpty,
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
	let workspaceB: WorkspaceID = .init(workspaceBID)
	let panelsA: [PanelID] = ["pa-1", "pa-2"].map { PanelID($0) }
	let panelsB: [PanelID] = ["pb-1", "pb-2"].map { PanelID($0) }
	let treeA: LayoutTree<PanelID> = try unwrap(
		harness.orchestrator.presentation.canvases[displayA]?.panelTree,
		"the first group's Panels must be seated on the target canvas"
	)
	try expect(
		panelsA.allSatisfy {
			harness.orchestrator.presentation.canvasID(containing: $0) == displayA
		},
		"a Panel with no seat yet lands on the canvas the person used"
	)

	// A second group arrives while canvas B is the target: its Panels land
	// there, and the first group's keep the canvas they already have.
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
		harness.orchestrator.presentation.canvases[displayA]?.panelTree == treeA,
		"a seated Panel keeps its canvas and its tree across snapshots"
	)
	let treeB: LayoutTree<PanelID> = try unwrap(
		harness.orchestrator.presentation.canvases[displayB]?.panelTree,
		"a new group's Panels must land on the target canvas"
	)
	try expect(
		panelsB.allSatisfy {
			harness.orchestrator.presentation.canvasID(containing: $0) == displayB
		},
		"the target canvas receives the Panels that had no seat"
	)
	// Membership is the server's and never follows placement.
	try expect(
		panelsB.allSatisfy {
			harness.orchestrator.presentation.workspaceID(of: $0) == workspaceB
		},
		"seating a Panel on a canvas must not change its group"
	)

	// Canvas B closes. The host takes its display away and re-projects; the
	// server is not asked again, because placement is the client's.
	harness.orchestrator.setDisplays([canvasADisplay])
	try session.canvasesDidChange()
	try expect(
		harness.orchestrator.presentation.canvases[displayB] == nil,
		"a closed canvas stops being a canvas the solver places anything on"
	)
	try expect(
		panelsB.allSatisfy {
			harness.orchestrator.presentation.canvasID(containing: $0) == nil
		},
		"a Panel on a closed canvas is left unplaced rather than moved"
	)
	try expect(
		panelsB.allSatisfy { harness.orchestrator.presentation.panels[$0] != nil },
		"its descriptor survives the close, which is what Reopen restores"
	)
	try expect(
		harness.orchestrator.presentation.canvases[displayA]?.panelTree == treeA,
		"closing one canvas must not disturb the other canvas's tree"
	)
	try expect(
		Set(harness.orchestrator.presentation.canvases.keys) == [displayA],
		"a closed canvas is no longer a display the solver places anything on"
	)

	// Reopen Closed Canvas: the same canvas ID comes back and its Panels return
	// arranged the way they were, from the layout the session parked.
	harness.orchestrator.setDisplays([canvasADisplay, canvasBDisplay])
	try session.canvasesDidChange()
	try expect(
		harness.orchestrator.presentation.canvases[displayB]?.panelTree == treeB,
		"the reopened canvas keeps the tree it was arranged with"
	)
	try expect(
		panelsB.allSatisfy {
			harness.orchestrator.presentation.canvasID(containing: $0) == displayB
		},
		"reopening a canvas brings back exactly the Panels it held"
	)
	try expect(
		harness.orchestrator.presentation.canvases[displayA]?.panelTree == treeA,
		"reopening a canvas must not rearrange the canvas that stayed open"
	)
}

/// Without a server there is nothing to project, but a canvas still has to be
/// usable: it opens with one empty Panel to drag a window into and to split.
@MainActor
private func testAnUnconnectedCanvasOpensWithOneEmptyPanel() throws {
	let harness: Harness = .init(presentation: try emptyCanvasPresentation())
	harness.orchestrator.setDisplays([canvasADisplay])
	try expect(
		harness.orchestrator.presentation.canvases.isEmpty,
		"merely knowing about a display must not invent a Panel"
	)
	harness.orchestrator.seedCanvasIfUnconnected(displayA)
	let seeded: [PanelID] = harness.orchestrator.presentation.panelIDs(onCanvas: displayA)
	try expect(seeded.count == 1, "an unconnected canvas opens with exactly one Panel")
	let panelID: PanelID = try unwrap(seeded.first, "the seeded Panel")
	try expect(
		harness.orchestrator.presentation.workspaceID(of: panelID) != nil,
		"the seeded Panel must belong to a group so it can be outlined"
	)
	try expect(
		harness.orchestrator.presentation.virtualFocus.panelID == panelID,
		"the seeded Panel takes Virtual Focus so a split has a target"
	)

	// Opening a second canvas seeds that one too, and leaves the first alone.
	let before: CanvasLayout = try unwrap(
		harness.orchestrator.presentation.canvases[displayA],
		"canvas A"
	)
	harness.orchestrator.setDisplays([canvasADisplay, canvasBDisplay])
	harness.orchestrator.seedCanvasIfUnconnected(displayB)
	try expect(
		harness.orchestrator.presentation.panelIDs(onCanvas: displayB).count == 1,
		"a second canvas opens with its own Panel"
	)
	try expect(
		harness.orchestrator.presentation.canvases[displayA] == before,
		"seeding a new canvas must not disturb one that already exists"
	)
	try expect(
		harness.orchestrator.presentation.workspaceID(of: panelID)
			!= harness.orchestrator.presentation.workspaceID(
				of: try unwrap(
					harness.orchestrator.presentation.panelIDs(onCanvas: displayB).first,
					"canvas B's Panel"
				)
			),
		"each canvas starts its own group"
	)
}

/// In shared mode the projection owns every canvas. Seeding a Panel here would
/// make the client a second writer of membership.
@MainActor
private func testSharedModeNeverSeedsAPanel() throws {
	let harness: Harness = .init(presentation: try emptyCanvasPresentation())
	harness.orchestrator.useSharedOrganization()
	harness.orchestrator.setDisplays([canvasADisplay])
	harness.orchestrator.seedCanvasIfUnconnected(displayA)
	try expect(
		harness.orchestrator.presentation.panels.isEmpty
			&& harness.orchestrator.presentation.canvases.isEmpty,
		"shared mode must accept its canvases from the projection alone"
	)
}

@MainActor
func canvasIsolationCases() -> [TestCase] {
	[
		.init(
			"an unconnected canvas opens with one empty Panel",
			testAnUnconnectedCanvasOpensWithOneEmptyPanel
		),
		.init(
			"shared mode never seeds a Panel",
			testSharedModeNeverSeedsAPanel
		),
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
