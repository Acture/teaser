import Foundation

/// Rust resource strings use UTF-8 identity. Swift String equality instead
/// treats canonically equivalent spellings as equal, which can merge documents.
struct NotesDocumentID: Hashable {
	let bytes: Data
	init(_ value: String) { bytes = Data(value.utf8) }
	var wireValue: String { String(decoding: bytes, as: UTF8.self) }
}

/// Archives use records so raw document references stay readable without JSON
/// object keys (whose Swift String representation would alias NFC/NFD IDs).
struct OrganizationNotes: Codable {
	private struct Record: Codable {
		let document_id: String
		let text: String
	}
	private var documents: [NotesDocumentID: String] = [:]

	init() {}

	subscript(documentID: String) -> String? {
		get { documents[NotesDocumentID(documentID)] }
		set { documents[NotesDocumentID(documentID)] = newValue }
	}

	init(from decoder: any Decoder) throws {
		let container: any SingleValueDecodingContainer = try decoder.singleValueContainer()
		let records: [Record] = try container.decode([Record].self)
		for record: Record in records {
			guard documents.updateValue(record.text, forKey: NotesDocumentID(record.document_id)) == nil else {
				throw DecodingError.dataCorruptedError(in: container, debugDescription: "Duplicate Notes document ID")
			}
		}
	}

	func encode(to encoder: any Encoder) throws {
		var container: any SingleValueEncodingContainer = encoder.singleValueContainer()
		let records: [Record] = documents.sorted {
			$0.key.bytes.lexicographicallyPrecedes($1.key.bytes)
		}.map { Record(document_id: $0.key.wireValue, text: $0.value) }
		try container.encode(records)
	}
}
