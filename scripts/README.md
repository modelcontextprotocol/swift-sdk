# MCP Swift SDK Conformance Testing

This directory contains scripts for running MCP conformance tests against the Swift SDK implementation.

## Prerequisites

- Node.js (version 20 or higher)
- Swift 6.0.3 or higher
- Built Swift executables (`mcp-everything-client` and `mcp-everything-server`)

## Running Conformance Tests

### Run all tests (client and server)

```bash
./scripts/run-conformance.sh
```

### Run only client tests

```bash
./scripts/run-conformance.sh --mode client
```

### Run only server tests

```bash
./scripts/run-conformance.sh --mode server
```

### Use a custom baseline file

```bash
./scripts/run-conformance.sh --baseline path/to/baseline.yml
```

## Baseline File

The `conformance-baseline.yml` file at the project root documents known test failures. This allows CI to pass while tracking which tests are not yet implemented or failing.

**Important:** If a test listed in the baseline starts passing, the CI will fail to remind you to remove it from the baseline (preventing stale baseline entries).

### Format

```yaml
client:
  - test-scenario-name
  - auth/test-name

server:
  - test-scenario-name
```

## CI Integration

Conformance tests run automatically in GitHub Actions on every PR and push to main. The CI workflow:

1. Builds both client and server executables
2. Runs client conformance tests
3. Starts the server in the background
4. Runs server conformance tests
5. Compares results against the baseline file

## Exit Codes

- **0**: Success (all tests pass or failures match baseline)
- **1**: Failure (regression detected or baseline is stale)

## Updating the Baseline

When implementing new features that fix failing tests:

1. Run conformance tests locally
2. Remove the now-passing tests from `conformance-baseline.yml`
3. Commit the updated baseline file with your changes

## Debugging

To see detailed test output:

```bash
# Run tests manually with npx
swift build
CLIENT_PATH="$(swift build --show-bin-path)/mcp-everything-client"
npx @modelcontextprotocol/conformance client --command "$CLIENT_PATH" --suite all
npx @modelcontextprotocol/conformance server --url http://localhost:3000/mcp --suite all
```

Available test suites:
- `all`: Run all conformance tests
- `core`: Core MCP functionality
- `extensions`: Optional MCP extensions
- `auth`: Authentication and authorization tests
- `metadata`: Metadata handling tests
