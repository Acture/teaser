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
			return "terminal Surface adapter already owns an attachment"
		case .quiesced:
			return "terminal Surface adapter is quiesced"
		}
	}
}

/// Bridges Ghostty's synchronous EXTERNAL callbacks to one exclusive tacod
/// attachment. Writes remain synchronous and bounded, so this probe seam never
/// grows an unbounded input queue. A production host can replace this transport
/// policy without changing the Ghostty callback boundary.
final class TerminalSurfaceAdapter: @unchecked Sendable {
	private let condition: NSCondition = .init()
	private var acceptingCallbacks: Bool = true
	private var activeCallbacks: Int = 0
	private var client: AttachmentClient?
	private var resizeHistory: [TerminalResizeEvent] = []
	private var lastForwardableSize: AttachmentTerminalSize?
	private var callbackFailures: [String] = []

	private struct CallbackLease {
		let client: AttachmentClient?
	}

	init(client: AttachmentClient) {
		self.client = client
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

	func install(client: AttachmentClient) throws {
		condition.lock()
		guard acceptingCallbacks else {
			condition.unlock()
			throw TerminalSurfaceAdapterError.quiesced
		}
		while activeCallbacks > 0 {
			condition.wait()
		}
		guard self.client == nil else {
			condition.unlock()
			throw TerminalSurfaceAdapterError.alreadyAttached
		}
		let size: AttachmentTerminalSize? = lastForwardableSize

		do {
			if let size {
				try client.sendResize(size)
			}
		} catch {
			condition.unlock()
			client.close()
			throw error
		}
		self.client = client
		condition.unlock()
	}

	func detach() {
		condition.lock()
		while activeCallbacks > 0 {
			condition.wait()
		}
		let detachedClient: AttachmentClient? = client
		client = nil
		condition.unlock()
		detachedClient?.close()
	}

	func quiesceAndDetach() {
		condition.lock()
		acceptingCallbacks = false
		while activeCallbacks > 0 {
			condition.wait()
		}
		let detachedClient: AttachmentClient? = client
		client = nil
		condition.unlock()
		detachedClient?.close()
	}

	func resetResizes() {
		condition.lock()
		resizeHistory.removeAll(keepingCapacity: true)
		lastForwardableSize = nil
		condition.unlock()
	}

	func lastResize() -> TerminalResizeEvent? {
		condition.lock()
		defer { condition.unlock() }
		return resizeHistory.last
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
		guard let currentClient = lease.client else {
			recordFailure("input callback arrived without an attached Session")
			return
		}
		do {
			var offset: Int = 0
			while offset < count {
				let chunkCount: Int = min(
					attachmentMaximumFramePayloadBytes,
					count - offset
				)
				let chunk: [UInt8] = Array(
					UnsafeBufferPointer(
						start: bytes.advanced(by: offset),
						count: chunkCount
					)
				)
				try currentClient.sendInput(chunk)
				offset += chunkCount
			}
		} catch {
			recordFailure("input forwarding failed: \(error)")
		}
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
		resizeHistory.append(event)
		lastForwardableSize = size
		condition.broadcast()
		condition.unlock()

		guard let currentClient = lease.client else { return }
		do {
			try currentClient.sendResize(size)
		} catch {
			recordFailure("resize forwarding failed: \(error)")
		}
	}

	private func beginCallback() -> CallbackLease? {
		condition.lock()
		defer { condition.unlock() }
		guard acceptingCallbacks else { return nil }
		activeCallbacks += 1
		return CallbackLease(client: client)
	}

	private func endCallback() {
		condition.lock()
		activeCallbacks -= 1
		condition.broadcast()
		condition.unlock()
	}

	private func recordFailure(_ message: String) {
		condition.lock()
		callbackFailures.append(message)
		condition.broadcast()
		condition.unlock()
	}
}
