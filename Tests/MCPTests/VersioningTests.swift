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
        let clientVersion = "2024-11-05"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == "2024-11-05")
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
        #expect(Version.supported.contains("2025-11-25"))
        #expect(Version.supported.contains("2025-06-18"))
        #expect(Version.supported.contains("2025-03-26"))
        #expect(Version.supported.contains("2024-11-05"))
        #expect(Version.supported.contains("2026-07-28"))
        #expect(Version.supported.count == 5)
    }

    @Test("Server's latest version is correct")
    func testServerLatestVersion() {
        #expect(Version.latest == "2025-11-25")
    }

    @Test("Client requests new 2025-11-25 version")
    func testClientRequests2025_11_25Version() {
        let clientVersion = "2025-11-25"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == "2025-11-25")
    }
}

@Suite("Protocol Profile Tests")
struct ProtocolProfileTests {
    @Test("Handshake and stateless revisions are disjoint and ordered newest first")
    func testRevisionLists() {
        #expect(Set(Version.handshake).isDisjoint(with: Version.stateless))
        #expect(Version.handshake == Version.handshake.sorted(by: >))
        #expect(Version.handshake.first == Version.latest)
        #expect(Version.supported == Set(Version.handshake + Version.stateless))
    }

    @Test("A stateless revision is never negotiated through initialize")
    func testNegotiateRejectsStatelessRevision() {
        #expect(Version.negotiate(clientRequestedVersion: Version.v2026_07_28) == Version.v2025_11_25)
        #expect(Version.negotiate(clientRequestedVersion: "2099-01-01") == Version.v2025_11_25)
    }

    @Test("Handshake revisions use sessions and server requests")
    func testHandshakeProfile() {
        let profile = Version.profile(for: Version.v2025_11_25)
        #expect(profile.usesInitializeHandshake)
        #expect(profile.usesSessions)
        #expect(profile.allowsServerRequests)
        #expect(profile.allowsPrimingEvents)
        #expect(!profile.usesRequestMeta)
        #expect(!profile.usesResultType)
        #expect(!profile.usesSubscriptionsListen)
        #expect(!profile.usesStandardHeaders)
    }

    @Test("Priming events are disabled before 2025-03-26")
    func testPrimingEvents() {
        #expect(!Version.profile(for: Version.v2024_11_05).allowsPrimingEvents)
        #expect(Version.profile(for: Version.v2025_03_26).allowsPrimingEvents)
    }

    @Test("2026-07-28 and later are stateless")
    func testStatelessProfile() {
        for version in [Version.v2026_07_28, "2099-12-31"] {
            let profile = Version.profile(for: version)
            #expect(!profile.usesInitializeHandshake)
            #expect(!profile.usesSessions)
            #expect(!profile.allowsServerRequests)
            #expect(!profile.allowsPrimingEvents)
            #expect(profile.usesRequestMeta)
            #expect(profile.usesResultType)
            #expect(profile.usesSubscriptionsListen)
            #expect(profile.usesStandardHeaders)
        }
    }

    @Test("A version that is not a date gets the latest handshake profile")
    func testNonDateVersions() {
        for version in ["garbage", "9", "2026-07-28x", "2026/07/28", "", "DRAFT-2026"] {
            let profile = Version.profile(for: version)
            #expect(profile.usesInitializeHandshake, "\(version)")
            #expect(profile.version == version)
        }
        #expect(Version.isDateVersion("2026-07-28"))
        #expect(!Version.isDateVersion("2026-7-28"))
        #expect(!Version.isDateVersion("２０２６-07-28"))
    }
}
