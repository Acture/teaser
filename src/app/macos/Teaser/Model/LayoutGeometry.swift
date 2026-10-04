import Foundation

struct LayoutPoint: Codable, Equatable, Hashable, Sendable {
	var x: Double
	var y: Double

	static let zero: LayoutPoint = .init(x: 0, y: 0)
}

struct LayoutSize: Codable, Equatable, Hashable, Sendable {
	var width: Double
	var height: Double

	static let zero: LayoutSize = .init(width: 0, height: 0)

	var area: Double {
		width * height
	}
}

struct LayoutRect: Codable, Equatable, Hashable, Sendable {
	var origin: LayoutPoint
	var size: LayoutSize

	init(x: Double, y: Double, width: Double, height: Double) {
		origin = .init(x: x, y: y)
		size = .init(width: width, height: height)
	}

	init(origin: LayoutPoint, size: LayoutSize) {
		self.origin = origin
		self.size = size
	}

	var minX: Double { origin.x }
	var maxX: Double { origin.x + size.width }
	var minY: Double { origin.y }
	var maxY: Double { origin.y + size.height }
	var midX: Double { origin.x + size.width / 2 }
	var midY: Double { origin.y + size.height / 2 }

	func contains(_ point: LayoutPoint) -> Bool {
		point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
	}

	func contains(_ rect: LayoutRect, tolerance: Double = 0) -> Bool {
		rect.minX >= minX - tolerance
			&& rect.maxX <= maxX + tolerance
			&& rect.minY >= minY - tolerance
			&& rect.maxY <= maxY + tolerance
	}

	func intersects(_ other: LayoutRect) -> Bool {
		maxX > other.minX
			&& other.maxX > minX
			&& maxY > other.minY
			&& other.maxY > minY
	}

	func insetBy(dx: Double, dy: Double) -> LayoutRect {
		.init(
			x: minX + dx,
			y: minY + dy,
			width: max(0, size.width - 2 * dx),
			height: max(0, size.height - 2 * dy)
		)
	}
}

extension Double {
	func clamped(to range: ClosedRange<Double>) -> Double {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
