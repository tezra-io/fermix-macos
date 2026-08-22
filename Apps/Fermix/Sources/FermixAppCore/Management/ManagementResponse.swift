import Foundation

/// Decoding of the response envelope.
///
/// A response carries **exactly one** of `result` or `error`. Both or neither
/// is a malformed envelope.
///
/// The envelope is read in two passes on purpose. The first reads only the
/// request id and which branch is present; the result is decoded *after* the id
/// has been matched. A frame that belongs to another request must never be
/// interpreted as this one's answer, and a single pass would report whatever
/// that other frame's shape happened to violate instead of the correlation
/// failure that actually occurred.
enum ManagementResponse {
    private enum EnvelopeKeys: String, CodingKey {
        case requestId = "request_id"
        case result, error
    }

    /// Pass one: the id, the branch, and the error if that is the branch.
    private struct Preamble: Decodable {
        let requestId: String?
        let carriesResult: Bool
        let failure: ManagementFailure?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: EnvelopeKeys.self)
            requestId = try container.decodeIfPresent(String.self, forKey: .requestId)

            carriesResult = try Self.carries(.result, in: container)
            let carriesError = try Self.carries(.error, in: container)
            guard carriesResult != carriesError else {
                throw ManagementError.malformedEnvelope(
                    carriesResult ? .resultAndErrorPresent : .neitherResultNorError
                )
            }

            failure = carriesError
                ? try container.decode(ManagementFailure.self, forKey: .error)
                : nil
        }

        private static func carries(
            _ key: EnvelopeKeys,
            in container: KeyedDecodingContainer<EnvelopeKeys>
        ) throws -> Bool {
            guard container.contains(key) else { return false }
            return try !container.decodeNil(forKey: key)
        }
    }

    /// Pass two: the result, in the shape the correlated method owes. A
    /// response carries no method, so the shape comes from the request it
    /// answers and is never guessed from the envelope.
    private struct ResultEnvelope<Result: Decodable>: Decodable {
        let result: Result

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: EnvelopeKeys.self)
            result = try container.decode(Result.self, forKey: .result)
        }
    }

    static func decode<Result: Decodable>(
        _ payload: Data,
        expecting identifier: String,
        method: ManagementMethod,
        as type: Result.Type
    ) throws -> Result {
        let decoder = JSONDecoder()
        let preamble = try read(
            Preamble.self,
            from: payload,
            decoder: decoder,
            method: method
        )

        if let failure = preamble.failure {
            // A null id is legitimate here: the daemon could not recover an id
            // from the request at all. Reporting that as a correlation failure
            // would hide the defect the daemon is naming.
            try checkCorrelation(preamble.requestId, expecting: identifier, allowingNull: true)
            throw ManagementError.daemon(failure)
        }

        try checkCorrelation(preamble.requestId, expecting: identifier, allowingNull: false)
        let envelope: ResultEnvelope<Result> = try read(
            ResultEnvelope<Result>.self,
            from: payload,
            decoder: decoder,
            method: method
        )
        return envelope.result
    }

    private static func read<Value: Decodable>(
        _ type: Value.Type,
        from payload: Data,
        decoder: JSONDecoder,
        method: ManagementMethod
    ) throws -> Value {
        do {
            return try decoder.decode(type, from: payload)
        } catch let error as ManagementError {
            throw error
        } catch let error as DecodingError {
            throw translate(error, method: method)
        } catch {
            throw ManagementError.malformedEnvelope(.undecodableJSON)
        }
    }

    private static func checkCorrelation(
        _ received: String?,
        expecting identifier: String,
        allowingNull: Bool
    ) throws {
        guard let received else {
            guard allowingNull else {
                throw ManagementError.malformedEnvelope(.requestIdentifierMissing)
            }
            return
        }
        guard received == identifier else {
            throw ManagementError.correlationMismatch(expected: identifier, received: received)
        }
    }

    /// Turn a decoding failure into the contract's own vocabulary: which field
    /// of which method's result did not arrive as published.
    private static func translate(
        _ error: DecodingError,
        method: ManagementMethod
    ) -> ManagementError {
        switch error {
        case .keyNotFound(let key, let context):
            return shapeMismatch(context.codingPath + [key], method: method)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return shapeMismatch(context.codingPath, method: method)
        case .dataCorrupted(let context):
            guard !context.codingPath.isEmpty else {
                return .malformedEnvelope(.undecodableJSON)
            }
            return shapeMismatch(context.codingPath, method: method)
        @unknown default:
            return .malformedEnvelope(.undecodableJSON)
        }
    }

    private static func shapeMismatch(
        _ path: [CodingKey],
        method: ManagementMethod
    ) -> ManagementError {
        let field = path
            .map(\.stringValue)
            .drop { $0 == "result" }
            .joined(separator: ".")
        return .malformedEnvelope(.resultShapeMismatch(method: method, field: field))
    }
}
