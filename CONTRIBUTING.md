# Contributing Guide

Thank you for your interest in contributing to the MCP Swift SDK! This document provides guidelines
and instructions for contributing.

If you work with an AI coding agent, also point it at [AGENTS.md](AGENTS.md). That file covers the
technical conventions in this codebase: message definitions, concurrency, platform gates, and test
patterns.

## AI Policy

The MCP community allows the use of AI assistant tooling for contributions. Before using AI agents,
please review [the MCP AI Policy](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/AI_POLICY.md)
to understand the guidelines and responsibilities for such contributions. In short:

- **Disclose it.** State in the PR description or issue that AI was used, and to what extent.
- **Own it.** You must understand the change and be able to explain it in your own words. When a
  maintainer asks a question, the answer should come from you, not be pasted from a chat window.
- **Keep a human in the loop.** Don't let agents open PRs, file issues, or post comments without a
  person reviewing the output first.

## Before You Start

Open an issue and agree on the approach before writing code for:

- New public APIs, or changes to existing public API shapes
- Architectural changes, such as the `Transport` protocol or the `Client` / `Server` actors
- Changes that cut across many files or modules
- Behavior not covered by the MCP specification. These need a
  [Specification Enhancement Proposal (SEP)](https://modelcontextprotocol.io/seps)
  first.

## Requirements

- [Swift](https://www.swift.org/install/) (6.1 or later)
  - macOS: [Xcode](https://developer.apple.com/xcode/) (16.3 or later), using its bundled toolchain
  - Linux: [swiftly](https://www.swift.org/install/linux/) to install Swift, plus `libcurl4-openssl-dev`
- [Node.js](https://nodejs.org/) (22 or later), only needed for the
  [MCP conformance tests](https://github.com/modelcontextprotocol/conformance)

## Development

You can build the project as follows:

```bash
swift build
```

## Testing

Use these commands to run tests:

```bash
swift test                                                               # All tests
swift test --filter CompletionTests                                      # One suite
swift package generate-documentation --target MCP --warnings-as-errors   # If you changed doc comments
scripts/run-conformance.sh                                               # If you changed protocol behavior or transports
```

## Best Practices

### Commit Messages and PR Descriptions

- Write the subject in the imperative mood and sentence case, describing the behavior change, for
  example `Decode any percent-encoded byte in non-base64 data URLs`. A Conventional Commits prefix
  (`fix:`, `test:`, `docs:`, `refactor:`, `chore:`) is recommended.
- Explain **why** in the body: the root cause, the relevant spec or RFC section, and how the change
  addresses it.
- Link the issue the PR addresses (`Fixes #123`).
- Disclose AI assistance (see [AI Policy](#ai-policy)).

### Coding Style

Follow [the Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/),
and match the style of the surrounding code. [AGENTS.md](AGENTS.md#core-development-principles) has
more rules and examples for message definitions, concurrency, platform gates, and tests.

- **Formatting**: use 4-space indentation, as configured in `.vscode/settings.json`. The repository
  has no enforced formatter, so don't reformat code you are not otherwise changing.
- **Imports**: core `Base/` files import specific Foundation symbols
  (`import struct Foundation.Data`). Other files use `import Foundation`. List `import Logging`
  first.
- **No file headers**: source files start with imports, with no license or copyright banner.
- **Doc comments**: document every `public` symbol with `///`, a one-line summary, and DocC
  callouts (`- Parameters:`, `- Returns:`, `- Throws:`, `- SeeAlso:`, `- Important:`). Use
  ` ``Symbol`` ` links only for symbols that resolve, because CI fails on broken links. Use
  single backticks for method names, header names, and other literals. Code samples in doc comments
  are not compiled, so check them against the real API.
- **Organization**: separate a type from its extensions with `// MARK: -`, and label sections with
  `// MARK: - Name`. Put protocol conformances in separate extensions where the file already does.
- **Codable**: use `private enum CodingKeys: String, CodingKey`. Encode optional fields with
  `encodeIfPresent`.
- **Errors**: throw `MCPError` from protocol and transport code: `.invalidParams` for bad input,
  `.methodNotFound` for unsupported capabilities, `.invalidRequest` for lifecycle violations, and
  `.internalError` otherwise, with a short message. OAuth failures use `OAuthAuthorizationError`.
  Don't swallow errors silently. If an error is intentionally ignored, log it and explain why.
- **Logging**: use the transport's swift-log `Logger`. Labels follow `mcp.transport.<kind>`, and the
  default logger is a no-op. Use `trace` for per-message events, `debug` for lifecycle events,
  `warning` for unexpected input, and `error` for failures. Put structured values in `metadata:`.
  Never log tokens, secrets, or authorization headers.
- **Security-sensitive code** (`Authorization/`, `HTTPRequestValidation.swift`): validate URLs and
  inputs with the existing validators. Keep secrets out of errors and logs, and add tests for each
  rejected input.

## Security

Report vulnerabilities privately through GitHub Security Advisories, as described in
[SECURITY.md](SECURITY.md). Don't report them in public issues, discussions, or pull requests.

## License

By contributing, you agree that new contributions are licensed under Apache 2.0. Existing code
remains under MIT. See [LICENSE](LICENSE).
