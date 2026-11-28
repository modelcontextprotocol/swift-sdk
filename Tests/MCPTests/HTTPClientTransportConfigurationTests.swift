import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("HTTP client transport configuration")
struct HTTPClientTransportConfigurationTests {
    // Server-to-client replies need a connection while each call holds one
    // for its response.
    @Test("The default configuration allows many connections per host")
    func connectionLimit() {
        let configuration = HTTPClientTransport.defaultConfiguration
        #expect(configuration.httpMaximumConnectionsPerHost == HTTPClientTransport.defaultMaximumConnectionsPerHost)
        #expect(HTTPClientTransport.defaultMaximumConnectionsPerHost >= 32)
    }
}
