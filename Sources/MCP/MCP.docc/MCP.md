# ``MCP``

Clients and servers for the Model Context Protocol.

## Overview

The package implements MCP for both protocol eras: the `initialize`
handshake (2025-11-25 and earlier) and self-contained requests at
2026-07-28, which carry their protocol version and client capabilities in
`_meta`. One ``Server`` serves both. A ``Client`` discovers a 2026-07-28
server and falls back to the handshake for older servers; see
``Client/ProtocolMode``.

The guides in the repository's
[docs directory](https://github.com/modelcontextprotocol/swift-sdk/tree/main/docs)
cover each feature with compiled examples: the protocol, servers, clients,
protocol versions, migration, testing and troubleshooting.

## Topics

### Essentials

- ``Client``
- ``Server``
- ``MCPError``

### Transports

- ``StdioTransport``
- ``HTTPClientTransport``
- ``StatefulHTTPServerTransport``
- ``StatelessHTTPServerTransport``
- ``InMemoryTransport``
- ``Transport``

### Server features

- ``Tool``
- ``Prompt``
- ``Resource``

### Notification streams

- ``SubscriptionFilter``

### Multi round-trip requests

- ``InputRequest``
- ``InputResponse``
- ``RequestStateProtection``
- ``RequestStateCodec``
- ``AESGCMRequestStateCodec``

### Authorization

- ``OAuthAuthorizer``
- ``OAuthConfiguration``

### Protocol versions

- ``Version``
- ``ProtocolProfile``
