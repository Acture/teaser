import Foundation

@MainActor
final class OrganizationClient {
	enum State: Equatable { case disconnected, subscribing, loading, ready, failed(String) }
	private enum RequestKind { case subscribe, snapshot, apply }
	private struct Pending { let kind: RequestKind; let deadline: ContinuousClock.Instant }
	private struct Subscription: Encodable { let type: String }
	private struct Parameters: Encodable {
		var subscriptions: [Subscription]?
		var expected_revision: UInt64?
		var commands: [OrganizationCommand]?
	}
	private struct Request: Encodable { let id: String; let method: String; let params: Parameters }
	private struct Envelope: Decodable {
		struct Result: Decodable { let type: String; let snapshot: OrganizationSnapshot? }
		struct Failure: Decodable { let code: String; let message: String }
		let id: String?
		let result: Result?
		let error: Failure?
		let event: String?
		let data: Result?
	}
	private let factory: () -> any HerdrTransport
	private let timeout: Duration
	private var transport: (any HerdrTransport)?
	private var requests: [String: any HerdrTransport] = [:]
	private var pending: [String: Pending] = [:]
	private var buffered: [OrganizationSnapshot] = []
	private var timer: Task<Void, Never>?
	private(set) var generation: UUID = .init()
	private(set) var state: State = .disconnected
	private(set) var snapshot: OrganizationSnapshot?
	private(set) var endpoint: String = ""
	private(set) var errorMessage: String?
	var onChange: (() -> Void)?
	var onSnapshot: ((OrganizationSnapshot) throws -> Void)?
	var canApply: Bool { state == .ready && !pending.values.contains { $0.kind == .apply } }

	init(timeout: Duration = .seconds(5), factory: @escaping () -> any HerdrTransport = { UnixJSONTransport() }) {
		self.timeout = timeout; self.factory = factory
	}
	func connect(path: String) {
		disconnect()
		generation = .init(); endpoint = path; snapshot = nil; errorMessage = nil
		let token: UUID = generation
		let connection: any HerdrTransport = factory()
		transport = connection
		connection.onFrame = { [weak self] frame in
			guard let self, self.generation == token else { return }
			do { try self.receive(frame) } catch { self.fail(error) }
		}
		connection.onClose = { [weak self] error in
			guard let self, self.generation == token else { return }
			self.fail(error)
		}
		do {
			state = .subscribing
			try connection.open(path: path)
			try request(.subscribe, method: "events.subscribe", params: .init(subscriptions: [.init(type: "teaser.organization.updated")]))
			timer = Task { @MainActor [weak self] in
				while !Task.isCancelled {
					do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
					guard let self, self.generation == token else { return }
					self.checkTimeouts()
				}
			}
		} catch { fail(error) }
		onChange?()
	}
	func disconnect() {
		generation = .init()
		transport?.onFrame = nil; transport?.onClose = nil; transport?.close(); transport = nil
		for connection: any HerdrTransport in requests.values {
			connection.onFrame = nil; connection.onClose = nil; connection.close()
		}
		requests.removeAll()
		timer?.cancel(); timer = nil
		if pending.values.contains(where: { $0.kind == .apply }) { errorMessage = HerdrError.disconnected.localizedDescription }
		pending.removeAll(); buffered.removeAll(); state = .disconnected
		onChange?()
	}
	func apply(_ commands: [OrganizationCommand]) {
		guard canApply, let snapshot else {
			errorMessage = "Organization is disconnected, unsupported, stale, or a command is pending."
			onChange?(); return
		}
		do {
			guard !commands.isEmpty, commands.count <= 256 else { throw HerdrError.invalid("Batch must contain 1–256 commands") }
			try request(.apply, method: "teaser.organization.apply", params: .init(expected_revision: snapshot.revision, commands: commands))
			errorMessage = nil
		} catch { fail(error) }
		onChange?()
	}
	func checkTimeouts(now: ContinuousClock.Instant = .now) {
		if pending.values.contains(where: { $0.deadline <= now }) { fail(HerdrError.timeout) }
	}
	private func request(_ kind: RequestKind, method: String, params: Parameters = .init()) throws {
		guard pending.count < 8, let transport else { throw HerdrError.invalid("Pending request limit reached") }
		let id: String = UUID().uuidString
		let connection: any HerdrTransport
		if kind == .subscribe { connection = transport }
		else {
			connection = factory()
			let token: UUID = generation
			connection.onFrame = { [weak self] frame in
				guard let self, self.generation == token, self.pending[id] != nil else { return }
				do { try self.receive(frame) } catch { self.fail(error) }
			}
			connection.onClose = { [weak self] error in
				guard let self, self.generation == token, self.pending[id] != nil else { return }
				self.fail(error)
			}
			requests[id] = connection
			try connection.open(path: endpoint)
			guard connection.endpointIdentity == transport.endpointIdentity else {
				throw HerdrError.invalid("Socket endpoint was replaced. Reconnect to create a new local scope.")
			}
		}
		pending[id] = .init(kind: kind, deadline: .now.advanced(by: timeout))
		try connection.send(JSONEncoder().encode(Request(id: id, method: method, params: params)))
	}
	private func resnapshot() throws {
		state = .loading
		if !pending.values.contains(where: { $0.kind == .snapshot }) {
			try request(.snapshot, method: "teaser.organization.snapshot")
		}
	}
	private func receive(_ frame: Data) throws {
		guard frame.count <= NDJSONFramer.maximumFrame else { throw HerdrError.invalid("Oversized response") }
		let envelope: Envelope = try JSONDecoder().decode(Envelope.self, from: frame)
		if let event: String = envelope.event {
			guard event == "teaser.organization.updated", envelope.id == nil,
				envelope.data?.type == "teaser_organization_updated", let update: OrganizationSnapshot = envelope.data?.snapshot
			else { throw HerdrError.invalid("Malformed organization event") }
			try update.validate()
			if state != .ready {
				guard buffered.count < 32 else { throw HerdrError.invalid("Organization event buffer exceeded") }
				buffered.append(update)
			} else if update.revision > (snapshot?.revision ?? 0) {
				if let revision: UInt64 = snapshot?.revision, revision != UInt64.max, update.revision == revision + 1 {
					try accept(update)
				} else { buffered.append(update); try resnapshot() }
			}
		} else {
			guard let id: String = envelope.id else { throw HerdrError.invalid("Response has no request ID") }
			guard let item: Pending = pending.removeValue(forKey: id) else { return } // old/duplicate reply
			if let connection: any HerdrTransport = requests.removeValue(forKey: id) {
				connection.onFrame = nil; connection.onClose = nil; connection.close()
			}
			if let failure: Envelope.Failure = envelope.error {
				let error: HerdrError = .remote(failure.code, failure.message)
				if item.kind == .apply {
					errorMessage = error.localizedDescription
					if failure.code == "revision_conflict" { try resnapshot() }
				} else { throw HerdrError.invalid("Unsupported organization endpoint or subscription: \(error.localizedDescription)") }
			} else if item.kind == .subscribe {
				guard envelope.result?.type == "subscription_started" else { throw HerdrError.invalid("Invalid subscription acknowledgment") }
				try resnapshot()
			} else {
				guard envelope.result?.type == "teaser_organization_snapshot", let update: OrganizationSnapshot = envelope.result?.snapshot
				else { throw HerdrError.invalid("Invalid organization response") }
				try update.validate()
				if item.kind == .snapshot {
					try accept(update)
					let events: [OrganizationSnapshot] = buffered.sorted(by: { $0.revision < $1.revision })
					buffered.removeAll(); state = .ready
					for value: OrganizationSnapshot in events {
						guard let current: UInt64 = snapshot?.revision, value.revision > current else { continue }
						if current != UInt64.max && value.revision == current + 1 { try accept(value) }
						else { buffered.append(value); try resnapshot() }
					}
				} else { try accept(update) }
			}
		}
		onChange?()
	}
	private func accept(_ update: OrganizationSnapshot) throws {
		guard snapshot == nil || update.revision > snapshot!.revision else { return }
		try onSnapshot?(update)
		snapshot = update
	}
	private func fail(_ error: Error) {
		disconnect(); errorMessage = error.localizedDescription; state = .failed(error.localizedDescription); onChange?()
	}
}
