# Hosting Multiple Servers

`Client` connects to exactly one server. An application that wants to offer a
model the union of several servers' tools has to keep the clients, decide what
happens when one of them is down, and invent a naming scheme so two servers
exporting `search` do not collide. `Host` does that.

```zig
var host: mcp.Host = .init(io, allocator, .{
    .name = "my-app",
    .version = "1.0.0",
});
defer host.deinit();

var doc = try mcp.config.parse(allocator, bytes, "mcp-config.json");
defer doc.deinit();

try host.addDocument(doc);
const ready = try host.startAll();
std.log.info("{d}/{d} servers ready", .{ ready, host.servers.items.len });

for (host.tools()) |tool| {
    std.log.info("{s} -> {s}.{s}", .{ tool.exposed_name, tool.server_name, tool.tool_name });
}

const result = try host.callTool(allocator, "mcp_files_read", args);
defer result.deinit();
```

The document must outlive the host: `args`, `env` and `headers` are read on
every start. Server names, commands and URLs are copied, so a spec whose
document is gone can still be inspected.

## Isolated Failure

The governing rule is that one server must not take the others down with it.

`startAll` never fails because of a server. A server that will not start is
left `.failed` with `lastError` set, and every other server still comes up;
the return value is how many are `.ready`.

```zig
const ready = try host.startAll();
for (host.servers.items) |server| {
    if (server.status == .failed) {
        std.log.warn("{s}: {s}", .{ server.spec.name, server.last_error.? });
    }
}
```

`startServer` targets one server and *does* return its error, since you asked
about that server specifically. Either way the host stays usable.

| Status | Meaning |
|---|---|
| `configured` | Registered, not started. |
| `disabled` | Turned off in configuration. `startAll` skips it; `startServer` returns `error.ServerDisabled`. |
| `ready` | Connected, tools published. |
| `failed` | The last start attempt failed; see `lastError`. |
| `stopped` | Was ready, then disconnected on request. |

## Tool Namespacing

Tools are published as `<prefix>_<server>_<tool>` (prefix `mcp` by default,
set with `HostConfig.tool_prefix`). Every character outside `[A-Za-z0-9]` is
escaped as `_xNN`, including `_` itself, so the two literal `_` separators are
the only ones in the result. The encoding is therefore **injective**: server
`a_b` tool `c` becomes `mcp_a_x5fb_c` while server `a` tool `b_c` becomes
`mcp_a_b_x5fc`, where a naive join would produce `mcp_a_b_c` for both. The
result also stays within the character set model-facing tool names are usually
restricted to.

Calls resolve through the published table rather than by decoding the name, so
the mapping back to (server, tool) is exact regardless of what the server used.

```zig
if (host.findTool(name)) |tool| {
    std.log.info("{s} is {s} on {s}", .{ name, tool.tool_name, tool.server_name });
}
```

`ExposedTool` also carries the tool's `description` and `inputSchema`,
borrowed from the server's `tools/list` response, which is what a host needs to
describe the tool to a model.

## Allow-Lists

A server entry's `tools` array restricts what the host will publish from it:

```json
{ "mcpServers": { "files": { "command": "mcp-files", "tools": ["read_file"] } } }
```

An **absent or empty** list means every tool, not none — a server with no
`tools` key would otherwise be silently muted. A tool that is filtered out is
not callable through `callTool` either; there is one gate, not two.

## Lifecycle

```zig
try host.stopServer("files");     // disconnect, withdraw its tools, keep config
try host.restartServer("files");  // e.g. after the server died
try host.refreshTools("files");   // on notifications/tools/list_changed
```

Publishing is all-or-nothing. `ExposedTool` borrows out of the `tools/list`
response, so the previously published tools stay live and stay published until
the replacement set is fully built. A refresh that fails leaves the server's
existing tools intact and callable rather than silently emptying it.

To refresh on demand, register the notification handler on the underlying
client:

```zig
const server = host.servers.items[host.findIndex("files").?];
try server.client.?.onNotification(
    allocator,
    "notifications/tools/list_changed",
    &host,
    onToolsChanged,
);
```

## Known Limitation: No Startup Timeout

A server that accepts a connection and then never answers `initialize` blocks
`startServer`, and with it `startAll`. Enforcing a wall-clock timeout needs
read deadlines at the transport layer, which stdio transports do not yet
expose. Until then, prefer servers you control or a transport that fails fast.

## API

```zig
pub const HostConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    tool_prefix: []const u8 = "mcp",
    server_stderr: std.process.SpawnOptions.StdIo = .ignore,
};

pub const Status = enum { configured, disabled, ready, failed, stopped };

pub const ExposedTool = struct {
    exposed_name: []const u8,
    tool_name: []const u8,
    server_name: []const u8,
    description: ?[]const u8,
    input_schema: ?std.json.Value,
    server_index: usize,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, config: HostConfig) Host
pub fn deinit(self: *Host) void

pub fn addServer(self: *Host, spec: ServerSpec) !void
pub fn addDocument(self: *Host, doc: config.Document) !void

pub fn startServer(self: *Host, name: []const u8) !void
pub fn startAll(self: *Host) !usize
pub fn stopServer(self: *Host, name: []const u8) !void
pub fn restartServer(self: *Host, name: []const u8) !void
pub fn refreshTools(self: *Host, name: []const u8) !void

pub fn tools(self: *const Host) []const ExposedTool
pub fn findTool(self: *const Host, exposed_name: []const u8) ?ExposedTool
pub fn callTool(self: *Host, allocator: std.mem.Allocator, exposed_name: []const u8, arguments: ?std.json.Value) !Response

pub fn status(self: *const Host, name: []const u8) ?Status
pub fn lastError(self: *const Host, name: []const u8) ?[]const u8
pub fn findIndex(self: *const Host, name: []const u8) ?usize
```

| Error | Cause |
|---|---|
| `error.DuplicateServer` | A server with that name is already registered. |
| `error.UnknownServer` | No server with that name. |
| `error.UnknownTool` | No tool published under that name. |
| `error.ServerDisabled` | The entry is turned off in configuration. |
| `error.ServerNotReady` | The owning server is not connected. |
