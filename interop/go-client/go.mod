// The Go side of the interop matrix (interop/README.md). The Go SDK is a
// pinned release from the module proxy; its conformance server and examples
// are tools of this module, so scripts/run-interop.sh builds them at the
// same version.
module interop/go-client

go 1.25.0

require github.com/modelcontextprotocol/go-sdk v1.8.0

require (
	github.com/google/jsonschema-go v0.4.3 // indirect
	github.com/segmentio/asm v1.1.3 // indirect
	github.com/segmentio/encoding v0.5.4 // indirect
	github.com/yosida95/uritemplate/v3 v3.0.2 // indirect
	golang.org/x/oauth2 v0.35.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/time v0.15.0 // indirect
)

tool (
	github.com/modelcontextprotocol/go-sdk/conformance/everything-server
	github.com/modelcontextprotocol/go-sdk/examples/client/listfeatures
	github.com/modelcontextprotocol/go-sdk/examples/server/hello
)
