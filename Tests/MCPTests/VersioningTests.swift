import Testing

@testable import MCP

@Suite("Version Negotiation Tests")
struct VersioningTests {
    @Test("Client requests latest supported version")
    func testClientRequestsLatestSupportedVersion() {
        let clientVersion = Version.latest
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests older supported version")
    func testClientRequestsOlderSupportedVersion() {
        let clientVersion = Version.v2024_11_05
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.v2024_11_05)
    }

    @Test("Client requests unsupported version")
    func testClientRequestsUnsupportedVersion() {
        let clientVersion = "2023-01-01"  // An unsupported version
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests empty version string")
    func testClientRequestsEmptyVersionString() {
        let clientVersion = ""
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests garbage version string")
    func testClientRequestsGarbageVersionString() {
        let clientVersion = "not-a-version"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Server's supported versions correctly defined")
    func testServerSupportedVersions() {
        #expect(Version.supported.contains(Version.v2025_11_25))
        #expect(Version.supported.contains(Version.v2025_06_18))
        #expect(Version.supported.contains(Version.v2025_03_26))
        #expect(Version.supported.contains(Version.v2024_11_05))
        #expect(Version.supported.count == 4)
    }

    @Test("Server's latest version is correct")
    func testServerLatestVersion() {
        #expect(Version.latest == Version.v2025_11_25)
    }
}
