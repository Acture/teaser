import Darwin
import Foundation

struct NDJSONFramer {
	static let maximumFrame: Int = 1_048_576 + 4096 // snapshot plus envelope
	private var buffer: Data = .init()
	mutating func append(_ data: Data) throws -> [Data] {
		var frames: [Data] = []
		for byte: UInt8 in data {
			if byte == 10 {
				guard !buffer.isEmpty else { throw HerdrError.invalid("Empty JSON frame") }
				frames.append(buffer); buffer = .init()
				guard frames.count <= 64 else { throw HerdrError.invalid("Too many queued JSON frames") }
			} else {
				guard buffer.count < Self.maximumFrame else { throw HerdrError.invalid("JSON frame exceeds limit") }
				buffer.append(byte)
			}
		}
		return frames
	}
}

@MainActor
protocol HerdrTransport: AnyObject {
	var endpointIdentity: String? { get }
	var onFrame: ((Data) -> Void)? { get set }
	var onClose: ((Error) -> Void)? { get set }
	func open(path: String) throws
	func send(_ data: Data) throws
	func close()
}

extension HerdrTransport {
	var endpointIdentity: String? { nil }
}

/// A nonblocking Unix stream. Each tick has bounded read/write work and yields
/// to the main actor; no blocking connect/read, desktop API or daemon fallback.
@MainActor
final class UnixJSONTransport: HerdrTransport {
	var onFrame: ((Data) -> Void)?
	var onClose: ((Error) -> Void)?
	private var descriptor: Int32 = -1
	private var pump: Task<Void, Never>?
	private var framer: NDJSONFramer = .init()
	private var outgoing: Data = .init()
	private var connecting: Bool = false
	private(set) var endpointIdentity: String?

	func open(path: String) throws {
		close()
		var metadata: stat = .init()
		let resolvedPath: String = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
		guard lstat(resolvedPath, &metadata) == 0 else { throw systemError() }
		endpointIdentity = "\(metadata.st_dev):\(metadata.st_ino)"
		var address: sockaddr_un = .init()
		let bytes: [UInt8] = Array(path.utf8)
		guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
			throw HerdrError.invalid("Choose an absolute Unix socket path shorter than 104 bytes")
		}
		address.sun_family = sa_family_t(AF_UNIX)
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { destination in
			destination.copyBytes(from: bytes + [0])
		}
		descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw systemError() }
		guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
			let error: Error = systemError(); close(); throw error
		}
		var one: Int32 = 1
		guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
			let error: Error = systemError(); close(); throw error
		}
		let result: Int32 = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		connecting = result != 0
		if result != 0 && errno != EINPROGRESS {
			let error: Error = systemError(); close(); throw error
		}
		pump = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				guard let self, self.descriptor >= 0 else { return }
				do { try self.tick() }
				catch { self.close(); self.onClose?(error); return }
				do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
			}
		}
	}
	func send(_ data: Data) throws {
		guard descriptor >= 0 else { throw HerdrError.disconnected }
		guard data.count <= 1_048_576, !data.contains(10), outgoing.count + data.count + 1 <= 2_097_152 else {
			throw HerdrError.invalid("JSON request or outgoing queue exceeds limit")
		}
		outgoing.append(data); outgoing.append(10)
	}
	func close() {
		pump?.cancel(); pump = nil
		if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
		outgoing.removeAll(); framer = .init(); connecting = false
		endpointIdentity = nil
	}
	private func tick() throws {
		if connecting {
			var item: pollfd = .init(fd: descriptor, events: Int16(POLLOUT), revents: 0)
			guard Darwin.poll(&item, 1, 0) > 0 else { return }
			var error: Int32 = 0
			var size: socklen_t = socklen_t(MemoryLayout<Int32>.size)
			guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
				throw HerdrError.invalid("Unix socket connection failed (\(error))")
			}
			connecting = false
		}
		if !outgoing.isEmpty {
			let written: Int = outgoing.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, min($0.count, 65_536)) }
			if written > 0 { outgoing.removeFirst(written) }
			else if written < 0 && errno != EAGAIN && errno != EINTR { throw systemError() }
		}
		var bytes: [UInt8] = .init(repeating: 0, count: 16_384)
		for _: Int in 0..<8 {
			let count: Int = Darwin.read(descriptor, &bytes, bytes.count)
			if count == 0 { throw HerdrError.disconnected }
			if count < 0 {
				if errno == EAGAIN || errno == EINTR { return }
				throw systemError()
			}
			let frames: [Data] = try framer.append(Data(bytes.prefix(count)))
			for frame: Data in frames {
				onFrame?(frame)
				if descriptor < 0 { return }
			}
		}
	}
	private func systemError() -> HerdrError {
		.invalid("Unix socket: \(String(cString: strerror(errno)))")
	}
}
