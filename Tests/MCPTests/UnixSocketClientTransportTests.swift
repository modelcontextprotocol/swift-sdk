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
	/// Simple test server for testing UnixSocketClientTransport
	actor TestUnixSocketServer {
		private var socketDescriptor: FileDescriptor?
		private var clientDescriptor: FileDescriptor?
		private let path: String
		private var isRunning = false
		private var messageStream: AsyncThrowingStream<Data, Swift.Error>?
		private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
		private var readTask: Task<Void, Never>?

		init(path: String) {
			self.path = path
		}

		func start() async throws {
			guard !isRunning else { return }

			// Clean up existing socket
			unlink(path)

			let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
			guard sockfd >= 0 else {
				throw MCPError.transportError(Errno(rawValue: CInt(errno)))
			}

			let fd = FileDescriptor(rawValue: sockfd)

			// Set SO_REUSEADDR
			var reuseAddr: Int32 = 1
			_ = setsockopt(
				sockfd, SOL_SOCKET, SO_REUSEADDR,
				&reuseAddr, socklen_t(MemoryLayout<Int32>.size))

			var addr = sockaddr_un()
			addr.sun_family = sa_family_t(AF_UNIX)
			let pathBytes = path.utf8CString
			_ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
				pathBytes.withUnsafeBufferPointer { buffer in
					memcpy(ptr, buffer.baseAddress, min(buffer.count, 103))
				}
			}

			let bindResult = withUnsafePointer(to: &addr) { addrPtr in
				addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
					#if canImport(Darwin)
						Darwin.bind(
							sockfd, sockaddrPtr,
							socklen_t(MemoryLayout<sockaddr_un>.size))
					#elseif canImport(Glibc)
						Glibc.bind(
							sockfd, sockaddrPtr,
							socklen_t(MemoryLayout<sockaddr_un>.size))
					#else
						Musl.bind(
							sockfd, sockaddrPtr,
							socklen_t(MemoryLayout<sockaddr_un>.size))
					#endif
				}
			}

			guard bindResult >= 0 else {
				try fd.close()
				throw MCPError.transportError(Errno(rawValue: CInt(errno)))
			}

			let listenResult = listen(sockfd, 1)
			guard listenResult >= 0 else {
				try fd.close()
				unlink(path)
				throw MCPError.transportError(Errno(rawValue: CInt(errno)))
			}

			// Set non-blocking
			let flags = fcntl(sockfd, F_GETFL)
			_ = fcntl(sockfd, F_SETFL, flags | O_NONBLOCK)

			self.socketDescriptor = fd

			// Accept one client
			var clientfd: Int32 = -1
			while clientfd < 0 && !Task.isCancelled {
				clientfd = accept(sockfd, nil, nil)
				if clientfd >= 0 {
					break
				}
				let error = Errno(rawValue: CInt(errno))
				if error == .resourceTemporarilyUnavailable || error == .wouldBlock {
					try await Task.sleep(for: .milliseconds(10))
					continue
				} else {
					try fd.close()
					unlink(path)
					throw MCPError.transportError(error)
				}
			}

			guard clientfd >= 0 else {
				try fd.close()
				unlink(path)
				throw MCPError.internalError("Accept cancelled")
			}

			let clientFd = FileDescriptor(rawValue: clientfd)
			let clientFlags = fcntl(clientfd, F_GETFL)
			_ = fcntl(clientfd, F_SETFL, clientFlags | O_NONBLOCK)

			self.clientDescriptor = clientFd

			// Create stream
			var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
			self.messageStream = AsyncThrowingStream { continuation = $0 }
			self.messageContinuation = continuation

			isRunning = true
			readTask = Task { await self.readLoop() }
		}

		func stop() async {
			guard isRunning else { return }
			isRunning = false

			readTask?.cancel()
			await readTask?.value
			readTask = nil

			if let client = clientDescriptor {
				try? client.close()
				clientDescriptor = nil
			}

			if let socket = socketDescriptor {
				try? socket.close()
				socketDescriptor = nil
			}

			unlink(path)
			messageContinuation?.finish()
			messageContinuation = nil
			messageStream = nil
		}

		func send(_ data: Data) async throws {
			guard isRunning, let client = clientDescriptor else {
				throw MCPError.transportError(Errno(rawValue: ENOTCONN))
			}

			var messageWithNewline = data
			messageWithNewline.append(UInt8(ascii: "\n"))

			var remaining = messageWithNewline
			while !remaining.isEmpty {
				do {
					let written = try remaining.withUnsafeBytes { buffer in
						try client.write(UnsafeRawBufferPointer(buffer))
					}
					if written > 0 {
						remaining = remaining.dropFirst(written)
					}
				} catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
					try await Task.sleep(for: .milliseconds(10))
					continue
				} catch {
					throw MCPError.transportError(error)
				}
			}
		}

		func receive() -> AsyncThrowingStream<Data, Swift.Error> {
			guard let stream = messageStream else {
				return AsyncThrowingStream { $0.finish() }
			}
			return stream
		}

		private func readLoop() async {
			let bufferSize = 4096
			var buffer = [UInt8](repeating: 0, count: bufferSize)
			var pendingData = Data()

			guard let descriptor = clientDescriptor, let continuation = messageContinuation
			else {
				return
			}

			while isRunning && !Task.isCancelled {
				do {
					let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
						try descriptor.read(into: UnsafeMutableRawBufferPointer(pointer))
					}

					if bytesRead == 0 {
						break
					}

					pendingData.append(Data(buffer[..<bytesRead]))

					while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
						let messageData = pendingData[..<newlineIndex]
						pendingData = pendingData[(newlineIndex + 1)...]

						if !messageData.isEmpty {
							continuation.yield(Data(messageData))
						}
					}
				} catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
					try? await Task.sleep(for: .milliseconds(10))
					continue
				} catch {
					if !Task.isCancelled {
						break
					}
				}
			}

			continuation.finish()
		}
	}

	@Suite("Unix Socket Client Transport Tests")
	struct UnixSocketClientTransportTests {
		/// Generates a unique temporary socket path
		private func tempSocketPath() -> String {
			// Use a short path to avoid exceeding socket path limits
			let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
			let shortID = String(uuid.prefix(8))
			return "/tmp/mcp-\(shortID).sock"
		}

		/// Cleanup helper to remove socket file
		private func cleanup(_ path: String) {
			unlink(path)
		}

		@Test("Client Connect to Server")
		func testClientConnectToServer() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server in background
			let serverTask = Task {
				try await server.start()
			}

			// Give server time to start listening
			try await Task.sleep(for: .milliseconds(100))

			// Connect client
			try await client.connect()

			// Wait for server to accept
			_ = try await serverTask.value

			// Verify connection succeeded
			#expect(true)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Send Message to Server")
		func testClientSendMessageToServer() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send message from client
			let message = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
			try await client.send(message.data(using: .utf8)!)

			// Receive on server
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			let received = try await iterator.next()
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Receive Message from Server")
		func testClientReceiveMessageFromServer() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send message from server
			let message = #"{"jsonrpc":"2.0","result":"pong","id":1}"#
			try await server.send(message.data(using: .utf8)!)

			// Receive on client
			let stream = await client.receive()
			var iterator = stream.makeAsyncIterator()

			let received = try await iterator.next()
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Bidirectional Communication")
		func testClientBidirectionalCommunication() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

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

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Multiple Messages")
		func testClientMultipleMessages() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
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

			// Receive all messages
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			for expectedMessage in messages {
				let received = try await iterator.next()
				#expect(received == expectedMessage.data(using: .utf8)!)
			}

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Large Message")
		func testClientLargeMessage() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

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

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Invalid Socket Path (Too Long)")
		func testClientInvalidSocketPathTooLong() async throws {
			// Create a path that exceeds platform limits
			let longPath = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
			let client = UnixSocketClientTransport(path: longPath)

			do {
				try await client.connect()
				#expect(Bool(false), "Expected connect to throw an error")
			} catch {
				#expect(error is MCPError)
				if case .internalError(let msg) = error as? MCPError {
					#expect(msg?.contains("Socket path too long") == true)
				}
			}

			await client.disconnect()
		}

		@Test("Client Connection Failure (No Server)")
		func testClientConnectionFailureNoServer() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let client = UnixSocketClientTransport(path: path)

			do {
				try await client.connect()
				#expect(Bool(false), "Expected connect to throw an error")
			} catch {
				// Expected to fail - no server listening
				#expect(error is MCPError)
			}

			await client.disconnect()
		}

		@Test("Client Send Error (Disconnected)")
		func testClientSendErrorDisconnected() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Connect and disconnect
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value
			await client.disconnect()

			// Try to send after disconnect - should fail
			do {
				try await client.send("test".data(using: .utf8)!)
				#expect(Bool(false), "Expected send to throw an error")
			} catch {
				#expect(error is MCPError)
			}

			await server.stop()
		}

		@Test("Client Connection Lifecycle")
		func testClientConnectionLifecycle() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Connect
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send a message
			try await client.send(#"{"test":"data"}"#.data(using: .utf8)!)

			// Disconnect
			await client.disconnect()
			await server.stop()

			// Verify we got here without errors
			#expect(true)
		}

		@Test("Client Reconnection")
		func testClientReconnection() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			// First connection
			let server1 = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			let serverTask1 = Task {
				try await server1.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			try await serverTask1.value

			// Send a message
			let message1 = #"{"test":"first"}"#
			try await client.send(message1.data(using: .utf8)!)

			// Disconnect
			await client.disconnect()
			await server1.stop()

			// Wait a bit
			try await Task.sleep(for: .milliseconds(100))

			// Second connection (reconnect)
			let server2 = TestUnixSocketServer(
				path: path)

			let serverTask2 = Task {
				try await server2.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask2.value

			// Send another message
			let message2 = #"{"test":"second"}"#
			try await client.send(message2.data(using: .utf8)!)

			// Receive on server
			let stream = await server2.receive()
			var iterator = stream.makeAsyncIterator()

			let received = try await iterator.next()
			#expect(received == message2.data(using: .utf8)!)

			await client.disconnect()
			await server2.stop()
		}

		@Test("Client Multiple Connect Calls Are Idempotent")
		func testClientMultipleConnectCallsIdempotent() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))

			// Connect multiple times - should be idempotent
			try await client.connect()
			try await client.connect()  // Should return early
			try await client.connect()  // Should return early

			_ = try await serverTask.value

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Disconnect During Receive")
		func testClientDisconnectDuringReceive() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Start a task to receive messages
			let receiveTask = Task {
				var count = 0
				for try await _ in await client.receive() {
					count += 1
					if count > 10 {
						// Prevent infinite loop in test
						break
					}
				}
			}

			// Let the receive loop start
			try await Task.sleep(for: .milliseconds(100))

			// Disconnect while receiving
			await client.disconnect()

			// Wait for the receive task to complete
			_ = await receiveTask.result

			await server.stop()
		}

		@Test("Client Partial Message Reception")
		func testClientPartialMessageReception() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Server sends a complete message
			let message = #"{"jsonrpc":"2.0","result":"ok","id":1}"#
			try await server.send(message.data(using: .utf8)!)

			// Client receives the message (readLoop handles partial reads internally)
			let stream = await client.receive()
			var iterator = stream.makeAsyncIterator()

			let received = try await iterator.next()
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Receive After Disconnect Returns Empty Stream")
		func testClientReceiveAfterDisconnect() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Connect
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Disconnect before receiving
			await client.disconnect()

			// Create receive stream after disconnect
			let messages = await client.receive()
			var messageCount = 0

			for try await _ in messages {
				messageCount += 1
			}

			// Stream should complete immediately
			#expect(messageCount == 0)

			await server.stop()
		}

		@Test("Client Server Close Detection")
		func testClientServerCloseDetection() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Start receiving on client
			let receiveTask = Task {
				var messageCount = 0
				for try await _ in await client.receive() {
					messageCount += 1
				}
				return messageCount
			}

			// Give time for receive loop to start
			try await Task.sleep(for: .milliseconds(50))

			// Server closes connection
			await server.stop()

			// Client should detect the close
			let count = try await receiveTask.value
			#expect(count == 0)

			await client.disconnect()
		}

		@Test("Client Socket Path Max Constant")
		func testClientSocketPathMaxConstant() {
			// Verify the constant is reasonable
			#if canImport(Darwin)
				#expect(UnixSocketClientTransport.socketPathMax == 103)
			#elseif canImport(Glibc) || canImport(Musl)
				#expect(UnixSocketClientTransport.socketPathMax >= 107)
			#endif
		}

		@Test("Client Non-Blocking Socket")
		func testClientNonBlockingSocket() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
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
			#expect(true)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Empty Message Handling")
		func testClientEmptyMessageHandling() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Start server
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Send empty data
			try await client.send(Data())

			// Server should not receive anything (empty line is filtered out)
			let stream = await server.receive()
			var iterator = stream.makeAsyncIterator()

			// Send a real message to unblock the iterator
			try await Task.sleep(for: .milliseconds(50))
			let message = #"{"test":"real"}"#
			try await client.send(message.data(using: .utf8)!)

			let received = try await iterator.next()
			#expect(received == message.data(using: .utf8)!)

			await client.disconnect()
			await server.stop()
		}

		@Test("Client Multiple Disconnects Are Safe")
		func testClientMultipleDisconnectsSafe() async throws {
			let path = tempSocketPath()
			defer { cleanup(path) }

			let server = TestUnixSocketServer(
				path: path)
			let client = UnixSocketClientTransport(path: path)

			// Connect
			let serverTask = Task {
				try await server.start()
			}

			try await Task.sleep(for: .milliseconds(100))
			try await client.connect()
			_ = try await serverTask.value

			// Multiple disconnects should be safe
			await client.disconnect()
			await client.disconnect()  // Should be safe
			await client.disconnect()  // Should be safe

			await server.stop()
		}
	}
#endif
