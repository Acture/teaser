import Foundation

enum LayoutAxis: String, Codable, Equatable, Hashable, Sendable {
	case horizontal
	case vertical
}

enum LayoutEdge: String, Codable, Equatable, Hashable, Sendable {
	case leading
	case trailing
	case top
	case bottom

	var axis: LayoutAxis {
		switch self {
		case .leading, .trailing:
			return .horizontal
		case .top, .bottom:
			return .vertical
		}
	}

	/// The solver lays a split's first child at the lower coordinate on its axis,
	/// and layout frames are AppKit screen frames, so first means leading on the
	/// horizontal axis and bottom on the vertical one.
	var insertsBeforeTarget: Bool {
		self == .leading || self == .bottom
	}
}

struct SplitPreference: Codable, Equatable, Hashable, Sendable {
	/// The proportion the person set by dragging this divider. `nil` means the
	/// divider has never been dragged, so the solver keeps deriving it from the
	/// growth weights of the two subtrees and the split follows the Panels
	/// inside it rather than halving whatever it is given.
	///
	/// A solve clamped by a minimum is never written back here, so a proportion
	/// the canvas is currently too small to honour returns intact once the room
	/// does.
	fileprivate(set) var userRatio: Double?

	init(userRatio: Double? = nil) {
		if let userRatio {
			precondition(userRatio > 0 && userRatio < 1)
		}
		self.userRatio = userRatio
	}

	/// Sized by the Panels inside it. Everything that is not a person dragging a
	/// divider creates a split this way.
	static let derived: SplitPreference = .init()

	static func user(_ ratio: Double) -> SplitPreference {
		.init(userRatio: ratio)
	}

	var isUserSet: Bool { userRatio != nil }
}

enum LayoutTreeEditError: Error, Equatable, LocalizedError, Sendable {
	case duplicateLeaf
	case invalidRatio
	case targetNotFound
	case splitNotFound
	case cannotRemoveOnlyLeaf

	var errorDescription: String? {
		switch self {
		case .duplicateLeaf:
			return "That region already exists in this layout tree."
		case .invalidRatio:
			return "A split ratio must be greater than 0 and less than 1."
		case .targetNotFound:
			return "The region this edit targets is no longer in the layout."
		case .splitNotFound:
			return "The divider this edit targets is no longer in the layout."
		case .cannotRemoveOnlyLeaf:
			return "The last remaining region cannot be removed."
		}
	}
}

indirect enum LayoutTree<Leaf>: Codable, Equatable, Hashable, Sendable
where Leaf: Codable & Hashable & Sendable {
	case leaf(Leaf)
	case split(
		id: LayoutSplitID,
		axis: LayoutAxis,
		preference: SplitPreference,
		first: LayoutTree<Leaf>,
		second: LayoutTree<Leaf>
	)

	var leaves: [Leaf] {
		switch self {
		case .leaf(let leaf):
			return [leaf]
		case .split(_, _, _, let first, let second):
			return first.leaves + second.leaves
		}
	}

	var splitIDs: [LayoutSplitID] {
		switch self {
		case .leaf:
			return []
		case .split(let id, _, _, let first, let second):
			return [id] + first.splitIDs + second.splitIDs
		}
	}

	func contains(_ leaf: Leaf) -> Bool {
		leaves.contains(leaf)
	}

	/// Records a proportion a person chose. From here on this split ignores its
	/// subtrees' growth weights: the ratio is theirs until they clear it.
	mutating func setUserRatio(
		_ ratio: Double,
		for splitID: LayoutSplitID
	) throws {
		guard ratio > 0 && ratio < 1 else {
			throw LayoutTreeEditError.invalidRatio
		}
		let didUpdate: Bool = updateSplit(splitID, update: { preference in
			preference.userRatio = ratio
		})
		guard didUpdate else {
			throw LayoutTreeEditError.splitNotFound
		}
	}

	/// Hands one split back to the growth weights.
	mutating func clearUserRatio(for splitID: LayoutSplitID) throws {
		let didUpdate: Bool = updateSplit(splitID, update: { preference in
			preference.userRatio = nil
		})
		guard didUpdate else {
			throw LayoutTreeEditError.splitNotFound
		}
	}

	mutating func insert(
		_ newLeaf: Leaf,
		at edge: LayoutEdge,
		of target: Leaf,
		splitID: LayoutSplitID,
		preference: SplitPreference = .derived
	) throws {
		guard !contains(newLeaf) else {
			throw LayoutTreeEditError.duplicateLeaf
		}
		guard insertUnchecked(
			newLeaf,
			at: edge,
			of: target,
			splitID: splitID,
			preference: preference
		) else {
			throw LayoutTreeEditError.targetNotFound
		}
	}

	mutating func split(
		_ target: Leaf,
		with newLeaf: Leaf,
		inside targetFrame: LayoutRect,
		forcedAxis: LayoutAxis? = nil,
		splitID: LayoutSplitID
	) throws {
		let axis: LayoutAxis = forcedAxis
			?? (targetFrame.size.width >= targetFrame.size.height ? .horizontal : .vertical)
		let edge: LayoutEdge = axis == .horizontal ? .trailing : .bottom
		try insert(newLeaf, at: edge, of: target, splitID: splitID)
	}

	mutating func remove(_ leaf: Leaf) throws {
		guard case .split = self else {
			throw LayoutTreeEditError.cannotRemoveOnlyLeaf
		}
		guard let replacement: LayoutTree<Leaf> = removing(leaf) else {
			throw LayoutTreeEditError.targetNotFound
		}
		self = replacement
	}

	mutating func swap(_ firstLeaf: Leaf, _ secondLeaf: Leaf) throws {
		guard firstLeaf != secondLeaf,
			contains(firstLeaf),
			contains(secondLeaf)
		else {
			throw LayoutTreeEditError.targetNotFound
		}
		swapUnchecked(firstLeaf, secondLeaf)
	}

	private mutating func updateSplit(
		_ splitID: LayoutSplitID,
		update: (inout SplitPreference) -> Void
	) -> Bool {
		switch self {
		case .leaf:
			return false
		case .split(let id, let axis, var preference, var first, var second):
			if id == splitID {
				update(&preference)
				self = .split(
					id: id,
					axis: axis,
					preference: preference,
					first: first,
					second: second
				)
				return true
			}
			let didUpdateFirst: Bool = first.updateSplit(splitID, update: update)
			let didUpdateSecond: Bool = didUpdateFirst
				? false
				: second.updateSplit(splitID, update: update)
			self = .split(
				id: id,
				axis: axis,
				preference: preference,
				first: first,
				second: second
			)
			return didUpdateFirst || didUpdateSecond
		}
	}

	private mutating func insertUnchecked(
		_ newLeaf: Leaf,
		at edge: LayoutEdge,
		of target: Leaf,
		splitID: LayoutSplitID,
		preference: SplitPreference
	) -> Bool {
		switch self {
		case .leaf(let leaf):
			guard leaf == target else { return false }
			let newTree: LayoutTree<Leaf> = .leaf(newLeaf)
			let oldTree: LayoutTree<Leaf> = .leaf(leaf)
			self = .split(
				id: splitID,
				axis: edge.axis,
				preference: preference,
				first: edge.insertsBeforeTarget ? newTree : oldTree,
				second: edge.insertsBeforeTarget ? oldTree : newTree
			)
			return true
		// `existing` is this node's own preference. Binding it as `preference`
		// would shadow the one being inserted, and every leaf that landed below
		// the root would silently take its parent's proportion.
		case .split(let id, let axis, let existing, var first, var second):
			let insertedFirst: Bool = first.insertUnchecked(
				newLeaf,
				at: edge,
				of: target,
				splitID: splitID,
				preference: preference
			)
			let insertedSecond: Bool = insertedFirst
				? false
				: second.insertUnchecked(
					newLeaf,
					at: edge,
					of: target,
					splitID: splitID,
					preference: preference
				)
			self = .split(
				id: id,
				axis: axis,
				preference: existing,
				first: first,
				second: second
			)
			return insertedFirst || insertedSecond
		}
	}

	private func removing(_ removedLeaf: Leaf) -> LayoutTree<Leaf>? {
		switch self {
		case .leaf(let leaf):
			return leaf == removedLeaf ? nil : self
		case .split(let id, let axis, let preference, let first, let second):
			let nextFirst: LayoutTree<Leaf>? = first.removing(removedLeaf)
			let nextSecond: LayoutTree<Leaf>? = second.removing(removedLeaf)
			switch (nextFirst, nextSecond) {
			case (nil, nil):
				return nil
			case (nil, let remaining?):
				return remaining
			case (let remaining?, nil):
				return remaining
			case (let first?, let second?):
				return .split(
					id: id,
					axis: axis,
					preference: preference,
					first: first,
					second: second
				)
			}
		}
	}

	private mutating func swapUnchecked(_ firstLeaf: Leaf, _ secondLeaf: Leaf) {
		switch self {
		case .leaf(let leaf):
			if leaf == firstLeaf {
				self = .leaf(secondLeaf)
			} else if leaf == secondLeaf {
				self = .leaf(firstLeaf)
			}
		case .split(let id, let axis, let preference, var first, var second):
			first.swapUnchecked(firstLeaf, secondLeaf)
			second.swapUnchecked(firstLeaf, secondLeaf)
			self = .split(
				id: id,
				axis: axis,
				preference: preference,
				first: first,
				second: second
			)
		}
	}
}
