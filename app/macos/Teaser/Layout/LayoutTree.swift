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

	var insertsBeforeTarget: Bool {
		self == .leading || self == .top
	}
}

struct SplitPreference: Codable, Equatable, Hashable, Sendable {
	var desiredRatio: Double
	var effectiveRatio: Double?

	init(desiredRatio: Double, effectiveRatio: Double? = nil) {
		precondition(desiredRatio > 0 && desiredRatio < 1)
		if let effectiveRatio {
			precondition(effectiveRatio > 0 && effectiveRatio < 1)
		}
		self.desiredRatio = desiredRatio
		self.effectiveRatio = effectiveRatio
	}

	var renderedRatio: Double {
		effectiveRatio ?? desiredRatio
	}
}

enum LayoutTreeEditError: Error, Equatable, Sendable {
	case duplicateLeaf
	case invalidRatio
	case targetNotFound
	case splitNotFound
	case cannotRemoveOnlyLeaf
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

	mutating func setDesiredRatio(
		_ ratio: Double,
		for splitID: LayoutSplitID
	) throws {
		guard ratio > 0 && ratio < 1 else {
			throw LayoutTreeEditError.invalidRatio
		}
		let didUpdate: Bool = updateSplit(splitID, update: { preference in
			preference.desiredRatio = ratio
			preference.effectiveRatio = nil
		})
		guard didUpdate else {
			throw LayoutTreeEditError.splitNotFound
		}
	}

	mutating func applyEffectiveRatios(
		_ ratios: [LayoutSplitID: Double]
	) {
		for (splitID, ratio): (LayoutSplitID, Double) in ratios {
			_ = updateSplit(splitID) { preference in
				preference.effectiveRatio = ratio
			}
		}
	}

	mutating func clearEffectiveRatios() {
		switch self {
		case .leaf:
			return
		case .split(let id, let axis, var preference, var first, var second):
			preference.effectiveRatio = nil
			first.clearEffectiveRatios()
			second.clearEffectiveRatios()
			self = .split(
				id: id,
				axis: axis,
				preference: preference,
				first: first,
				second: second
			)
		}
	}

	mutating func insert(
		_ newLeaf: Leaf,
		at edge: LayoutEdge,
		of target: Leaf,
		splitID: LayoutSplitID,
		desiredRatio: Double = 0.5
	) throws {
		guard !contains(newLeaf) else {
			throw LayoutTreeEditError.duplicateLeaf
		}
		guard insertUnchecked(
			newLeaf,
			at: edge,
			of: target,
			splitID: splitID,
			desiredRatio: desiredRatio
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
		desiredRatio: Double
	) -> Bool {
		switch self {
		case .leaf(let leaf):
			guard leaf == target else { return false }
			let newTree: LayoutTree<Leaf> = .leaf(newLeaf)
			let oldTree: LayoutTree<Leaf> = .leaf(leaf)
			self = .split(
				id: splitID,
				axis: edge.axis,
				preference: .init(desiredRatio: desiredRatio),
				first: edge.insertsBeforeTarget ? newTree : oldTree,
				second: edge.insertsBeforeTarget ? oldTree : newTree
			)
			return true
		case .split(let id, let axis, let preference, var first, var second):
			let insertedFirst: Bool = first.insertUnchecked(
				newLeaf,
				at: edge,
				of: target,
				splitID: splitID,
				desiredRatio: desiredRatio
			)
			let insertedSecond: Bool = insertedFirst
				? false
				: second.insertUnchecked(
					newLeaf,
					at: edge,
					of: target,
					splitID: splitID,
					desiredRatio: desiredRatio
				)
			self = .split(
				id: id,
				axis: axis,
				preference: preference,
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
