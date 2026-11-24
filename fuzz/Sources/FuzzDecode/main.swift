// Decodes the input as each message a peer can send. Nothing may crash;
// whatever decodes must encode again.

import Foundation
import MCP

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func probe<T: Codable>(_: T.Type, _ data: Data) {
    guard let value = try? decoder.decode(T.self, from: data) else { return }
    _ = try? encoder.encode(value)
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    probe(Value.self, data)
    probe(MCPError.self, data)
    probe(Initialize.Parameters.self, data)
    probe(Initialize.Result.self, data)
    probe(ServerDiscover.Result.self, data)
    probe(ListTools.Result.self, data)
    probe(CallTool.Parameters.self, data)
    probe(CallTool.Result.self, data)
    probe(GetPrompt.Result.self, data)
    probe(ReadResource.Result.self, data)
    probe(CreateSamplingMessage.Parameters.self, data)
    probe(CreateSamplingMessage.Result.self, data)
    probe(CreateElicitation.Parameters.self, data)
    probe(CreateElicitation.Result.self, data)
    probe([String: InputRequest].self, data)
    probe([String: InputResponse].self, data)
    probe(SubscriptionsListen.Parameters.self, data)
    probe(Client.Capabilities.self, data)
    probe(Server.Capabilities.self, data)
    if let header = String(data: data, encoding: .utf8) {
        _ = MCPRequestHeaders.decode(header)
    }
    return 0
}
