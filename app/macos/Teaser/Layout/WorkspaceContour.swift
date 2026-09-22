import Foundation

/// What the contour pass needs about one Panel. Deliberately not
/// `DesktopOverlayPanel`: `Layout/` must not depend on the presentation layer.
struct ContourInput: Equatable, Sendable {
	let panelID: PanelID
	let workspaceID: WorkspaceID
	let displayID: DisplayID
	let frame: LayoutRect
}

/// A closed rectilinear loop. Consecutive vertices differ in exactly one
/// coordinate, the last closes back to the first, and no vertex is collinear
/// with its neighbours, so one boundary has exactly one spelling and two runs
/// over the same input compare equal.
struct ContourLoop: Codable, Equatable, Hashable, Sendable {
	/// Counter-clockwise around solid area, clockwise around a hole, in the
	/// solver's y-up coordinates. It starts at the loop's smallest vertex by
	/// (x, then y) — always a convex corner — so where tracing began never
	/// reaches the output.
	let vertices: [LayoutPoint]

	/// Twice the shoelace sum: positive for an outer boundary, negative for a
	/// hole. Doubled, because only the sign is ever read.
	var doubledSignedArea: Double {
		guard vertices.count >= 3 else { return 0 }
		var total: Double = 0
		var previous: LayoutPoint = vertices[vertices.count - 1]
		for vertex: LayoutPoint in vertices {
			total += previous.x * vertex.y - vertex.x * previous.y
			previous = vertex
		}
		return total
	}

	var isHole: Bool { doubledSignedArea < 0 }
}

/// One locally connected run of one Workspace on one canvas.
struct WorkspaceContourFragment: Codable, Equatable, Hashable, Sendable {
	let displayID: DisplayID
	let outer: ContourLoop
	/// Other-group Panels this fragment rings. Stroked in the same colour: the
	/// inner edge of a ring is as much the group's boundary as its outer edge,
	/// and leaving it bare reads as if the enclosed Panel were a member.
	let holes: [ContourLoop]
	let panelIDs: [PanelID]
	/// 1-based, group-wide across every canvas, so a split group reads
	/// "Alpha 1/2" here and "Alpha 2/2" there.
	let ordinal: Int
}

struct WorkspaceContour: Codable, Equatable, Hashable, Sendable {
	let workspaceID: WorkspaceID
	let fragments: [WorkspaceContourFragment]
}

/// sRGB components, so the palette and its distance from the focus blue are
/// asserted in a harness that never touches AppKit.
struct WorkspaceContourColor: Codable, Equatable, Hashable, Sendable {
	let red: Double
	let green: Double
	let blue: Double
}

/// Turns solved Panel rectangles into the outer boundary of each locally
/// adjacent run of one Workspace.
///
/// The pass is a grid, not per-rectangle edge cancellation. Every rectangle on
/// a canvas contributes its coordinates to one shared pair of snapped axes, so
/// a tall Panel facing two shorter ones already has its edge split at their
/// shared coordinate. Partial overlap, full overlap, a T-junction, and a Panel
/// faced by five unequal neighbours are then the same code: a grid edge is a
/// boundary exactly when one of the two cells it separates belongs to this
/// fragment and the other does not.
enum WorkspaceContourGeometry {
	/// The solver copies a split's non-cut axis bit-exactly at any depth, and on
	/// the cut axis a shared edge reached by two accumulation paths drifts under
	/// 1e-9 pt for any coordinate a display can carry. The smallest separation
	/// the output can legitimately contain is 0 — same-group neighbours across a
	/// `panelGap` gutter, which inflate to touching — or `groupGap - panelGap`.
	/// Nothing real lands between those, and this is the tolerance
	/// `TeaserLayoutTests` already compares frames with.
	static let epsilon: Double = 0.000_001

	/// Pure, total, non-throwing. Degenerate rects are dropped, never reported:
	/// the solver has already rejected a non-finite canvas frame, and a contour
	/// must not be able to fail a solve.
	///
	/// `inflation` is half the gutter that counts as adjacency. Same-group
	/// Panels merge exactly when their inflated rectangles touch, so a pair
	/// facing each other across the wider between-group gutter stays two
	/// fragments — a single loop there would have to swallow the gutter that
	/// marks the group boundary.
	static func contours(
		_ inputs: [ContourInput],
		canvasOrder: [DisplayID],
		inflation: Double
	) -> [WorkspaceContour] {
		// A display absent from `canvasOrder` cannot come from the solver, which
		// only ever frames canvases it solved. Appending them keeps the pass
		// total instead of dropping Panels where no test would see it.
		var displays: [DisplayID] = canvasOrder
		let ordered: Set<DisplayID> = .init(canvasOrder)
		displays.append(
			contentsOf: Set(inputs.map(\.displayID))
				.subtracting(ordered)
				.sorted { $0.rawValue < $1.rawValue }
		)

		var fragmentsByWorkspace: [WorkspaceID: [WorkspaceContourFragment]] = [:]
		for displayID: DisplayID in displays {
			let onCanvas: [ContourInput] = inputs.filter { $0.displayID == displayID }
			for (workspaceID, fragments): (WorkspaceID, [WorkspaceContourFragment])
				in canvasFragments(onCanvas, displayID: displayID, inflation: inflation)
			{
				fragmentsByWorkspace[workspaceID, default: []].append(
					contentsOf: fragments
				)
			}
		}

		// Ordinals run across every canvas in canvas order, so one group split
		// over two canvases reads 1 of 2 here and 2 of 2 there.
		return fragmentsByWorkspace.keys
			.sorted { $0.rawValue < $1.rawValue }
			.map { workspaceID in
				let fragments: [WorkspaceContourFragment] =
					(fragmentsByWorkspace[workspaceID] ?? [])
					.enumerated()
					.map { offset, fragment in
						.init(
							displayID: fragment.displayID,
							outer: fragment.outer,
							holes: fragment.holes,
							panelIDs: fragment.panelIDs,
							ordinal: offset + 1
						)
					}
				return .init(workspaceID: workspaceID, fragments: fragments)
			}
	}

	// MARK: - One canvas

	private static func canvasFragments(
		_ inputs: [ContourInput],
		displayID: DisplayID,
		inflation: Double
	) -> [(WorkspaceID, [WorkspaceContourFragment])] {
		// Degenerates are dropped before inflation, so a zero-width Panel cannot
		// grow a `2 * inflation` contour out of nothing.
		let usable: [(input: ContourInput, rect: LayoutRect)] = inputs.compactMap {
			input in
			let frame: LayoutRect = input.frame
			guard frame.origin.x.isFinite, frame.origin.y.isFinite,
				frame.size.width.isFinite, frame.size.height.isFinite,
				frame.size.width > 0, frame.size.height > 0
			else { return nil }
			return (input, frame.insetBy(dx: -inflation, dy: -inflation))
		}
		guard !usable.isEmpty else { return [] }

		// One snapped axis pair for the whole canvas, before grouping: snapping
		// per Workspace would let a hole's vertices and the enclosed group's
		// outer vertices differ in the last bits and never cancel.
		let xAxis: SnappedAxis = .init(
			usable.flatMap { [$0.rect.minX, $0.rect.maxX] }
		)
		let yAxis: SnappedAxis = .init(
			usable.flatMap { [$0.rect.minY, $0.rect.maxY] }
		)
		let columns: Int = xAxis.representatives.count - 1
		let rows: Int = yAxis.representatives.count - 1
		guard columns > 0, rows > 0 else { return [] }

		let grouped: [WorkspaceID: [(input: ContourInput, rect: LayoutRect)]] =
			.init(grouping: usable) { $0.input.workspaceID }
		var inside: [Bool] = .init(repeating: false, count: columns * rows)

		return grouped.keys.sorted { $0.rawValue < $1.rawValue }.compactMap {
			workspaceID in
			guard let members: [(input: ContourInput, rect: LayoutRect)] =
				grouped[workspaceID]
			else { return nil }
			for index: Int in inside.indices { inside[index] = false }
			var cells: [(member: ContourInput, column: Int, row: Int)] = []
			for member: (input: ContourInput, rect: LayoutRect) in members {
				guard let first: Int = xAxis.index(of: member.rect.minX),
					let last: Int = xAxis.index(of: member.rect.maxX),
					let bottom: Int = yAxis.index(of: member.rect.minY),
					let top: Int = yAxis.index(of: member.rect.maxY),
					first < last, bottom < top
				else { continue }
				for column: Int in first ..< last {
					for row: Int in bottom ..< top {
						inside[row * columns + column] = true
					}
				}
				cells.append((member.input, first, bottom))
			}

			let labels: [Int] = components(
				inside: inside,
				columns: columns,
				rows: rows
			)
			let componentCount: Int = (labels.max() ?? -1) + 1
			guard componentCount > 0 else { return nil }

			let fragments: [WorkspaceContourFragment] = (0 ..< componentCount)
				.compactMap { component in
					fragment(
						component: component,
						labels: labels,
						columns: columns,
						rows: rows,
						xAxis: xAxis,
						yAxis: yAxis,
						displayID: displayID,
						panelIDs: cells
							.filter { labels[$0.row * columns + $0.column] == component }
							.map(\.member.panelID)
							.sorted { $0.rawValue < $1.rawValue }
					)
				}
				.sorted(by: fragmentOrder)
			return fragments.isEmpty ? nil : (workspaceID, fragments)
		}
	}

	private static func fragmentOrder(
		_ lhs: WorkspaceContourFragment,
		_ rhs: WorkspaceContourFragment
	) -> Bool {
		guard let left: LayoutPoint = lhs.outer.vertices.first,
			let right: LayoutPoint = rhs.outer.vertices.first
		else { return lhs.outer.vertices.count < rhs.outer.vertices.count }
		if left.x != right.x { return left.x < right.x }
		return left.y < right.y
	}

	/// 4-connected labelling over the marked cells, seeded in row-major order so
	/// component numbers do not depend on dictionary iteration.
	private static func components(
		inside: [Bool],
		columns: Int,
		rows: Int
	) -> [Int] {
		var labels: [Int] = .init(repeating: -1, count: columns * rows)
		var next: Int = 0
		for row: Int in 0 ..< rows {
			for column: Int in 0 ..< columns {
				let seed: Int = row * columns + column
				guard inside[seed], labels[seed] == -1 else { continue }
				var stack: [Int] = [seed]
				labels[seed] = next
				while let cell: Int = stack.popLast() {
					let cellColumn: Int = cell % columns
					let cellRow: Int = cell / columns
					let neighbours: [(Int, Int)] = [
						(cellColumn - 1, cellRow),
						(cellColumn + 1, cellRow),
						(cellColumn, cellRow - 1),
						(cellColumn, cellRow + 1),
					]
					for (neighbourColumn, neighbourRow): (Int, Int) in neighbours {
						guard neighbourColumn >= 0, neighbourColumn < columns,
							neighbourRow >= 0, neighbourRow < rows
						else { continue }
						let neighbour: Int = neighbourRow * columns + neighbourColumn
						guard inside[neighbour], labels[neighbour] == -1 else { continue }
						labels[neighbour] = next
						stack.append(neighbour)
					}
				}
				next += 1
			}
		}
		return labels
	}

	// MARK: - One fragment

	private static func fragment(
		component: Int,
		labels: [Int],
		columns: Int,
		rows: Int,
		xAxis: SnappedAxis,
		yAxis: SnappedAxis,
		displayID: DisplayID,
		panelIDs: [PanelID]
	) -> WorkspaceContourFragment? {
		var edges: [GridEdge] = []
		for row: Int in 0 ..< rows {
			for column: Int in 0 ..< columns {
				guard labels[row * columns + column] == component else { continue }
				// Oriented so the cell is on the left of its own edge: an isolated
				// cell therefore traces east, north, west, south — counter-clockwise
				// in the solver's y-up coordinates.
				if !belongs(column - 1, row, component, labels, columns, rows) {
					edges.append(.init(x: column, y: row + 1, direction: .south))
				}
				if !belongs(column + 1, row, component, labels, columns, rows) {
					edges.append(.init(x: column + 1, y: row, direction: .north))
				}
				if !belongs(column, row - 1, component, labels, columns, rows) {
					edges.append(.init(x: column, y: row, direction: .east))
				}
				if !belongs(column, row + 1, component, labels, columns, rows) {
					edges.append(.init(x: column + 1, y: row + 1, direction: .west))
				}
			}
		}

		let loops: [ContourLoop] = trace(edges).compactMap {
			canonicalised($0, xAxis: xAxis, yAxis: yAxis)
		}
		// A 4-connected union of cells has exactly one outer boundary; every other
		// loop it traces rings an enclosed region.
		guard let outer: ContourLoop = loops.first(where: { !$0.isHole }) else {
			return nil
		}
		return .init(
			displayID: displayID,
			outer: outer,
			holes: loops.filter(\.isHole).sorted(by: loopOrder),
			panelIDs: panelIDs,
			// Rewritten group-wide by `contours(_:canvasOrder:inflation:)`.
			ordinal: 0
		)
	}

	private static func loopOrder(_ lhs: ContourLoop, _ rhs: ContourLoop) -> Bool {
		guard let left: LayoutPoint = lhs.vertices.first,
			let right: LayoutPoint = rhs.vertices.first
		else { return lhs.vertices.count < rhs.vertices.count }
		if left.x != right.x { return left.x < right.x }
		return left.y < right.y
	}

	private static func belongs(
		_ column: Int,
		_ row: Int,
		_ component: Int,
		_ labels: [Int],
		_ columns: Int,
		_ rows: Int
	) -> Bool {
		guard column >= 0, column < columns, row >= 0, row < rows else {
			return false
		}
		return labels[row * columns + column] == component
	}

	/// Walks the boundary edges into closed loops. At each vertex the first
	/// unused outgoing edge is taken in the order left turn, straight, right
	/// turn. That is what resolves the only ambiguous vertex — two diagonal
	/// cells inside — into two fragments meeting at a point rather than one
	/// pinched loop, which is how a person reads a diagonal neighbour: not a
	/// neighbour.
	private static func trace(_ edges: [GridEdge]) -> [[GridVertex]] {
		var outgoing: [GridVertex: [GridEdge]] = [:]
		for edge: GridEdge in edges { outgoing[edge.start, default: []].append(edge) }
		let ordered: [GridEdge] = edges.sorted { lhs, rhs in
			if lhs.start.x != rhs.start.x { return lhs.start.x < rhs.start.x }
			if lhs.start.y != rhs.start.y { return lhs.start.y < rhs.start.y }
			return lhs.direction.rawValue < rhs.direction.rawValue
		}

		var used: Set<GridEdge> = []
		var loops: [[GridVertex]] = []
		for start: GridEdge in ordered where !used.contains(start) {
			var loop: [GridVertex] = []
			var current: GridEdge = start
			var steps: Int = 0
			while true {
				steps += 1
				guard steps <= edges.count else {
					// Every boundary edge set closes; exceeding the edge count means
					// the marking or the turn order is wrong. Drop the fragment
					// rather than emit a loop that is not one.
					assertionFailure("contour tracing did not close")
					loop = []
					break
				}
				used.insert(current)
				loop.append(current.start)
				let candidates: [GridEdge] = outgoing[current.end] ?? []
				let turns: [GridDirection] = [
					current.direction.turningLeft,
					current.direction,
					current.direction.turningRight,
				]
				var next: GridEdge?
				for turn: GridDirection in turns {
					guard let match: GridEdge = candidates.first(
						where: { $0.direction == turn && (!used.contains($0) || $0 == start) }
					) else { continue }
					next = match
					break
				}
				guard let next else {
					assertionFailure("contour tracing reached a dead end")
					loop = []
					break
				}
				if next == start { break }
				current = next
			}
			if !loop.isEmpty { loops.append(loop) }
		}
		return loops
	}

	/// Grid indices back to snapped coordinates, minus every vertex collinear
	/// with its neighbours — grid lines contributed by unrelated Panels put
	/// spurious vertices along straight runs, and dropping them is what makes a
	/// fragment's spelling independent of the rest of the canvas. Rotated to
	/// start at the smallest vertex, never reversed, so orientation survives.
	private static func canonicalised(
		_ vertices: [GridVertex],
		xAxis: SnappedAxis,
		yAxis: SnappedAxis
	) -> ContourLoop? {
		guard vertices.count >= 4 else { return nil }
		let points: [LayoutPoint] = vertices.map {
			.init(x: xAxis.representatives[$0.x], y: yAxis.representatives[$0.y])
		}
		var corners: [LayoutPoint] = []
		for index: Int in points.indices {
			let previous: LayoutPoint = points[(index + points.count - 1) % points.count]
			let current: LayoutPoint = points[index]
			let next: LayoutPoint = points[(index + 1) % points.count]
			let straight: Bool =
				(previous.x == current.x && current.x == next.x)
				|| (previous.y == current.y && current.y == next.y)
			if !straight { corners.append(current) }
		}
		guard corners.count >= 4 else { return nil }
		var smallest: Int = 0
		for index: Int in corners.indices {
			let candidate: LayoutPoint = corners[index]
			let best: LayoutPoint = corners[smallest]
			if candidate.x < best.x || (candidate.x == best.x && candidate.y < best.y) {
				smallest = index
			}
		}
		return .init(
			vertices: Array(corners[smallest...] + corners[..<smallest])
		)
	}
}

/// One axis's coordinates, clustered once for the whole canvas. After this the
/// pass compares integers only: no double is compared again.
private struct SnappedAxis {
	let representatives: [Double]
	private let indexOf: [Double: Int]

	init(_ values: [Double]) {
		var representatives: [Double] = []
		var indexOf: [Double: Int] = [:]
		var clusterFirst: Double = 0
		for value: Double in values.sorted() {
			// Bounded diameter, not pairwise nearness: approximate equality is not
			// transitive, and a chain of near-misses would otherwise drag two
			// genuinely different edges into one cluster.
			if representatives.isEmpty
				|| value - clusterFirst > WorkspaceContourGeometry.epsilon
			{
				clusterFirst = value
				representatives.append(value)
			}
			indexOf[value] = representatives.count - 1
		}
		self.representatives = representatives
		self.indexOf = indexOf
	}

	func index(of value: Double) -> Int? { indexOf[value] }
}

private enum GridDirection: Int {
	case east = 0
	case north = 1
	case west = 2
	case south = 3

	var turningLeft: GridDirection {
		.init(rawValue: (rawValue + 1) % 4) ?? self
	}

	var turningRight: GridDirection {
		.init(rawValue: (rawValue + 3) % 4) ?? self
	}
}

private struct GridVertex: Hashable {
	let x: Int
	let y: Int
}

private struct GridEdge: Hashable {
	let start: GridVertex
	let direction: GridDirection

	init(x: Int, y: Int, direction: GridDirection) {
		start = .init(x: x, y: y)
		self.direction = direction
	}

	var end: GridVertex {
		switch direction {
		case .east: return .init(x: start.x + 1, y: start.y)
		case .north: return .init(x: start.x, y: start.y + 1)
		case .west: return .init(x: start.x - 1, y: start.y)
		case .south: return .init(x: start.x, y: start.y - 1)
		}
	}
}

/// Ten fluorescent hues, hashed from the Workspace's own ID so a fragment on
/// another canvas is the same colour and a relaunch does not repaint the
/// canvas.
enum WorkspaceContourPalette {
	/// The arc 145°–269° is left out on purpose: `systemBlue` sits at roughly
	/// 210°, and both the Virtual Focus ring and the drop highlight use it. A
	/// group contour must never be mistaken for either.
	private static let hues: [Double] = [
		270, 296, 322, 348, 14, 40, 66, 92, 118, 144,
	]

	static let colors: [WorkspaceContourColor] = hues.map {
		fluorescent(hue: $0)
	}

	/// FNV-1a 64. `Hasher` and `String.hashValue` are seeded per process: they
	/// would repaint every Workspace on each launch and never agree between two
	/// clients looking at the same organization.
	static func hash(_ workspaceID: WorkspaceID) -> UInt64 {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte: UInt8 in Array(workspaceID.rawValue.utf8) {
			hash ^= UInt64(byte)
			hash = hash &* 0x0000_0100_0000_01b3
		}
		hash ^= hash >> 32
		return hash
	}

	static func baseIndex(_ workspaceID: WorkspaceID) -> Int {
		Int(hash(workspaceID) % UInt64(colors.count))
	}

	/// One colour per Workspace for the whole session. Takes every Workspace the
	/// presentation has, never one canvas's, because a Workspace that changed
	/// colour between canvases would break the only thing its contour is for.
	///
	/// A collision probes forward, so the earlier-sorting ID always keeps its
	/// hashed hue and only the later one moves. Past ten Workspaces a colour
	/// repeats rather than a group going unmarked.
	static func assignment(
		for workspaceIDs: [WorkspaceID]
	) -> [WorkspaceID: WorkspaceContourColor] {
		var taken: Set<Int> = []
		var assignment: [WorkspaceID: WorkspaceContourColor] = [:]
		for workspaceID: WorkspaceID in workspaceIDs.sorted(
			by: { $0.rawValue < $1.rawValue }
		) {
			let base: Int = baseIndex(workspaceID)
			var chosen: Int = base
			for probe: Int in 0 ..< colors.count {
				let candidate: Int = (base + probe) % colors.count
				guard !taken.contains(candidate) else { continue }
				chosen = candidate
				break
			}
			taken.insert(chosen)
			assignment[workspaceID] = colors[chosen]
		}
		return assignment
	}

	/// HSB at full brightness and 0.95 saturation: saturated enough to read as
	/// fluorescent over a photograph, short of the clipping that makes adjacent
	/// hues indistinguishable.
	private static func fluorescent(hue: Double) -> WorkspaceContourColor {
		let saturation: Double = 0.95
		let sector: Double = (hue / 60).truncatingRemainder(dividingBy: 6)
		let fraction: Double = sector - sector.rounded(.down)
		let dim: Double = 1 - saturation
		let falling: Double = 1 - saturation * fraction
		let rising: Double = 1 - saturation * (1 - fraction)
		let rounded: (Double) -> Double = { ($0 * 100).rounded() / 100 }
		switch Int(sector) {
		case 0: return .init(red: 1, green: rounded(rising), blue: rounded(dim))
		case 1: return .init(red: rounded(falling), green: 1, blue: rounded(dim))
		case 2: return .init(red: rounded(dim), green: 1, blue: rounded(rising))
		case 3: return .init(red: rounded(dim), green: rounded(falling), blue: 1)
		case 4: return .init(red: rounded(rising), green: rounded(dim), blue: 1)
		default: return .init(red: 1, green: rounded(dim), blue: rounded(falling))
		}
	}
}
