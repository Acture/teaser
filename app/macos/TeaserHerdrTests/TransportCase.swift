import Darwin
import Foundation
@testable import TeaserKit

/// Uses an actual disposable Unix stream peer, not a Herdr process or personal
/// socket. Exercises product open/send/read/framing/EOF behavior end to end.
@MainActor
func transportCase() async throws {
	let path: String = "/tmp/teaser-herdr-\(UUID().uuidString).sock"
	let listener: Int32 = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
	try expect(listener >= 0, "listener socket")
	defer { Darwin.close(listener); Darwin.unlink(path) }
	var address: sockaddr_un = .init()
	address.sun_family = sa_family_t(AF_UNIX)
	address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
	withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
	let result: Int32 = withUnsafePointer(to: &address) { pointer in
		pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
			Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
		}
	}
	try expect(result == 0 && Darwin.listen(listener, 1) == 0, "bind/listen disposable socket")
	try expect(fcntl(listener, F_SETFL, O_NONBLOCK) == 0, "nonblocking listener")
	let transport: UnixJSONTransport = .init()
	defer { transport.close() }
	var frames: [Data] = []
	var closed: Bool = false
	transport.onFrame = { frames.append($0) }
	transport.onClose = { _ in closed = true }
	try transport.open(path: path)
	var peer: Int32 = -1
	for _: Int in 0..<100 {
		peer = Darwin.accept(listener, nil, nil)
		if peer >= 0 { break }
		try await Task.sleep(for: .milliseconds(10))
	}
	try expect(peer >= 0, "transport connected")
	defer { if peer >= 0 { Darwin.close(peer) } }
	try expect(fcntl(peer, F_SETFL, O_NONBLOCK) == 0, "nonblocking peer")
	try transport.send(Data("{\"request\":1}".utf8))
	var bytes: [UInt8] = .init(repeating: 0, count: 256)
	var count: Int = -1
	for _: Int in 0..<100 {
		count = Darwin.read(peer, &bytes, bytes.count)
		if count > 0 { break }
		try await Task.sleep(for: .milliseconds(10))
	}
	try expect(count > 0 && String(decoding: bytes.prefix(max(0, count)), as: UTF8.self) == "{\"request\":1}\n", "actual outbound NDJSON")
	let first: Data = Data("{".utf8)
	try expect(first.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == 1, "first fragment")
	try await Task.sleep(for: .milliseconds(30))
	try expect(frames.isEmpty, "partial frame withheld")
	let second: Data = Data("}\n{\"event\":1}\n".utf8)
	try expect(second.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == second.count, "second fragment")
	for _: Int in 0..<100 {
		if frames.count == 2 { break }
		try await Task.sleep(for: .milliseconds(10))
	}
	try expect(frames == [Data("{}".utf8), Data("{\"event\":1}".utf8)], "actual inbound fragmentation")
	do { try transport.send(Data(repeating: 65, count: 1_048_577)); throw TestFailure.assertion("oversized send accepted") }
	catch is HerdrError {}
	Darwin.close(peer); peer = -1
	for _: Int in 0..<100 {
		if closed { break }
		try await Task.sleep(for: .milliseconds(10))
	}
	try expect(closed, "EOF closes actual transport")
}
