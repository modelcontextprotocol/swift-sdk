import Foundation
import Testing

@testable import MCP

#if canImport(System)
        import System
#else
        @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
        import Darwin.POSIX
#elseif canImport(Glibc)
        import Glibc
#elseif canImport(Musl)
        import Musl
#endif

@Suite("Unix Socket Transport Tests")
struct UnixSocketTransportTests {
        /// Generates a unique temporary socket path
        private func tempSocketPath() -> String {
                #if canImport(Darwin)
                        return NSTemporaryDirectory() + "mcp-test-\(UUID().uuidString).sock"
                #else
                        return "/tmp/mcp-test-\(UUID().uuidString).sock"
                #endif
        }

        /// Cleanup helper to remove socket file
        private func cleanup(_ path: String) {
                unlink(path)
        }

        @Test("Client-Server Connection")
        func testClientServerConnection() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server in background
                let serverTask = Task {
                        try await server.connect()
                }

                // Give server time to start listening
                try await Task.sleep(for: .milliseconds(100))

                // Connect client
                try await client.connect()

                // Wait for server to accept
                try await serverTask.value

                // Verify both are connected
                #expect(true)  // If we got here, connection succeeded

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Send Message Client to Server")
        func testSendMessageClientToServer() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Send message from client
                let message = #"{"jsonrpc":"2.0","method":"test","id":1}"#
                try await client.send(message.data(using: .utf8)!)

                // Receive on server
                let stream = await server.receive()
                var iterator = stream.makeAsyncIterator()

                let received = try await iterator.next()
                #expect(received == message.data(using: .utf8)!)

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Send Message Server to Client")
        func testSendMessageServerToClient() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Send message from server
                let message = #"{"jsonrpc":"2.0","result":"ok","id":1}"#
                try await server.send(message.data(using: .utf8)!)

                // Receive on client
                let stream = await client.receive()
                var iterator = stream.makeAsyncIterator()

                let received = try await iterator.next()
                #expect(received == message.data(using: .utf8)!)

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Bidirectional Communication")
        func testBidirectionalCommunication() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Client sends request
                let request = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
                try await client.send(request.data(using: .utf8)!)

                // Server receives and sends response
                let serverStream = await server.receive()
                var serverIterator = serverStream.makeAsyncIterator()

                let receivedRequest = try await serverIterator.next()
                #expect(receivedRequest == request.data(using: .utf8)!)

                let response = #"{"jsonrpc":"2.0","result":"pong","id":1}"#
                try await server.send(response.data(using: .utf8)!)

                // Client receives response
                let clientStream = await client.receive()
                var clientIterator = clientStream.makeAsyncIterator()

                let receivedResponse = try await clientIterator.next()
                #expect(receivedResponse == response.data(using: .utf8)!)

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Multiple Messages")
        func testMultipleMessages() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Send multiple messages
                let messages = [
                        #"{"jsonrpc":"2.0","method":"test1","id":1}"#,
                        #"{"jsonrpc":"2.0","method":"test2","id":2}"#,
                        #"{"jsonrpc":"2.0","method":"test3","id":3}"#,
                ]

                for message in messages {
                        try await client.send(message.data(using: .utf8)!)
                }

                // Receive all messages
                let stream = await server.receive()
                var iterator = stream.makeAsyncIterator()

                for expectedMessage in messages {
                        let received = try await iterator.next()
                        #expect(received == expectedMessage.data(using: .utf8)!)
                }

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Large Message")
        func testLargeMessage() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Start server
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Create a large message (20KB)
                let largeData = String(repeating: "x", count: 20000)
                let message =
                        #"{"jsonrpc":"2.0","method":"test","params":{"data":"\#(largeData)"},"id":1}"#

                try await client.send(message.data(using: .utf8)!)

                // Receive on server
                let stream = await server.receive()
                var iterator = stream.makeAsyncIterator()

                let received = try await iterator.next()
                #expect(received == message.data(using: .utf8)!)

                await server.disconnect()
                await client.disconnect()
        }

        @Test("Socket Cleanup - Remove Existing")
        func testSocketCleanupRemoveExisting() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                // Create first server and connect with a client
                let server1 = try UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client1 = try UnixSocketTransport(path: path, mode: .client)

                let serverTask1 = Task { try await server1.connect() }
                try await Task.sleep(for: .milliseconds(100))
                try await client1.connect()
                try await serverTask1.value

                // Disconnect both
                await client1.disconnect()
                await server1.disconnect()

                // Socket file should not exist after disconnect
                #expect(access(path, F_OK) != 0)

                // Create second server with removeExisting - should succeed even if file exists
                let server2 = try UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client2 = try UnixSocketTransport(path: path, mode: .client)

                let serverTask2 = Task { try await server2.connect() }
                try await Task.sleep(for: .milliseconds(100))
                try await client2.connect()
                try await serverTask2.value

                await client2.disconnect()
                await server2.disconnect()
        }

        @Test("Socket Cleanup - Fail If Exists")
        func testSocketCleanupFailIfExists() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                // Create a dummy file at the socket path
                let fileData = Data("test".utf8)
                #if canImport(Darwin)
                        try fileData.write(to: URL(fileURLWithPath: path))
                #else
                        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                        close(fd)
                #endif

                // Try to create server with failIfExists - should fail
                let server = UnixSocketTransport(path: path, mode: .server(cleanup: .failIfExists))

                do {
                        try await server.connect()
                        #expect(Bool(false), "Expected connect to throw an error")
                } catch {
                        // Expected to fail
                        #expect(error is MCPError)
                }

                await server.disconnect()
        }

        @Test("Socket Cleanup - Reuse If Possible (Stale Socket)")
        func testSocketCleanupReuseStale() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                // Create a stale socket file (not a real socket)
                let fileData = Data("stale".utf8)
                #if canImport(Darwin)
                        try fileData.write(to: URL(fileURLWithPath: path))
                #else
                        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                        close(fd)
                #endif

                // Server with reuseIfPossible should remove stale file and succeed
                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .reuseIfPossible))
                let client = UnixSocketTransport(path: path, mode: .client)

                let serverTask = Task { try await server.connect() }
                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                await client.disconnect()
                await server.disconnect()
        }

        @Test("Invalid Socket Path (Too Long)")
        func testInvalidSocketPathTooLong() async throws {
                // Create a path that exceeds platform limits (Darwin: 104, Linux: 108 bytes)
                let longPath = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
                let transport = UnixSocketTransport(path: longPath, mode: .client)

                do {
                        try await transport.connect()
                        #expect(Bool(false), "Expected connect to throw an error")
                } catch {
                        #expect(error is MCPError)
                        if case .internalError(let msg) = error as? MCPError {
                                #expect(msg?.contains("Socket path too long") == true)
                        }
                }

                await transport.disconnect()
        }

        @Test("Client Connection Failure (No Server)")
        func testClientConnectionFailureNoServer() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let client = UnixSocketTransport(path: path, mode: .client)

                do {
                        try await client.connect()
                        #expect(Bool(false), "Expected connect to throw an error")
                } catch {
                        // Expected to fail - no server listening
                        #expect(error is MCPError)
                }

                await client.disconnect()
        }

        @Test("Send Error (Disconnected)")
        func testSendErrorDisconnected() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Connect and disconnect
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value
                await client.disconnect()

                // Try to send after disconnect - should fail
                do {
                        try await client.send("test".data(using: .utf8)!)
                        #expect(Bool(false), "Expected send to throw an error")
                } catch {
                        #expect(error is MCPError)
                }

                await server.disconnect()
        }

        @Test("Connection Lifecycle")
        func testConnectionLifecycle() async throws {
                let path = tempSocketPath()
                defer { cleanup(path) }

                let server = UnixSocketTransport(
                        path: path, mode: .server(cleanup: .removeExisting))
                let client = UnixSocketTransport(path: path, mode: .client)

                // Connect
                let serverTask = Task {
                        try await server.connect()
                }

                try await Task.sleep(for: .milliseconds(100))
                try await client.connect()
                try await serverTask.value

                // Send a message
                try await client.send(#"{"test":"data"}"#.data(using: .utf8)!)

                // Disconnect
                await client.disconnect()
                await server.disconnect()

                // Verify socket file is cleaned up
                #expect(access(path, F_OK) != 0)
        }
}
