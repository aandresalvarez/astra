import Foundation
import Testing
@testable import ASTRA

@Suite("Google Docs Document API")
struct GoogleDocsDocumentAPITests {
    @Test("Document ID is parsed from editor URL")
    func documentIDFromEditorURL() {
        let url = "https://docs.google.com/document/d/1-hVE5IbIgbo4ULcShvLthl700sT3_e0SGEaF505c3vc/edit?tab=t.0"
        #expect(GoogleDocsDocumentAPI.documentID(from: url) == "1-hVE5IbIgbo4ULcShvLthl700sT3_e0SGEaF505c3vc")
        #expect(GoogleDocsDocumentAPI.documentID(from: "https://drive.google.com/drive/home") == nil)
    }

    @Test("Document text extraction joins paragraph text runs")
    func documentTextExtractionJoinsParagraphTextRuns() throws {
        let object: [String: Any] = [
            "title": "Alvaro1 t",
            "body": [
                "content": [
                    [
                        "startIndex": 1,
                        "endIndex": 7,
                        "paragraph": [
                            "elements": [
                                [
                                    "startIndex": 1,
                                    "endIndex": 4,
                                    "textRun": ["content": "Hel"]
                                ],
                                [
                                    "startIndex": 4,
                                    "endIndex": 7,
                                    "textRun": ["content": "lo\n"]
                                ]
                            ]
                        ]
                    ],
                    [
                        "startIndex": 7,
                        "endIndex": 13,
                        "paragraph": [
                            "elements": [
                                [
                                    "startIndex": 7,
                                    "endIndex": 13,
                                    "textRun": ["content": "World\n"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let snapshot = try #require(GoogleDocsDocumentAPI.extractDocumentSnapshot(documentID: "doc123", object: object))

        #expect(snapshot.documentID == "doc123")
        #expect(snapshot.title == "Alvaro1 t")
        #expect(snapshot.text == "Hello\nWorld\n")
        #expect(snapshot.endIndex == 13)
    }
}
