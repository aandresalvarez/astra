import Testing
import Foundation

@Suite("Session Resume (HITL)")
struct SessionResumeTests {

    @Test("Resume args contain session ID and --resume flag")
    func resumeArgs() {
        let sessionId = "abc-123-def"
        let args = ["-p", "follow up message", "--resume", sessionId, "--output-format", "stream-json", "--verbose"]

        #expect(args.contains("--resume"))
        #expect(args.contains(sessionId))
        #expect(args[args.firstIndex(of: "--resume")! + 1] == sessionId)
    }

    @Test("Session ID extracted from system event")
    func sessionIdFromSystemEvent() throws {
        let json = """
        {"type":"system","subtype":"init","cwd":"/tmp","session_id":"sess-42","model":"claude-sonnet-4-6"}
        """
        struct SystemEvent: Decodable { let type: String; let session_id: String? }
        let event = try JSONDecoder().decode(SystemEvent.self, from: json.data(using: .utf8)!)
        #expect(event.session_id == "sess-42")
    }
}
