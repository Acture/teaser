import Darwin
import Foundation

let attachmentProtocolVersion: UInt32 = 1
let attachmentMaximumFramePayloadBytes: Int = 65_536

struct AttachmentConnectionDeadline: Sendable {
	let uptimeNanoseconds: UInt64

	init(timeout: TimeInterval) {
		precondition(timeout.isFinite && timeout > 0)
		let intervalNanosecondsValue: TimeInterval =
			(timeout * 1_000_000_000).rounded(.up)
		let intervalNanoseconds: UInt64 =
			intervalNanosecondsValue >= TimeInterval(UInt64.max)
			? UInt64.max
			: UInt64(intervalNanosecondsValue)
		let (deadline, overflow): (UInt64, Bool) =
			DispatchTime.now().uptimeNanoseconds
			.addingReportingOverflow(intervalNanoseconds)
		uptimeNanoseconds = overflow ? UInt64.max : deadline
	}

	private init(uptimeNanoseconds: UInt64) {
		self.uptimeNanoseconds = uptimeNanoseconds
	}

	var remainingTimeInterval: TimeInterval {
		let now: UInt64 = DispatchTime.now().uptimeNanoseconds
		guard now < uptimeNanoseconds else { return 0 }
		return TimeInterval(uptimeNanoseconds - now) / 1_000_000_000
	}

	var isExpired: Bool {
		DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds
	}

	var dispatchTime: DispatchTime {
		.init(uptimeNanoseconds: uptimeNanoseconds)
	}

	func capped(to timeout: TimeInterval) -> AttachmentConnectionDeadline {
		precondition(timeout.isFinite && timeout > 0)
		let cap: AttachmentConnectionDeadline = .init(timeout: timeout)
		return .init(
			uptimeNanoseconds: min(uptimeNanoseconds, cap.uptimeNanoseconds)
		)
	}
}

enum AttachmentClientError: Error, CustomStringConvertible, Equatable {
	case invalidSocketPath(String)
	case invalidRequest(String)
	case invalidResponse(String)
	case protocolViolation(String)
	case serverRejected(code: String, message: String)
	case transport(String)
	case closed

	var description: String {
		switch self {
		case .invalidSocketPath(let path):
			return "invalid Unix socket path: \(String(reflecting: path))"
		case .invalidRequest(let message):
			return "invalid attachment request: \(message)"
		case .invalidResponse(let message):
			return "invalid attachment response: \(message)"
		case .protocolViolation(let message):
			return "attachment protocol violation: \(message)"
		case .serverRejected(let code, let message):
			return "attachment rejected (\(code)): \(message)"
		case .transport(let message):
			return "attachment transport failed: \(message)"
		case .closed:
			return "attachment is closed"
		}
	}
}

struct AttachmentUpgrade: Equatable, Sendable {
	let sessionID: String
	let replayFrom: UInt64
	let liveOffset: UInt64
	let maximumFramePayloadBytes: Int
}

struct AttachmentTerminalSize: Equatable, Sendable {
	let rows: UInt16
	let columns: UInt16
	let pixelWidth: UInt16
	let pixelHeight: UInt16
}

enum AttachmentServerFrame: Equatable, Sendable {
	case output(offset: UInt64, bytes: [UInt8])
	case replayGap(requested: UInt64, availableFrom: UInt64)
	case exit(code: UInt32)
}

private struct AttachRequest: Encodable {
	let version: UInt32
	let requestID: UInt64
	let method: String
	let sessionID: String
	let surfaceID: UInt64
	let nextOffset: UInt64

	enum CodingKeys: String, CodingKey {
		case version
		case requestID = "request_id"
		case method
		case sessionID = "session_id"
		case surfaceID = "surface_id"
		case nextOffset = "next_offset"
	}
}

private struct AttachResponse: Decodable {
	let version: UInt32?
	let requestID: UInt64?
	let status: String
	let sessionID: String?
	let upgrade: String?
	let replayFrom: UInt64?
	let liveOffset: UInt64?
	let maximumFramePayloadBytes: Int?
	let error: AttachResponseError?

	enum CodingKeys: String, CodingKey {
		case version
		case requestID = "request_id"
		case status
		case sessionID = "session_id"
		case upgrade
		case replayFrom = "replay_from"
		case liveOffset = "live_offset"
		case maximumFramePayloadBytes = "max_frame_payload_bytes"
		case error
	}
}

private struct AttachResponseError: Decodable {
	let code: String
	let message: String
}

final class AttachmentClient: @unchecked Sendable {
	private static let attachUpgrade: String = "teaser.attach.v1"
	private static let maximumJSONLineBytes: Int = 16 * 1_024
	private static let inputFrameKind: UInt8 = 0x01
	private static let resizeFrameKind: UInt8 = 0x02
	private static let outputFrameKind: UInt8 = 0x81
	private static let replayGapFrameKind: UInt8 = 0x82
	private static let exitFrameKind: UInt8 = 0x83

	let upgrade: AttachmentUpgrade

	private let readLock: NSLock = .init()
	private let writeLock: NSLock = .init()
	private let stateLock: NSLock = .init()
	private var descriptor: Int32
	private var nextUnreadOffsetValue: UInt64

	private init(
		descriptor: Int32,
		upgrade: AttachmentUpgrade,
		nextOffset: UInt64
	) {
		self.descriptor = descriptor
		self.upgrade = upgrade
		self.nextUnreadOffsetValue = nextOffset
	}

	deinit {
		close()
	}

	static func connect(
		socketPath: String,
		sessionID: String,
		surfaceID: UInt64,
		nextOffset: UInt64,
		timeoutSeconds: TimeInterval = 5,
		deadline suppliedDeadline: AttachmentConnectionDeadline? = nil,
		frameReadTimeoutSeconds: TimeInterval? = nil
	) throws -> AttachmentClient {
		guard UUID(uuidString: sessionID) != nil else {
			throw AttachmentClientError.invalidRequest(
				"session_id must be an opaque UUID"
			)
		}
		guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
			throw AttachmentClientError.invalidRequest(
				"timeoutSeconds must be finite and positive"
			)
		}
		if let frameReadTimeoutSeconds {
			guard
				frameReadTimeoutSeconds.isFinite,
				frameReadTimeoutSeconds > 0
			else {
				throw AttachmentClientError.invalidRequest(
					"frameReadTimeoutSeconds must be finite and positive when supplied"
				)
			}
		}

		let deadline: AttachmentConnectionDeadline =
			suppliedDeadline ?? .init(timeout: timeoutSeconds)
		let descriptor: Int32 = try openSocket(path: socketPath, deadline: deadline)
		var retainedDescriptor: Bool = false
		defer {
			if !retainedDescriptor {
				_ = Darwin.shutdown(descriptor, SHUT_RDWR)
				Darwin.close(descriptor)
			}
		}

		let request: AttachRequest = .init(
			version: attachmentProtocolVersion,
			requestID: surfaceID,
			method: "session.attach",
			sessionID: sessionID,
			surfaceID: surfaceID,
			nextOffset: nextOffset
		)
		var requestBytes: [UInt8] = Array(try JSONEncoder().encode(request))
		guard requestBytes.count <= maximumJSONLineBytes else {
			throw AttachmentClientError.invalidRequest(
				"encoded request exceeds \(maximumJSONLineBytes) bytes"
			)
		}
		requestBytes.append(0x0A)
		try writeAll(
			descriptor: descriptor,
			bytes: requestBytes,
			deadline: deadline
		)

		let responseBytes: [UInt8] = try readLine(
			descriptor: descriptor,
			maximumBytes: maximumJSONLineBytes,
			deadline: deadline
		)
		let response: AttachResponse
		do {
			response = try JSONDecoder().decode(
				AttachResponse.self,
				from: Data(responseBytes)
			)
		} catch {
			throw AttachmentClientError.invalidResponse(
				"response is not a valid attach envelope: \(error)"
			)
		}

		if response.status == "error" {
			guard let serverError = response.error else {
				throw AttachmentClientError.invalidResponse(
					"error response omitted error details"
				)
			}
			throw AttachmentClientError.serverRejected(
				code: serverError.code,
				message: serverError.message
			)
		}
		guard response.status == "ok" else {
			throw AttachmentClientError.invalidResponse(
				"unknown response status \(String(reflecting: response.status))"
			)
		}
		guard response.version == attachmentProtocolVersion else {
			throw AttachmentClientError.invalidResponse(
				"version did not match \(attachmentProtocolVersion)"
			)
		}
		guard response.requestID == surfaceID else {
			throw AttachmentClientError.invalidResponse(
				"request_id did not match \(surfaceID)"
			)
		}
		guard response.sessionID == sessionID else {
			throw AttachmentClientError.invalidResponse(
				"session_id did not match the requested Session"
			)
		}
		guard response.upgrade == attachUpgrade else {
			throw AttachmentClientError.invalidResponse(
				"upgrade was not \(attachUpgrade)"
			)
		}
		guard let replayFrom = response.replayFrom else {
			throw AttachmentClientError.invalidResponse(
				"successful response omitted replay_from"
			)
		}
		guard let liveOffset = response.liveOffset else {
			throw AttachmentClientError.invalidResponse(
				"successful response omitted live_offset"
			)
		}
		guard replayFrom <= liveOffset else {
			throw AttachmentClientError.invalidResponse(
				"replay_from \(replayFrom) exceeds live_offset \(liveOffset)"
			)
		}
		guard response.maximumFramePayloadBytes
			== attachmentMaximumFramePayloadBytes
		else {
			throw AttachmentClientError.invalidResponse(
				"max_frame_payload_bytes did not match "
					+ "\(attachmentMaximumFramePayloadBytes)"
			)
		}

		let upgrade: AttachmentUpgrade = .init(
			sessionID: sessionID,
			replayFrom: replayFrom,
			liveOffset: liveOffset,
			maximumFramePayloadBytes: attachmentMaximumFramePayloadBytes
		)
		try restoreBlocking(descriptor: descriptor)
		try setSocketTimeout(
			descriptor: descriptor,
			option: SO_RCVTIMEO,
			seconds: frameReadTimeoutSeconds
		)
		try setSocketTimeout(
			descriptor: descriptor,
			option: SO_SNDTIMEO,
			seconds: timeoutSeconds
		)
		guard !deadline.isExpired else {
			throw AttachmentClientError.transport(
				"attachment handshake exceeded its deadline"
			)
		}
		retainedDescriptor = true
		return AttachmentClient(
			descriptor: descriptor,
			upgrade: upgrade,
			nextOffset: nextOffset
		)
	}

	var nextUnreadOffset: UInt64 {
		stateLock.lock()
		defer { stateLock.unlock() }
		return nextUnreadOffsetValue
	}

	var isClosed: Bool {
		stateLock.lock()
		defer { stateLock.unlock() }
		return descriptor < 0
	}

	func sendInput(_ bytes: [UInt8]) throws {
		guard !bytes.isEmpty else { return }
		try performWrite {
			if bytes.count <= attachmentMaximumFramePayloadBytes {
				try writeFrame(kind: Self.inputFrameKind, payload: bytes)
				return
			}
			var offset: Int = 0
			while offset < bytes.count {
				let end: Int = min(
					offset + attachmentMaximumFramePayloadBytes,
					bytes.count
				)
				let chunk: [UInt8] = Array(bytes[offset..<end])
				try writeFrame(kind: Self.inputFrameKind, payload: chunk)
				offset = end
			}
		}
	}

	func sendResize(_ size: AttachmentTerminalSize) throws {
		var payload: [UInt8] = []
		payload.reserveCapacity(8)
		payload.appendBigEndian(size.rows)
		payload.appendBigEndian(size.columns)
		payload.appendBigEndian(size.pixelWidth)
		payload.appendBigEndian(size.pixelHeight)

		try performWrite {
			try writeFrame(kind: Self.resizeFrameKind, payload: payload)
		}
	}

	func readFrame() throws -> AttachmentServerFrame {
		readLock.lock()
		do {
			let frame: AttachmentServerFrame = try readFrameFromOpenConnection()
			readLock.unlock()
			return frame
		} catch {
			let descriptorToClose: Int32 = invalidateDescriptor()
			readLock.unlock()
			if descriptorToClose >= 0 {
				writeLock.lock()
				Darwin.close(descriptorToClose)
				writeLock.unlock()
			}
			throw error
		}
	}

	private func readFrameFromOpenConnection() throws -> AttachmentServerFrame {
		let currentDescriptor: Int32 = try openDescriptor()
		let header: [UInt8] = try Self.readExactly(
			descriptor: currentDescriptor,
			count: 5
		)
		let payloadLength: Int = Int(
			UInt32(bigEndianBytes: header[1...4])
		)
		guard payloadLength <= attachmentMaximumFramePayloadBytes else {
			throw AttachmentClientError.protocolViolation(
				"frame payload \(payloadLength) exceeds "
					+ "\(attachmentMaximumFramePayloadBytes)"
			)
		}
		let payload: [UInt8] = try Self.readExactly(
			descriptor: currentDescriptor,
			count: payloadLength
		)

		switch header[0] {
		case Self.outputFrameKind:
			guard payload.count >= 8 else {
				throw AttachmentClientError.protocolViolation(
					"output frame omitted its absolute offset"
				)
			}
			let offset: UInt64 = UInt64(bigEndianBytes: payload[0..<8])
			let bytes: [UInt8] = Array(payload.dropFirst(8))
			let expectedOffset: UInt64 = nextUnreadOffset
			guard offset == expectedOffset else {
				throw AttachmentClientError.protocolViolation(
					"output offset \(offset) is not contiguous with "
						+ "\(expectedOffset)"
				)
			}
			let (newOffset, overflow): (UInt64, Bool) = offset
				.addingReportingOverflow(UInt64(bytes.count))
			guard !overflow else {
				throw AttachmentClientError.protocolViolation(
					"output offset exceeded UInt64.max"
				)
			}
			setNextUnreadOffset(newOffset)
			return .output(offset: offset, bytes: bytes)

		case Self.replayGapFrameKind:
			guard payload.count == 16 else {
				throw AttachmentClientError.protocolViolation(
					"replay-gap payload must be 16 bytes"
				)
			}
			let requested: UInt64 = UInt64(bigEndianBytes: payload[0..<8])
			let availableFrom: UInt64 = UInt64(bigEndianBytes: payload[8..<16])
			let expectedOffset: UInt64 = nextUnreadOffset
			guard requested == expectedOffset else {
				throw AttachmentClientError.protocolViolation(
					"replay gap requested \(requested), expected \(expectedOffset)"
				)
			}
			guard availableFrom >= requested else {
				throw AttachmentClientError.protocolViolation(
					"replay gap moved backwards from \(requested) "
						+ "to \(availableFrom)"
				)
			}
			setNextUnreadOffset(availableFrom)
			return .replayGap(
				requested: requested,
				availableFrom: availableFrom
			)

		case Self.exitFrameKind:
			guard payload.count == 4 else {
				throw AttachmentClientError.protocolViolation(
					"exit payload must be 4 bytes"
				)
			}
			return .exit(code: UInt32(bigEndianBytes: payload[0..<4]))

		default:
			throw AttachmentClientError.protocolViolation(
				String(format: "unknown server frame kind 0x%02x", header[0])
			)
		}
	}

	func close() {
		let descriptorToClose: Int32 = invalidateDescriptor()
		guard descriptorToClose >= 0 else { return }
		readLock.lock()
		writeLock.lock()
		Darwin.close(descriptorToClose)
		writeLock.unlock()
		readLock.unlock()
	}

	private func performWrite(_ operation: () throws -> Void) throws {
		writeLock.lock()
		do {
			try operation()
			writeLock.unlock()
		} catch {
			let descriptorToClose: Int32 = invalidateDescriptor()
			writeLock.unlock()
			if descriptorToClose >= 0 {
				readLock.lock()
				Darwin.close(descriptorToClose)
				readLock.unlock()
			}
			throw error
		}
	}

	private func invalidateDescriptor() -> Int32 {
		stateLock.lock()
		let descriptorToClose: Int32 = descriptor
		descriptor = -1
		stateLock.unlock()
		if descriptorToClose >= 0 {
			_ = Darwin.shutdown(descriptorToClose, SHUT_RDWR)
		}
		return descriptorToClose
	}

	private func writeFrame(kind: UInt8, payload: [UInt8]) throws {
		guard payload.count <= attachmentMaximumFramePayloadBytes else {
			throw AttachmentClientError.protocolViolation(
				"outgoing payload \(payload.count) exceeds "
					+ "\(attachmentMaximumFramePayloadBytes)"
			)
		}
		guard let payloadLength = UInt32(exactly: payload.count) else {
			throw AttachmentClientError.protocolViolation(
				"outgoing payload length cannot be represented by UInt32"
			)
		}

		var frame: [UInt8] = [kind]
		frame.reserveCapacity(5 + payload.count)
		frame.appendBigEndian(payloadLength)
		frame.append(contentsOf: payload)
		try Self.writeAll(descriptor: openDescriptor(), bytes: frame)
	}

	private func openDescriptor() throws -> Int32 {
		stateLock.lock()
		defer { stateLock.unlock() }
		guard descriptor >= 0 else {
			throw AttachmentClientError.closed
		}
		return descriptor
	}

	private func setNextUnreadOffset(_ offset: UInt64) {
		stateLock.lock()
		nextUnreadOffsetValue = offset
		stateLock.unlock()
	}

	private static func openSocket(
		path: String,
		deadline: AttachmentConnectionDeadline
	) throws -> Int32 {
		let pathBytes: [UInt8] = Array(path.utf8)
		guard !pathBytes.isEmpty, !pathBytes.contains(0) else {
			throw AttachmentClientError.invalidSocketPath(path)
		}

		var address: sockaddr_un = .init()
		let pathCapacity: Int = MemoryLayout.size(ofValue: address.sun_path)
		guard pathBytes.count + 1 <= pathCapacity else {
			throw AttachmentClientError.invalidSocketPath(path)
		}

		address.sun_family = sa_family_t(AF_UNIX)
		let addressHeaderBytes: Int =
			MemoryLayout.size(ofValue: address.sun_len)
			+ MemoryLayout.size(ofValue: address.sun_family)
		let addressBytes: Int = addressHeaderBytes + pathBytes.count + 1
		guard let addressLength = UInt8(exactly: addressBytes) else {
			throw AttachmentClientError.invalidSocketPath(path)
		}
		address.sun_len = addressLength
		withUnsafeMutableBytes(of: &address.sun_path) { destination in
			for index: Int in destination.indices {
				destination[index] = 0
			}
			pathBytes.withUnsafeBytes { source in
				destination.copyBytes(from: source)
			}
		}

		let descriptor: Int32 = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else {
			throw AttachmentClientError.transport(
				"socket: \(currentErrnoDescription())"
			)
		}
		var connected: Bool = false
		defer {
			if !connected {
				Darwin.close(descriptor)
			}
		}

		var noSignal: Int32 = 1
		let noSignalStatus: Int32 = withUnsafePointer(to: &noSignal) { pointer in
			Darwin.setsockopt(
				descriptor,
				SOL_SOCKET,
				SO_NOSIGPIPE,
				pointer,
				socklen_t(MemoryLayout<Int32>.size)
			)
		}
		guard noSignalStatus == 0 else {
			throw AttachmentClientError.transport(
				"setsockopt(SO_NOSIGPIPE): \(currentErrnoDescription())"
			)
		}

		let originalFlags: Int32 = Darwin.fcntl(descriptor, F_GETFL)
		guard originalFlags >= 0 else {
			throw AttachmentClientError.transport(
				"fcntl(F_GETFL): \(currentErrnoDescription())"
			)
		}
		guard Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
			throw AttachmentClientError.transport(
				"fcntl(F_SETFL, O_NONBLOCK): \(currentErrnoDescription())"
			)
		}

		let connectStatus: Int32 = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(
				to: sockaddr.self,
				capacity: 1
			) { socketAddress in
				Darwin.connect(
					descriptor,
					socketAddress,
					socklen_t(addressLength)
				)
				}
			}
		if connectStatus != 0 {
			guard
				errno == EINPROGRESS
					|| errno == EALREADY
					|| errno == EWOULDBLOCK
			else {
				throw AttachmentClientError.transport(
					"connect \(String(reflecting: path)): "
						+ currentErrnoDescription()
				)
			}
			try waitForConnection(descriptor: descriptor, deadline: deadline)
		}

		connected = true
		return descriptor
	}

	private static func waitForConnection(
		descriptor: Int32,
		deadline: AttachmentConnectionDeadline
	) throws {
		while true {
			let remaining: TimeInterval = deadline.remainingTimeInterval
			guard remaining > 0 else {
				throw AttachmentClientError.transport(
					"connect exceeded its deadline"
				)
			}
			let milliseconds: Int32 = Int32(
				min(
					Double(Int32.max),
					max(1, ceil(remaining * 1_000))
				)
			)
			var descriptorEvent: pollfd = .init(
				fd: descriptor,
				events: Int16(POLLOUT),
				revents: 0
			)
			let status: Int32 = Darwin.poll(&descriptorEvent, 1, milliseconds)
			if status == 0 {
				throw AttachmentClientError.transport(
					"connect exceeded its deadline"
				)
			}
			if status < 0 {
				if errno == EINTR {
					continue
				}
				throw AttachmentClientError.transport(
					"poll(connect): \(currentErrnoDescription())"
				)
			}

			var socketError: Int32 = 0
			var socketErrorLength: socklen_t = .init(
				MemoryLayout<Int32>.size
			)
			let result: Int32 = Darwin.getsockopt(
				descriptor,
				SOL_SOCKET,
				SO_ERROR,
				&socketError,
				&socketErrorLength
			)
			guard result == 0 else {
				throw AttachmentClientError.transport(
					"getsockopt(SO_ERROR): \(currentErrnoDescription())"
				)
			}
			guard socketError == 0 else {
				throw AttachmentClientError.transport(
					"connect: \(String(cString: strerror(socketError)))"
				)
			}
			return
		}
	}

	private static func restoreBlocking(descriptor: Int32) throws {
		let flags: Int32 = Darwin.fcntl(descriptor, F_GETFL)
		guard flags >= 0 else {
			throw AttachmentClientError.transport(
				"fcntl(F_GETFL): \(currentErrnoDescription())"
			)
		}
		guard Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
			throw AttachmentClientError.transport(
				"fcntl(F_SETFL, blocking): \(currentErrnoDescription())"
			)
		}
	}

	private static func waitForIO(
		descriptor: Int32,
		events: Int16,
		deadline: AttachmentConnectionDeadline,
		operation: String
	) throws {
		while true {
			let remaining: TimeInterval = deadline.remainingTimeInterval
			guard remaining > 0 else {
				throw AttachmentClientError.transport(
					"\(operation) exceeded its deadline"
				)
			}
			let milliseconds: Int32 = Int32(
				min(
					Double(Int32.max),
					max(1, ceil(remaining * 1_000))
				)
			)
			var descriptorEvent: pollfd = .init(
				fd: descriptor,
				events: events,
				revents: 0
			)
			let status: Int32 = Darwin.poll(&descriptorEvent, 1, milliseconds)
			if status > 0 {
				return
			}
			if status == 0 {
				throw AttachmentClientError.transport(
					"\(operation) exceeded its deadline"
				)
			}
			if errno == EINTR {
				continue
			}
			throw AttachmentClientError.transport(
				"poll(\(operation)): \(currentErrnoDescription())"
			)
		}
	}

	private static func setSocketTimeout(
		descriptor: Int32,
		option: Int32,
		seconds: TimeInterval?
	) throws {
		let interval: TimeInterval = seconds ?? 0
		let wholeSeconds: Int = Int(interval.rounded(.down))
		let fractionalMicroseconds: Int = Int(
			((interval - TimeInterval(wholeSeconds)) * 1_000_000).rounded(.up)
		)
		let normalizedSeconds: Int =
			wholeSeconds + fractionalMicroseconds / 1_000_000
		let normalizedMicroseconds: Int =
			fractionalMicroseconds % 1_000_000
		var timeout: timeval = .init(
			tv_sec: normalizedSeconds,
			tv_usec: Int32(normalizedMicroseconds)
		)
		let status: Int32 = withUnsafePointer(to: &timeout) { pointer in
			Darwin.setsockopt(
				descriptor,
				SOL_SOCKET,
				option,
				pointer,
				socklen_t(MemoryLayout<timeval>.size)
			)
		}
		guard status == 0 else {
			throw AttachmentClientError.transport(
				"setsockopt(timeout): \(currentErrnoDescription())"
			)
		}
	}

	private static func readLine(
		descriptor: Int32,
		maximumBytes: Int,
		deadline: AttachmentConnectionDeadline
	) throws -> [UInt8] {
		var line: [UInt8] = []
		line.reserveCapacity(256)
		while line.count <= maximumBytes {
			let byte: [UInt8] = try readExactly(
				descriptor: descriptor,
				count: 1,
				deadline: deadline
			)
			if byte[0] == 0x0A {
				if line.last == 0x0D {
					line.removeLast()
				}
				return line
			}
			line.append(byte[0])
		}
		throw AttachmentClientError.invalidResponse(
			"JSON response exceeds \(maximumBytes) bytes"
		)
	}

	private static func readExactly(
		descriptor: Int32,
		count: Int,
		deadline: AttachmentConnectionDeadline? = nil
	) throws -> [UInt8] {
		guard count >= 0 else {
			throw AttachmentClientError.protocolViolation(
				"negative read length"
			)
		}
		guard count > 0 else { return [] }

		var bytes: [UInt8] = .init(repeating: 0, count: count)
		var received: Int = 0
		while received < count {
			if let deadline, deadline.isExpired {
				throw AttachmentClientError.transport(
					"read exceeded its deadline"
				)
			}
			let result: Int = bytes.withUnsafeMutableBytes { buffer in
				guard let baseAddress = buffer.baseAddress else { return 0 }
				return Darwin.read(
					descriptor,
					baseAddress.advanced(by: received),
					count - received
				)
			}
			if result > 0 {
				received += result
				continue
			}
			if result == 0 {
				throw AttachmentClientError.closed
			}
			if errno == EINTR {
				continue
			}
			if errno == EAGAIN || errno == EWOULDBLOCK, let deadline {
				try waitForIO(
					descriptor: descriptor,
					events: Int16(POLLIN),
					deadline: deadline,
					operation: "read"
				)
				continue
			}
			throw AttachmentClientError.transport(
				"read: \(currentErrnoDescription())"
			)
		}
		return bytes
	}

	private static func writeAll(
		descriptor: Int32,
		bytes: [UInt8],
		deadline: AttachmentConnectionDeadline? = nil
	) throws {
		guard !bytes.isEmpty else { return }
		var written: Int = 0
		while written < bytes.count {
			if let deadline, deadline.isExpired {
				throw AttachmentClientError.transport(
					"write exceeded its deadline"
				)
			}
			let result: Int = bytes.withUnsafeBytes { buffer in
				guard let baseAddress = buffer.baseAddress else { return 0 }
				return Darwin.write(
					descriptor,
					baseAddress.advanced(by: written),
					bytes.count - written
				)
			}
			if result > 0 {
				written += result
				continue
			}
			if result == 0 {
				throw AttachmentClientError.transport(
					"write made no progress"
				)
			}
			if errno == EINTR {
				continue
			}
			if errno == EAGAIN || errno == EWOULDBLOCK, let deadline {
				try waitForIO(
					descriptor: descriptor,
					events: Int16(POLLOUT),
					deadline: deadline,
					operation: "write"
				)
				continue
			}
			throw AttachmentClientError.transport(
				"write: \(currentErrnoDescription())"
			)
		}
	}
}

private func currentErrnoDescription() -> String {
	let code: Int32 = errno
	guard let message = strerror(code) else {
		return "errno \(code)"
	}
	return "errno \(code) (\(String(cString: message)))"
}

private extension Array where Element == UInt8 {
	mutating func appendBigEndian(_ value: UInt16) {
		append(UInt8(truncatingIfNeeded: value >> 8))
		append(UInt8(truncatingIfNeeded: value))
	}

	mutating func appendBigEndian(_ value: UInt32) {
		append(UInt8(truncatingIfNeeded: value >> 24))
		append(UInt8(truncatingIfNeeded: value >> 16))
		append(UInt8(truncatingIfNeeded: value >> 8))
		append(UInt8(truncatingIfNeeded: value))
	}
}

private extension UInt32 {
	init<Bytes: Collection>(bigEndianBytes bytes: Bytes)
	where Bytes.Element == UInt8 {
		precondition(bytes.count == 4)
		self = bytes.reduce(0) { partial, byte in
			(partial << 8) | UInt32(byte)
		}
	}
}

private extension UInt64 {
	init<Bytes: Collection>(bigEndianBytes bytes: Bytes)
	where Bytes.Element == UInt8 {
		precondition(bytes.count == 8)
		self = bytes.reduce(0) { partial, byte in
			(partial << 8) | UInt64(byte)
		}
	}
}
