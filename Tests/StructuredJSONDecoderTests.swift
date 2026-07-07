import Foundation
import Testing
import ASTRAPersistence
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Structured JSON decoder")
struct StructuredJSONDecoderTests {
    private struct Payload: Decodable, Equatable {
        var name: String
        var count: Int
    }

    @Test("decode reports success diagnostics")
    func decodeReportsSuccessDiagnostics() throws {
        let result = StructuredJSONDecoder.decode(
            Payload.self,
            from: #"{"name":"demo","count":3}"#
        )

        let value = try #require(result.value)
        #expect(value == Payload(name: "demo", count: 3))
        #expect(result.didDecode)
        #expect(result.diagnostic.status == .decoded)
        #expect(result.diagnostic.typeName == "Payload")
        #expect(result.diagnostic.byteCount > 0)
        #expect(result.diagnostic.codingPath == nil)
        #expect(result.diagnostic.errorDescription == nil)
    }

    @Test("decode reports empty input without throwing away type context")
    func decodeReportsEmptyInput() {
        let result = StructuredJSONDecoder.decode(Payload.self, from: " \n\t ")

        #expect(result.value == nil)
        #expect(!result.didDecode)
        #expect(result.diagnostic.status == .emptyInput)
        #expect(result.diagnostic.typeName == "Payload")
        #expect(result.diagnostic.byteCount == 0)
        #expect(result.diagnostic.errorDescription?.contains("empty") == true)
    }

    @Test("decode reports malformed payload coding path")
    func decodeReportsMalformedPayloadCodingPath() {
        let result = StructuredJSONDecoder.decode(
            Payload.self,
            from: #"{"name":"demo","count":"three"}"#
        )

        #expect(result.value == nil)
        #expect(!result.didDecode)
        #expect(result.diagnostic.status == .decodeFailed)
        #expect(result.diagnostic.codingPath == "count")
        #expect(result.diagnostic.errorDescription?.contains("Type mismatch") == true)
    }
}
