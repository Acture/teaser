import AppKit
import Foundation
import GhosttyKit

struct TerminalResizeEvent: Equatable, CustomStringConvertible, Sendable {
	let columns: UInt16
	let rows: UInt16
	let widthPixels: UInt32
	let heightPixels: UInt32

	var description: String {
		"\(columns)x\(rows) cells, \(widthPixels)x\(heightPixels) px"
	}

	init(
		columns: UInt16,
		rows: UInt16,
		widthPixels: UInt32,
		heightPixels: UInt32
	) {
		self.columns = columns
		self.rows = rows
		self.widthPixels = widthPixels
		self.heightPixels = heightPixels
	}

	init(size: ghostty_surface_size_s) {
		self.init(
			columns: size.columns,
			rows: size.rows,
			widthPixels: size.width_px,
			heightPixels: size.height_px
		)
	}
}

enum TerminalSurfaceAdapterError: Error, CustomStringConvertible {
	case alreadyAttached
	case quiesced

	var description: String {
		switch self {
		case .alreadyAttached:
			return "terminal Surface adapter already owns an attachment enqueuer"
		case .quiesced:
			return "terminal Surface adapter is quiesced"
		}
	}
}

/// Copies Ghostty's synchronous EXTERNAL callbacks into a nonblocking,
/// production-shaped attachment pump. The adapter owns no socket or Session
/// lifetime.
final class TerminalSurfaceAdapter: @unchecked Sendable {
	private static let maximumRecordedFailures: Int = 64

	private let condition: NSCondition = .init()
	private var acceptingCallbacks: Bool = true
	private var activeCallbacks: Int = 0
	private var enqueuer: (any TerminalAttachmentEnqueuing)?
	private var lastResizeEvent: TerminalResizeEvent?
	private var resizeRevision: UInt64 = 0
	private var lastForwardableSize: AttachmentTerminalSize?
	private var callbackFailures: [String] = []

	private struct CallbackLease {
		let enqueuer: (any TerminalAttachmentEnqueuing)?
	}

	init(enqueuer: (any TerminalAttachmentEnqueuing)? = nil) {
		self.enqueuer = enqueuer
	}

	@MainActor
	func makeConfiguration(
		view: NSView,
		scaleFactor: CGFloat
	) -> ghostty_surface_config_s {
		var config: ghostty_surface_config_s = ghostty_surface_config_new()
		config.platform_tag = GHOSTTY_PLATFORM_MACOS
		config.platform = ghostty_platform_u(
			macos: ghostty_platform_macos_s(
				nsview: Unmanaged.passUnretained(view).toOpaque()
			)
		)
		config.scale_factor = Double(scaleFactor)
		config.io_mode = GHOSTTY_SURFACE_IO_EXTERNAL
		config.external_userdata = Unmanaged.passUnretained(self).toOpaque()
		config.external_write_cb = { userdata, bytes, count in
			guard let userdata else { return }
			let adapter: TerminalSurfaceAdapter =
				Unmanaged<TerminalSurfaceAdapter>
				.fromOpaque(userdata)
				.takeUnretainedValue()
			adapter.receiveWrite(bytes: bytes, count: count)
		}
		config.external_resize_cb = {
			userdata,
			columns,
			rows,
			widthPixels,
			heightPixels in
			guard let userdata else { return }
			let adapter: TerminalSurfaceAdapter =
				Unmanaged<TerminalSurfaceAdapter>
				.fromOpaque(userdata)
				.takeUnretainedValue()
			adapter.receiveResize(
				columns: columns,
				rows: rows,
				widthPixels: widthPixels,
				heightPixels: heightPixels
			)
		}
		return config
	}

	@MainActor
	func install(enqueuer: any TerminalAttachmentEnqueuing) throws {
		condition.lock()
		guard acceptingCallbacks else {
			condition.unlock()
			throw TerminalSurfaceAdapterError.quiesced
		}
		while activeCallbacks > 0 {
			condition.wait()
		}
		guard self.enqueuer == nil else {
			condition.unlock()
			throw TerminalSurfaceAdapterError.alreadyAttached
		}

		while true {
			let observedResizeRevision: UInt64 = resizeRevision
			let size: AttachmentTerminalSize? = lastForwardableSize
			condition.unlock()
			if let size {
				_ = enqueuer.enqueueResize(size)
			}
			condition.lock()
			while activeCallbacks > 0 {
				condition.wait()
			}
			guard acceptingCallbacks else {
				condition.unlock()
				throw TerminalSurfaceAdapterError.quiesced
			}
			if resizeRevision == observedResizeRevision {
				self.enqueuer = enqueuer
				condition.unlock()
				return
			}
		}
	}

	@MainActor
	func detach() {
		condition.lock()
		while activeCallbacks > 0 {
			condition.wait()
		}
		enqueuer = nil
		condition.unlock()
	}

	@MainActor
	func quiesce() {
		condition.lock()
		acceptingCallbacks = false
		while activeCallbacks > 0 {
			condition.wait()
		}
		enqueuer = nil
		condition.unlock()
	}

	func resetResizes() {
		condition.lock()
		lastResizeEvent = nil
		resizeRevision &+= 1
		lastForwardableSize = nil
		condition.unlock()
	}

	func lastResize() -> TerminalResizeEvent? {
		condition.lock()
		defer { condition.unlock() }
		return lastResizeEvent
	}

	func failures() -> [String] {
		condition.lock()
		defer { condition.unlock() }
		return callbackFailures
	}

	private func receiveWrite(bytes: UnsafePointer<UInt8>?, count: Int) {
		guard let lease = beginCallback() else { return }
		defer { endCallback() }

		guard count >= 0 else {
			recordFailure("write callback reported a negative byte count")
			return
		}
		guard count == 0 || bytes != nil else {
			recordFailure(
				"write callback reported \(count) bytes with a nil pointer"
			)
			return
		}
		guard let bytes, count > 0 else { return }
		guard let currentEnqueuer = lease.enqueuer else {
			recordFailure("input callback arrived without an attached Session")
			return
		}
		let payload: [UInt8] = Array(
			UnsafeBufferPointer(start: bytes, count: count)
		)
		_ = currentEnqueuer.enqueueInput(payload)
	}

	private func receiveResize(
		columns: UInt16,
		rows: UInt16,
		widthPixels: UInt32,
		heightPixels: UInt32
	) {
		guard let lease = beginCallback() else { return }
		defer { endCallback() }

		let event: TerminalResizeEvent = .init(
			columns: columns,
			rows: rows,
			widthPixels: widthPixels,
			heightPixels: heightPixels
		)
		guard rows > 0, columns > 0 else {
			recordFailure("resize callback reported an empty terminal grid")
			return
		}
		guard
			let pixelWidth = UInt16(exactly: widthPixels),
			let pixelHeight = UInt16(exactly: heightPixels)
		else {
			recordFailure(
				"resize callback exceeds the attachment protocol's UInt16 "
					+ "pixel bound: \(widthPixels)x\(heightPixels)"
			)
			return
		}
		let size: AttachmentTerminalSize = .init(
			rows: rows,
			columns: columns,
			pixelWidth: pixelWidth,
			pixelHeight: pixelHeight
		)
		condition.lock()
		lastResizeEvent = event
		resizeRevision &+= 1
		lastForwardableSize = size
		condition.broadcast()
		condition.unlock()

		guard let currentEnqueuer = lease.enqueuer else { return }
		_ = currentEnqueuer.enqueueResize(size)
	}

	private func beginCallback() -> CallbackLease? {
		condition.lock()
		defer { condition.unlock() }
		guard acceptingCallbacks else { return nil }
		activeCallbacks += 1
		return CallbackLease(enqueuer: enqueuer)
	}

	private func endCallback() {
		condition.lock()
		activeCallbacks -= 1
		condition.broadcast()
		condition.unlock()
	}

	private func recordFailure(_ message: String) {
		condition.lock()
		if callbackFailures.count < Self.maximumRecordedFailures {
			callbackFailures.append(message)
		}
		condition.broadcast()
		condition.unlock()
	}
}
