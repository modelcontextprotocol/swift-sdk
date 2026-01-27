import Testing

@testable import MCP

@Test("ProgressNotification parameters validation")
func testProgressNotification() throws {
    let params = ProgressNotification.Parameters(
        progressToken: "some-token",
        progress: 20,
        total: 25,
        message: "beep boop bop"
    )
    #expect(params.progressToken == "some-token")
    #expect(params.progress == 20)
    #expect(params.total == 25)
    #expect(params.message == "beep boop bop")
    #expect(ProgressNotification.name == "notifications/progress")
}
