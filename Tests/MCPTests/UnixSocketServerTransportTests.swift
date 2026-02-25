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

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
	@Suite("Unix Socket Server Transport Tests")
	struct UnixSocketServerTransportTests {
		/// Generates a unique temporary socket path
		private func tempSocketPath() -> String {
			// Use a short path to avoid exceeding socket path limits
			let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
			let shortID = String(uuid.prefix(8))
			return "/tmp/srv-\(shortID).sock"
		}

		/// Cleanup helper to remove socket file
		private func cleanup(_ path: String) {
			unlink(path)
		}

		/// Checks if data is a connection notification (should be filtered out in tests)
		private func isConnectionNotification(_ data: Data) -> Bool {
			data == UnixSocketServerTransport.newConnectionNotification
		}

		@Test("Server Accept Client Connection")
		func testServerAcceptClientConnection() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server in background
			let serverTask = Task {
				try await server.connect()
			}

			// Give server time to start listening
			try await Task.sleep(for: .milliseconds(100))

			// Connect client
			try await client.connect()

			// Wait for server to accept
			_ = try await serverTask.value

			// Verify connection succeeded
			#expect(Bool(true))

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Receive Message from Client")
		func testServerReceiveMessageFromClient() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send message from client
			let message = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
			try await client.send(message.data(using: .utf8)!)

			// Receive on server (skip connection notification)
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			var received = try await iterator.next()
			if let data = received, isConnectionNotification(data) {
				received = try await iterator.next()
			}
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Send Message to Client")
		func testServerSendMessageToClient() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Give time for server to process the connection
			try await Task.sleep(for: .milliseconds(50))

			// Send message from server
			let message = #"{"jsonrpc":"2.0","result":"pong","id":1}"#
			try await server.send(message.data(using: .utf8)!)

			// Receive on client
			let stream = await client.receive()
			var iterator = stream.makeAsyncIterator()

			let received = try await iterator.next()
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Bidirectional Communication")
		func testServerBidirectionalCommunication() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Client sends request
			let request = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
			try await client.send(request.data(using: .utf8)!)

			// Server receives and sends response (skip connection notification)
			let serverStream = await server.receive()
			var serverIterator = serverStream.makeAsyncIterator()

			var receivedRequest = try await serverIterator.next()
			if let data = receivedRequest, isConnectionNotification(data) {
				receivedRequest = try await serverIterator.next()
			}
			#expect(receivedRequest == request.data(using: .utf8)!)

			let response = #"{"jsonrpc":"2.0","result":"pong","id":1}"#
			try await server.send(response.data(using: .utf8)!)

			// Client receives response
			let clientStream = await client.receive()
			var clientIterator = clientStream.makeAsyncIterator()

			let receivedResponse = try await clientIterator.next()
			#expect(receivedResponse == response.data(using: .utf8)!)

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Multiple Messages from Client")
		func testServerMultipleMessagesFromClient() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send multiple messages
			let messages = [
				#"{"jsonrpc":"2.0","method":"test1","id":1}"#,
				#"{"jsonrpc":"2.0","method":"test2","id":2}"#,
				#"{"jsonrpc":"2.0","method":"test3","id":3}"#,
			]

			for message in messages {
				try await client.send(message.data(using: .utf8)!)
			}

			// Receive all messages (skip connection notification)
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			// Skip connection notification
			var first = try await iterator.next()
			if let data = first, isConnectionNotification(data) {
				first = try await iterator.next()
			}
			#expect(first == messages[0].data(using: .utf8)!)

			for expectedMessage in messages.dropFirst() {
				let received = try await iterator.next()
				#expect(received == expectedMessage.data(using: .utf8)!)
			}

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Large Message")
		func testServerLargeMessage() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Create a large message (20KB)
			let largeData = String(repeating: "x", count: 20000)
			let message =
				#"{"jsonrpc":"2.0","method":"test","params":{"data":"\#(largeData)"},"id":1}"#

			try await client.send(message.data(using: .utf8)!)

			// Receive on server (skip connection notification)
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			var received = try await iterator.next()
			if let data = received, isConnectionNotification(data) {
				received = try await iterator.next()
			}
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Invalid Socket Path (Too Long)")
		func testServerInvalidSocketPathTooLong() async throws {
			// Create a path that exceeds platform limits
			let longPath = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
			let server = UnixSocketServerTransport(path: longPath, cleanup: .removeExisting)

			do {
				try await server.connect()
				#expect(Bool(false), "Expected connect to throw an error")
			} catch {
				#expect(error is MCPError)
				if case .internalError(let msg) = error as? MCPError {
					#expect(msg?.contains("Socket path too long") == true)
				}
			}

			await server.disconnect()
		}

		@Test("Server Socket Cleanup - Remove Existing")
		func testServerSocketCleanupRemoveExisting() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			// Create first server and client
			let server1 = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client1 = UnixSocketClientTransport(path: path)

			let serverTask1 = Task { try await server1.connect() }
			try await Task.sleep(for: .milliseconds(100))
			try await client1.connect()
			_ = try await serverTask1.value

			// Disconnect both
			await client1.disconnect()
			await server1.disconnect()

			// Wait a bit
			try await Task.sleep(for: .milliseconds(50))

			// Create second server with removeExisting - should succeed
			let server2 = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client2 = UnixSocketClientTransport(path: path)

			let serverTask2 = Task { try await server2.connect() }
			try await Task.sleep(for: .milliseconds(100))
			try await client2.connect()
			_ = try await serverTask2.value

			await client2.disconnect()
			await server2.disconnect()
		}

		@Test("Server Socket Cleanup - Fail If Exists")
		func testServerSocketCleanupFailIfExists() async throws {
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
			let server = UnixSocketServerTransport(path: path, cleanup: .failIfExists)

			do {
				try await server.connect()
				#expect(Bool(false), "Expected connect to throw an error")
			} catch {
				// Expected to fail
				#expect(error is MCPError)
			}

			await server.disconnect()
		}

		@Test("Server Socket Cleanup - Reuse Stale Socket")
		func testServerSocketCleanupReuseStale() async throws {
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
			let server = UnixSocketServerTransport(
				path: path, cleanup: .reuseIfPossible)
			let client = UnixSocketClientTransport(path: path)

			let serverTask = Task { try await server.connect() }
			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Send Error (Disconnected)")
		func testServerSendErrorDisconnected() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Connect and disconnect
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value
			await server.disconnect()

			// Try to send after disconnect - should fail
			do {
				try await server.send("test".data(using: .utf8)!)
				#expect(Bool(false), "Expected send to throw an error")
			} catch {
				#expect(error is MCPError)
			}

			await client.disconnect()
		}

		@Test("Server Connection Lifecycle")
		func testServerConnectionLifecycle() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Connect
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send a message
			try await client.send(#"{"test":"data"}"#.data(using: .utf8)!)

			// Disconnect
			await server.disconnect()
			await client.disconnect()

			// Verify socket file is cleaned up
			#expect(access(path, F_OK) != 0)
		}

		@Test("Server Accepts Multiple Sequential Clients")
		func testServerAcceptsMultipleSequentialClients() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			_ = try await serverTask.value

			let msg1 = #"{"jsonrpc":"2.0","method":"test1","id":1}"#
			let msg2 = #"{"jsonrpc":"2.0","method":"test2","id":2}"#
			let connectionNotification = UnixSocketServerTransport.newConnectionNotification

			// Collect messages in background - returns array when done (filter out connection notifications)
			let receiveTask = Task { () -> [Data] in
				var messages: [Data] = []
				for try await data in await server.receive() {
					// Skip connection notifications
					if data != connectionNotification {
						messages.append(data)
					}
					if messages.count >= 2 {
						break
					}
				}
				return messages
			}

			// First client connects, sends message, disconnects
			let client1 = UnixSocketClientTransport(path: path)
			try await client1.connect()
			try await Task.sleep(for: .milliseconds(50))
			try await client1.send(msg1.data(using: .utf8)!)
			try await Task.sleep(for: .milliseconds(50))
			await client1.disconnect()

			// Wait a bit for server to process disconnect
			try await Task.sleep(for: .milliseconds(100))

			// Second client connects and sends message
			let client2 = UnixSocketClientTransport(path: path)
			try await client2.connect()
			try await Task.sleep(for: .milliseconds(50))
			try await client2.send(msg2.data(using: .utf8)!)

			// Wait for messages to be received
			let receivedMessages = try await receiveTask.value

			// Verify both messages were received
			#expect(receivedMessages.count == 2)
			#expect(receivedMessages[0] == msg1.data(using: .utf8)!)
			#expect(receivedMessages[1] == msg2.data(using: .utf8)!)

			await client2.disconnect()
			await server.disconnect()
		}

		@Test("Server Three Sequential Clients With Requests")
		func testServerThreeSequentialClientsWithRequests() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)

			// Start server
			try await server.connect()

			// Messages for each client (simulating initialize requests)
			let requests = [
				#"{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05"}}"#,
				#"{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05"}}"#,
				#"{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05"}}"#,
			]

			let connectionNotification = UnixSocketServerTransport.newConnectionNotification

			// Collect messages in background (filter out connection notifications)
			let receiveTask = Task { () -> [Data] in
				var messages: [Data] = []
				for try await data in await server.receive() {
					// Skip connection notifications
					if data != connectionNotification {
						messages.append(data)
					}
					if messages.count >= 3 {
						break
					}
				}
				return messages
			}

			// Process 3 sequential clients
			for (index, request) in requests.enumerated() {
				let client = UnixSocketClientTransport(path: path)
				try await client.connect()
				try await Task.sleep(for: .milliseconds(50))

				// Send request
				try await client.send(request.data(using: .utf8)!)

				// Simulate server sending response (no error)
				let response = #"{"jsonrpc":"2.0","result":{"protocolVersion":"2024-11-05"},"id":1}"#
				try await Task.sleep(for: .milliseconds(50))
				try await server.send(response.data(using: .utf8)!)

				// Client receives response
				let clientStream = await client.receive()
				var iterator = clientStream.makeAsyncIterator()
				let receivedResponse = try await iterator.next()

				// Verify response has no error
				#expect(receivedResponse != nil)
				let responseString = String(data: receivedResponse!, encoding: .utf8)!
				#expect(!responseString.contains("\"error\""), "Client \(index + 1) should not receive error")
				#expect(responseString.contains("\"result\""), "Client \(index + 1) should receive result")

				await client.disconnect()
				try await Task.sleep(for: .milliseconds(100))
			}

			// Verify all 3 requests were received
			let receivedMessages = try await receiveTask.value
			#expect(receivedMessages.count == 3)

			// Verify each request is valid JSON-RPC (no errors in what we received)
			for (index, msg) in receivedMessages.enumerated() {
				let msgString = String(data: msg, encoding: .utf8)!
				#expect(msgString.contains("\"method\":\"initialize\""), "Message \(index + 1) should be initialize request")
				#expect(!msgString.contains("\"error\""), "Message \(index + 1) should not contain error")
			}

			await server.disconnect()
		}

		@Test("Server Socket Path Max Constant")
		func testServerSocketPathMaxConstant() {
			// Verify the constant is reasonable
			#if canImport(Darwin)
				#expect(UnixSocketServerTransport.socketPathMax == 103)
			#elseif canImport(Glibc) || canImport(Musl)
				#expect(UnixSocketServerTransport.socketPathMax >= 107)
			#endif
		}

		@Test("Server Non-Blocking Socket")
		func testServerNonBlockingSocket() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))

			// Client connects with non-blocking socket
			try await client.connect()
			_ = try await serverTask.value

			// Send multiple messages rapidly
			for i in 0..<10 {
				try await client.send(#"{"id":\#(i)}"#.data(using: .utf8)!)
			}

			// Verify non-blocking operation succeeded
			#expect(Bool(true))

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Multiple Connect Calls Are Idempotent")
		func testServerMultipleConnectCallsIdempotent() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))

			// Connect client
			try await client.connect()
			_ = try await serverTask.value

			// Multiple connect calls should be idempotent (return early)
			try await server.connect()
			try await server.connect()

			await client.disconnect()
			await server.disconnect()
		}

		@Test("Server Empty Message Handling")
		func testServerEmptyMessageHandling() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = UnixSocketServerTransport(
				path: path, cleanup: .removeExisting)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.connect()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send empty data
			try await client.send(Data())

			// Server should not receive anything (empty line is filtered out)
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			// First message will be connection notification, skip it
			var received = try await iterator.next()
			if let data = received, isConnectionNotification(data) {
				// Send a real message to unblock the iterator
				try await Task.sleep(for: .milliseconds(50))
				let message = #"{"test":"real"}"#
				try await client.send(message.data(using: .utf8)!)

				received = try await iterator.next()
				#expect(received == message.data(using: .utf8)!)
			} else {
				// No connection notification, proceed as before
				try await Task.sleep(for: .milliseconds(50))
				let message = #"{"test":"real"}"#
				try await client.send(message.data(using: .utf8)!)
				#expect(received == message.data(using: .utf8)!)
			}

			await client.disconnect()
			await server.disconnect()
		}
	}
#endif
