import Testing
@testable import ASTRA
import ASTRAGitContracts

@Suite("Git Status Parser Integration")
struct GitStatusParserIntegrationTests {
    @Test("GitService status parser entry points stay compatible")
    func gitServiceStatusParserWrappersDelegateToParser() {
        let output = " M file.swift\n"
        let outputZ = "?? new.swift\0"

        #expect(GitService.parseStatusPorcelain(output) == GitStatusParser.parsePorcelain(output))
        #expect(GitService.parseStatusPorcelainZ(outputZ) == GitStatusParser.parsePorcelainZ(outputZ))
    }
}
