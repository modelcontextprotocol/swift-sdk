import Logging

import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.POSIXError

@testable import MCP

/// Mock transport for testing
actor MockTransport: Transport, HTTPContextProviding {
    var logger: Logger

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    var isConnected = false

    private(set) var sentData: [Data] = []
    var sentMessages: [String] {
        return sentData.compactMap { data in
            guard let string = String(data: data, encoding: .utf8) else {
                logger.error("Failed to decode sent data as UTF-8")
                return nil
            }
            return string
        }
    }

    private var dataToReceive: [Data] = []
    private(set) var receivedMessages: [String] = []

    private var dataStreamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
  private var shouldBlockHTTPContext = false
  private var requestedHTTPContextIDs: Set<ID> = []
  private var httpContextContinuations: [ID: CheckedContinuation<Void, Never>] = [:]

    var shouldFailConnect = false
    var shouldFailSend = false

    init(logger: Logger = Logger(label: "mcp.test.transport")) {
        self.logger = logger
    }

    public func connect() async throws {
        if shouldFailConnect {
            throw MCPError.transportError(POSIXError(.ECONNREFUSED))
        }
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
        dataStreamContinuation?.finish()
        dataStreamContinuation = nil
    }

    public func send(_ message: Data) async throws {
        if shouldFailSend {
            throw MCPError.transportError(POSIXError(.EIO))
        }
        sentData.append(message)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return AsyncThrowingStream<Data, Swift.Error> { continuation in
            dataStreamContinuation = continuation
            for message in dataToReceive {
                continuation.yield(message)
                if let string = String(data: message, encoding: .utf8) {
                    receivedMessages.append(string)
                }
            }
            dataToReceive.removeAll()
        }
    }

    func setFailConnect(_ shouldFail: Bool) {
        shouldFailConnect = shouldFail
    }

    func setFailSend(_ shouldFail: Bool) {
        shouldFailSend = shouldFail
    }

  func httpRequestContext(for id: ID) async -> HTTPRequest? {
    requestedHTTPContextIDs.insert(id)
    if shouldBlockHTTPContext {
      await withCheckedContinuation { continuation in
        httpContextContinuations[id] = continuation
      }
    }
    return nil
  }

  func blockHTTPContext() {
    shouldBlockHTTPContext = true
  }

  func hasRequestedHTTPContext() -> Bool {
    !requestedHTTPContextIDs.isEmpty
  }

  func releaseHTTPContext() {
    shouldBlockHTTPContext = false
    let continuations = Array(httpContextContinuations.values)
    httpContextContinuations.removeAll()
    for continuation in continuations {
        continuation.resume()
    }
  }

    func queue(data: Data) {
        if let continuation = dataStreamContinuation {
            continuation.yield(data)
        } else {
            dataToReceive.append(data)
        }
    }

    func queue<M: Method>(request: Request<M>) throws {
        queue(data: try encoder.encode(request))
    }

    func queue<M: Method>(response: Response<M>) throws {
        queue(data: try encoder.encode(response))
    }

    func queue<N: Notification>(notification: Message<N>) throws {
        queue(data: try encoder.encode(notification))
    }

    func queue(batch requests: [AnyRequest]) throws {
        queue(data: try encoder.encode(requests))
    }

    func queue(batch responses: [AnyResponse]) throws {
        queue(data: try encoder.encode(responses))
    }

    func decodeLastSentMessage<T: Decodable>() -> T? {
        guard let lastMessage = sentData.last else { return nil }
        do {
            return try decoder.decode(T.self, from: lastMessage)
        } catch {
            return nil
        }
    }

    func clearMessages() {
        sentData.removeAll()
        dataToReceive.removeAll()
    }
}
