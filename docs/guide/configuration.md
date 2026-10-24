# Server Configuration Files

Every MCP host reads the same de-facto configuration schema: an `mcpServers`
object mapping a server name to how that server is reached. `mcp.config`
parses that object.

It parses and nothing else. It does not decide where the file lives, does not
read it from disk, and does not connect — where configuration belongs is a host
policy decision, and hosts disagree. You supply bytes and a label; you get back
specs that drop straight into a connect call.

```zig
const mcp = @import("mcp");

const bytes = try dir.readFileAlloc(io, "mcp-config.json", allocator, .limited(1 << 20));
defer allocator.free(bytes);

var doc = try mcp.config.parse(allocator, bytes, "mcp-config.json");
defer doc.deinit();

for (doc.diagnostics) |problem| std.log.warn("{s}", .{problem});

for (doc.servers) |spec| {
    if (!spec.enabled) continue;
    switch (spec.transport) {
        .stdio => try client.connectStdioOptions(io, allocator, spec.command.?, spec.stdioOptions()),
        .http, .sse => try client.connectHttpOptions(io, allocator, spec.url.?, spec.httpOptions()),
    }
}
```

`Document.deinit` frees everything at once — the specs are arena-backed, so no
field needs to be freed individually. They are only valid while the `Document`
lives.

## Schema

```json
{
  "mcpServers": {
    "files": {
      "command": "mcp-files",
      "args": ["--root", "/srv"],
      "env": { "MCP_FILES_LOG": "debug" },
      "tools": ["read_file"]
    },
    "remote": {
      "type": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer …" }
    },
    "retired": { "command": "old-server", "enabled": false }
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `type` | string | `stdio`/`local`, `http`/`streamable-http`/`remote`, or `sse`. Inferred when absent. |
| `command` | string | Executable to spawn. Required for `stdio`. |
| `args` | string[] | Arguments passed to `command`. |
| `env` | object | Environment variables layered onto the child's environment. |
| `url` | string | Endpoint. Required for `http` and `sse`. |
| `headers` | object | Extra request headers. Ignored (and flagged) for `stdio`. |
| `tools` | string[] | Allow-list of tools the host may expose. Empty means all. |
| `enabled` / `disabled` | bool | Turns an entry off without deleting it. |

When `type` is absent, a `command` implies `stdio` and a `url` implies `http`.
An entry with neither is rejected.

## One Bad Entry Does Not Sink the File

A typo in one server should not disconnect every other server a user has
configured, so each entry is parsed independently. A malformed one is dropped
and described in `diagnostics`; the rest still load.

```zig
var doc = try mcp.config.parse(allocator, bytes, "mcp-config.json");
defer doc.deinit();
// doc.servers holds the entries that parsed; doc.diagnostics explains the rest.
```

`parse` returns an error only when the document as a whole is unusable:

| Error | Cause |
|---|---|
| `error.InvalidJson` | The bytes are not JSON. |
| `error.InvalidConfig` | The root, or `mcpServers`, is not an object. |

## Headers Are Validated at Parse Time

Configuration files are an untrusted-input boundary. Header names must be RFC
9110 tokens, values may not contain CR, LF or NUL, and the four headers the
transport builds itself (`Content-Type`, `Accept`, `MCP-Protocol-Version`,
`Mcp-Session-Id`) cannot be overridden. This is the same rule
`HttpTransport.setExtraHeaders` applies, checked early so a header that could
never be sent is reported next to the file that defines it.

Diagnostics name the offending header or variable but **never quote its
value**. `Authorization` headers and API keys live in these fields, and
diagnostics routinely end up in logs.

## `${VAR}` Is Not Expanded

Substitution is a host policy decision, not a parsing one — which variables are
readable, and whether a missing one is fatal, differs per host. `parse` passes
placeholders through verbatim and records a diagnostic, because a literal
`Bearer ${GITHUB_TOKEN}` on the wire fails in a way that looks like a server
bug.

Hosts that want expansion should do it on `spec.headers` / `spec.env` before
connecting.

## Layered Configuration

Hosts commonly merge a user-level file, a project-level file and a local
override. `merge` resolves that by name, later documents winning:

```zig
const specs = try mcp.config.merge(allocator, &.{ user_doc, project_doc, local_doc });
defer allocator.free(specs);
```

The result borrows from the input documents, so each must outlive it. Each spec
keeps the `source` label it was parsed with, so a later diagnostic can name the
file the winning definition actually came from.

## API

```zig
pub const Transport = enum { stdio, http, sse };

pub const ServerSpec = struct {
    name: []const u8,
    source: []const u8,
    transport: Transport,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    url: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    allowed_tools: []const []const u8 = &.{},
    enabled: bool = true,

    pub fn stdioOptions(self: ServerSpec) Client.StdioOptions;
    pub fn httpOptions(self: ServerSpec) Client.HttpOptions;
};

pub const Document = struct {
    servers: []ServerSpec,
    diagnostics: []const []const u8,

    pub fn deinit(self: Document) void;
    pub fn find(self: Document, name: []const u8) ?ServerSpec;
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, source_label: []const u8) !Document;
pub fn merge(allocator: std.mem.Allocator, docs: []const Document) ![]ServerSpec;
```
