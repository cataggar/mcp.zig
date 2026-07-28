# Supported Protocol Version

::: info Official Documentation
This library implements **Model Context Protocol (MCP) version 2025-11-25**.
For the official MCP changelog and full specification, please visit [modelcontextprotocol.io](https://modelcontextprotocol.io/).
:::

## Key Changes in Protocol 2025-11-25

The following changes were introduced in the MCP specification revision 2025-11-25:

## Major changes

- Enhance authorization server discovery with support for **OpenID Connect Discovery 1.0**.
- Allow servers to expose **icons** as additional metadata for tools, resources, resource templates, and prompts.
- Enhance authorization flows with **incremental scope consent** via `WWW-Authenticate`.
- Provide guidance on **tool names**.
- Update `ElicitResult` and `EnumSchema` to use a more standards-based approach and support titled, untitled, single-select, and multi-select enums.
- Added support for **URL mode elicitation**.
- Add tool calling support to **sampling** via `tools` and `toolChoice` parameters.
- Add support for **OAuth Client ID Metadata Documents** as a recommended client registration mechanism.
- Add experimental support for **tasks** to enable tracking durable requests with polling and deferred result retrieval.

## Minor changes

- Clarify that servers using stdio transport may use **stderr** for all types of logging, not just error messages.
- Add optional `description` field to `Implementation` interface to align with MCP registry `server.json` format and provide human-readable context during initialization.
- Clarify that servers must respond with `HTTP 403 Forbidden` for invalid Origin headers in Streamable HTTP transport.
- Updated the **Security Best Practices** guidance.
- Clarify that input validation errors should be returned as Tool Execution Errors rather than Protocol Errors to enable model self-correction.
- Support polling SSE streams by allowing servers to disconnect at will.
- Clarify GET streams support polling, resumption always via GET regardless of stream origin, event IDs should encode stream identity, disconnection includes server-initiated closure.
- Align OAuth 2.0 Protected Resource Metadata discovery with RFC 9728, making `WWW-Authenticate` header optional with fallback to `.well-known` endpoint.
- Add support for default values in all primitive types (string, number, enum) for elicitation schemas.
- Establish **JSON Schema 2020-12** as the default dialect for MCP schema definitions.

## Other schema changes

- Decouple request payloads from RPC method definitions into standalone parameter schemas.

## Governance and process updates

- Formalize Model Context Protocol governance structure.
- Establish shared communication practices and guidelines for the MCP community.
- Formalize Working Groups and Interest Groups in MCP governance.
- Establish SDK tiering system with clear requirements for feature support and maintenance commitments.

## Choosing which versions a server speaks

By default a server speaks every revision in `protocol.SUPPORTED_VERSIONS`
and follows the spec's negotiation rule: when a client asks for a version it
does not know, it replies with the newest version it *does* know and lets the
client decide whether to continue.

A host whose behaviour is only defined on one revision can say so:

```zig
var server: mcp.Server = .init(allocator, .{
    .name = "my-server",
    .version = "1.0.0",
    .supported_protocol_versions = &.{"2025-11-25"},
    .strict_protocol_version = true,
});
```

- `supported_protocol_versions` — the set this server will speak, newest
  first. `null` (the default) means the library's full list. The first entry is
  what the server advertises when negotiating down, and the whole set is what
  an `MCP-Protocol-Version` request header is validated against.
- `strict_protocol_version` — when `true`, a client asking for a version
  outside the set fails the handshake with `-32602 Unsupported protocol
  version` (the `data` member lists what would work) instead of being
  negotiated down.

`protocolVersion` is a required member of the handshake, so a request that
omits it is answered `-32602 Invalid params` rather than being negotiated to
the server's preferred revision — otherwise the pin could be sidestepped by
leaving the field out. A refused handshake also leaves the session
uninitialized, so it buys no access to the rest of the method surface.

The two are independent. Pinning without `strict_protocol_version` narrows
what the server advertises and accepts on the wire while still negotiating
down politely; `strict_protocol_version` without pinning simply rejects
revisions the library has never heard of.

Note that pinning also tightens the HTTP header check. A request carrying no
`MCP-Protocol-Version` is read as `2025-03-26`, per the spec, so a server
pinned to a newer revision will answer such a request `400` — which is the
point: an old client cannot silently be served.
