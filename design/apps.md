# MCP Apps (SEP-1865)

MCP Apps lets a server deliver an interactive HTML view that renders a tool's results. A view is
a resource with a `ui://` URI; a tool refers to it in `_meta.ui`. The host renders the view in a
sandboxed frame, and the view talks to the host with JSON-RPC (the View-Host bridge).

Source: the `io.modelcontextprotocol/ui` extension, `modelcontextprotocol/ext-apps` at `v2.0.4`
(`7af9a75da720b8a81be0f9aff47b25f75e9530ad`, 2026-10-27), `specification/draft/apps.mdx`. The
stable text, `specification/2026-01-26/apps.mdx`, has the same wire for what the SDK implements;
the draft adds metadata on the `resources/list` entry and `object-src 'none'` in the default
policy. The reference helpers are `src/server/index.ts` and `src/spec.types.ts`.

The SDK implements the wire between server and host. It does not render views and does not
implement the bridge.

## Types

`Base/AppTypes.swift`:

| Type | Wire |
|---|---|
| `ExtensionID.ui` | `io.modelcontextprotocol/ui` |
| `UIExtensionSettings` | the client's `extensions[ui]`: `mimeTypes` (required by the specification) |
| `UIResourceMeta` | `_meta.ui` of a view: `csp`, `permissions`, `domain`, `prefersBorder` |
| `UIResourceMeta.CSP` | `connectDomains`, `resourceDomains`, `frameDomains`, `baseUriDomains` |
| `UIResourceMeta.Permissions` | `camera`, `microphone`, `geolocation`, `clipboardWrite`: presence flags, `{}` on the wire |
| `ToolUIMeta` | `_meta.ui` of a tool: `resourceUri`, `visibility` |
| `ToolUIMeta.Visibility` | open struct: `.model`, `.app` |

The accessors `Tool.ui`, `Resource.ui` and `Resource.Content.ui` read and write `_meta.ui`. The
raw `_meta` stays the source of truth: the setters write the known fields and keep the other
keys of `_meta` and of `_meta.ui`; `nil` removes `_meta.ui`. Decoding is lenient: a field of the
wrong type reads as absent, so a peer's new or malformed field does not hide the rest.

The flat key `_meta["ui/resourceUri"]` is deprecated and goes away before GA. `Tool.ui` reads it
when `_meta.ui` has no `resourceUri`; the setter removes it and never writes it. The ext-apps
helpers write both keys.

`isVisibleToModel` and `isCallableFromApp` are `true` when `visibility` is absent. An empty list,
or only unknown values, makes both `false`.

## Server

`Server.withAppResources(_:listInResources:)` (`Server/Apps.swift`) serves `UIResource`s:
validated `ui://` URIs (in lowercase, as the extension writes them: a view is found by its exact
URI), HTML as text or bytes, and one
`UIResourceMeta`, which goes on both the listing entry and the content item. The specification
recommends the content item; the listing entry lets a host review the metadata before it reads
the view. The MIME type is always `text/html;profile=mcp-app`: the specification reserves other
types for later extensions.

Views share the built-in resource path with skills (`Server/BuiltInResources.swift`): ordered
sources (views, then skills) answer `resources/read` before the application's handler, and join
the first `resources/list` page. Later pages continue the application's listing, then each
source in order. One cursor (`mcp-resources:` and base64 JSON) holds every position; it replaces
the skills-only cursor. A merged page has the shortest `ttlMs` of the pages it joins, and
`cacheScope: private` when any of them is private, so no entry is cached longer or more widely
than its own page allows. A `ui://` URI that no view has goes to the application's handler, which
can serve views that change.

The server declares `extensions[ui] = {}` and the `resources` capability. The specification
defines only the client's settings; the server's declaration tells a client that the server
knows the extension, and costs nothing.

`HandlerContext.clientUISettings` is what the client declared: at 2025-11-25 from `initialize`,
at 2026-07-28 from the request's `_meta`. SEP-2567 forbids lists that vary per connection, not per
request input, but a shared cache serves one list to every client (SEP-2549). A `tools/list` that
depends on the declared settings should therefore have `cacheScope: private`. The guides
recommend listing the same tools for every client, with text `content` for hosts without views.

## Client

`Client.Capabilities.ui` writes `extensions[ui]`.

`Client.readAppResource(uri:listing:)` (`Client/ClientApps.swift`):

1. A URI that is not `ui://` throws `AppResourceError.notUIResource` without a request.
2. `resources/read`; the content item with the requested URI.
3. The MIME type must be `text/html` with `profile=mcp-app`. Case, whitespace around `;` and
   `=`, quotes and other parameters are accepted.
4. `text`, or a `blob` of base64-encoded UTF-8.
5. The effective metadata is the content item's `_meta.ui`, or, when it has none, the listing
   entry's: the whole value, not a merge of fields (`resource._meta?.ui ??
   listingResource._meta?.ui` in the specification). A content `_meta.ui` that is present but
   not an object is kept, as `??` keeps it: the metadata is `nil`, and the policy the
   restrictive default. Without a `listing` argument the client
   reads up to 100 `resources/list` pages, and stops at a repeated cursor.

## Content Security Policy

`UIResourceMeta.CSP.restrictiveDefault` is the policy that the specification requires without
`csp`:

```
default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; media-src 'self' data:; object-src 'none'; connect-src 'none'
```

`CSP.policy()` is the construction of the specification's Security section, with the declared
origins after the fixed sources: `connect-src 'self'`, `font-src 'self'`, `frame-src 'none'` and
`base-uri 'self'` when the lists are empty. The two texts differ for an empty `connectDomains`
(`'none'` without `csp`, `'self'` with it); the SDK follows each text. The reference host
(`examples/basic-host`) is looser (`'unsafe-eval'`, `blob:`, `worker-src`); the SDK does not copy
it.

An origin that contains whitespace, a control character, `;`, `,`, `'` or `"` is dropped, as the
reference host's `sanitizeCspDomains` does: otherwise a server could add a directive or a source
keyword, which "MUST NOT allow undeclared domains" forbids. `Permissions.policyFeatures` gives
the Permissions Policy names (`clipboard-write` for `clipboardWrite`) for the frame's `allow`
attribute, which separates them with `;`.

## Interop

The interop `apps` profile (`interop/README.md`) runs the Swift, Go, Python and TypeScript
clients against the Swift everything-server and a TypeScript server on the ext-apps 1.7.5 server
helpers (`registerAppTool`, `registerAppResource`, `getUiCapability`). Each client declares the
extension and checks the tools' `_meta.ui`, the listing and content metadata, and that the server
saw the declaration. ext-apps 2.x needs the TypeScript SDK v2 packages, which, like 1.x, serve
2025-11-25 only; 1.7.5 runs on the SDK that the interop already pins.

## Not implemented

- The View-Host bridge: `ui/initialize` and the host context, `ui/notifications/*`, the view's
  `tools/call` with visibility enforced, sampling through the host, size and display modes, and
  app-provided tools. It needs a `WKWebView` transport (Apple platforms only) and, for web hosts,
  the sandbox proxy. Recorded in ROADMAP "Planned".
- Rendering, and checks of `domain`, whose format each host defines.

## Open questions

- The extension evolves on its own schedule; the flat key goes away before GA. Pin a new commit
  and update this note and the comment at the top of `AppTypes.swift`.
- The conformance harness has no MCP Apps scenario.
