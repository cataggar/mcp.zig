# Server

The Server is the main runtime component for exposing MCP capabilities to AI clients.

## Creating a Server

```zig
const mcp = @import("mcp");

var server: mcp.Server = .init(allocator, .{
    .name = "my-server",
    .version = "1.0.0",
});
defer server.deinit();
```

## Configuration

| Option | Type | Description |
| --- | --- | --- |
| name | []const u8 | Server name (required) |
| version | []const u8 | Server version (required) |
| title | ?[]const u8 | Human-readable title |
| description | ?[]const u8 | Server description |
| icons | ?[]const mcp.types.Icon | Optional icon list |
| websiteUrl | ?[]const u8 | Optional website URL |
| instructions | ?[]const u8 | Optional server usage instructions |
| page_size | usize | Maximum items per `*/list` response. `0` (default) returns everything in one page. |
| max_tool_workers | usize | Threads that run `tools/call` off the message loop. `0` (default) keeps the loop strictly sequential. |

### Pagination

With `page_size` set, `tools/list`, `resources/list`,
`resources/templates/list` and `prompts/list` return at most that many items
and a `nextCursor`, which the client passes back as `params.cursor`.

Entries are ordered by name before paging. Hash map iteration order is not
stable across insertions, so paging over the raw order could skip or repeat
entries whenever a component is registered mid-walk; a total order makes
"everything after X" well defined regardless. It also means a cursor whose key
has since been removed resumes correctly instead of stranding the walk.

Cursors are opaque (base64url of an internal key). One the server never issued
is answered with `-32602 Invalid cursor`; it does not drop the connection.

`page_size = 0` is the historical behaviour and never emits `nextCursor`.

### Concurrent tool calls

By default the message loop is strictly sequential: a tool that takes ten
seconds to answer stalls every request behind it, including `ping` and
`notifications/cancelled`. Setting `max_tool_workers` starts that many threads
and routes `tools/call` requests to them:

```zig
var server = mcp.Server.init(allocator, .{
    .name = "my-server",
    .version = "1.0.0",
    .max_tool_workers = 4,
});
```

Only `tools/call` is moved off the loop. Everything else — the handshake,
`ping`, cancellations — is still handled inline, so ordering during
initialization is preserved and a cancellation never queues up behind the call
it is meant to stop.

Admission is bounded rather than queued. When every worker is occupied the
next tool call is answered immediately with `-32000 Server busy` instead of
waiting in a queue the client cannot see:

```json
{"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"Server busy",
 "data":"all tool workers are occupied"}}
```

A client that gets this should retry; it means the server is saturated, not
that the request was wrong. Pick `max_tool_workers` to match how many tool
invocations you are willing to have running at once — an unbounded pool would
just move the failure from a clear error into memory exhaustion.

Writes to the transport are serialized, so replies from workers never
interleave with each other or with the loop. Responses may of course arrive
out of request order; JSON-RPC ids are what pair a response to its request.

Combine this with [contextual tool handlers](tools.md) so a long-running tool
can also be cancelled while it runs.

## Capabilities

Capabilities are enabled by registration and explicit toggles:

```zig
try server.addTool(tool);
try server.addResource(resource);
try server.addPrompt(prompt);

server.enableLogging();
server.enableCompletions();
server.enableTasks();
```

## Running the Server

### STDIO Transport

For command-line tools and local processes:

```zig
try server.run(io, allocator, .stdio);
```

### HTTP Transport

For local access over HTTP:

```zig
try server.run(io, allocator, .{ .http = .{ .host = "127.0.0.1", .port = 8080 } });
```

Binding anything other than loopback is opt-in and must be authenticated,
because an MCP server exposes every tool you have registered to whoever can
reach the port:

```zig
try server.run(io, allocator, .{ .http = .{
    .host = "0.0.0.0",
    .port = 8443,
    .allow_non_loopback = true,
    .auth_token = my_secret, // at least 32 characters
} });
```

Clients must then send `Authorization: Bearer <token>` on every request;
anything else is answered with `401`. A configuration that would expose tools
without authentication is rejected before the listener is created, so the
server refuses to start rather than starting insecurely.

Requests are also screened for browser origin. Anything carrying an `Origin`
header is rejected with `403` unless listed in `allowed_origins`, and the body
must be declared `application/json` or the request is rejected with `415`:

```zig
try server.run(io, allocator, .{ .http = .{
    .port = 8080,
    .allowed_origins = &.{"https://app.example.com"},
} });
```

Ordinary MCP clients are not browsers and send no `Origin`, so the empty
default is transparent for them while closing the door on web pages the user
happens to visit. Binding loopback is no defence here, because such a request
comes from the victim's own machine.

The HTTP mode accepts JSON-RPC POST requests at the root path.

### Driving the server yourself

If your program already owns its I/O — an editor extension, an existing HTTP
stack, or a test — you do not need a transport at all. `handleMessageAlloc`
takes one JSON-RPC message and returns everything the server produced:

```zig
const reply = try server.handleMessageAlloc(io, allocator, line);
defer reply.deinit();

if (reply.response()) |body| {
    // A request: `body` is the JSON-RPC response.
    try out.writeAll(body);
} else {
    // A notification: the server produced nothing to send back.
}
```

`Reply.messages` holds every message in the order the server produced it, so a
handler that emits progress notifications before its result is preserved
faithfully; `Reply.response()` is a convenience for the last one. All bytes are
allocated from the allocator you pass and freed by `reply.deinit()`.

This uses the implicit session, the same one stdio and custom transports use,
so the handshake and session state behave exactly as they do under `run`.

## Registering Components

### Tools

```zig
try server.addTool(.{
    .name = "calculate",
    .description = "Perform calculations",
    .handler = calcHandler,
});
```

### Resources

```zig
try server.addResource(.{
    .uri = "file:///data.json",
    .name = "Data File",
    .mimeType = "application/json",
    .handler = dataHandler,
});
```

### Prompts

```zig
try server.addPrompt(.{
    .name = "summarize",
    .description = "Summarize text",
    .handler = summarizeHandler,
});
```

## Error Handling

The server handles errors gracefully:

```zig
fn toolHandler(_: ?*anyopaque, _: std.Io, allocator: Allocator, args: ?std.json.Value) mcp.tools.ToolError!ToolResult {
    const message = mcp.tools.getString(args, "message") orelse {
        return mcp.tools.errorResult(allocator, "Missing required argument: message") catch return mcp.tools.ToolError.OutOfMemory;
    };

    return mcp.tools.textResult(allocator, message) catch return mcp.tools.ToolError.OutOfMemory;
}
```

### Request ids

A JSON-RPC id identifies one exchange, so the server tracks the ids it is
currently serving. A request that reuses an id while the original is still
outstanding is answered with `-32600 Duplicate request id` — otherwise two
responses would carry the same id and the client could not tell them apart.

The id is released as soon as its response is sent, so ordinary clients that
count from 1 and reuse ids across reconnects are unaffected; only genuinely
concurrent reuse is rejected. At most `Session.max_inflight_requests` (256)
requests may be in flight on one session; beyond that the server answers
`-32603 Too many requests in flight`.

### Methods outside the specification

A host built on this library may need methods MCP does not define — a
lifecycle `shutdown`, an editor-specific query, an internal health probe.
Register them rather than forking the dispatch:

```zig
fn shutdown(ctx: ?*anyopaque, _: std.Io, allocator: Allocator, _: ?std.json.Value) anyerror!std.json.Value {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.stop();

    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "stopped", .{ .bool = true });
    return .{ .object = result };
}

try server.onMethod("shutdown", &app, shutdown);
try server.onNotificationMethod("exit", &app, exit);
```

The returned `std.json.Value` becomes the JSON-RPC `result`, allocated from
the per-message arena. A handler that returns an error is answered `-32603`
with the error name, so a failing custom method cannot take the connection
down. A notification handler has nothing to reply to, so a failure is logged.

Three rules keep the registry from becoming a way to break the protocol:

- **Built-ins win, and cannot be shadowed.** The registry is consulted only
  after every specification method has declined. Registering a name the server
  answers itself returns `error.MethodReserved` — a registration that silently
  never runs is a worse outcome than being told no.
- **An unregistered method still answers `-32601`.** Nothing changes for
  clients that only speak MCP.
- **Registering the same method twice replaces the handler**, so re-registering
  during reconfiguration is safe.

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "demo-server",
        .version = "1.0.0",
        .description = "A demo MCP server",
    });
    defer server.deinit();

    // Register at least one tool/resource/prompt.
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input",
        .handler = echoHandler,
    });

    // Run
    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn echoHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = mcp.tools.getString(args, "text") orelse "No input";
    const result = try std.fmt.allocPrint(allocator, "Echo: {s}", .{text});

    return mcp.tools.textResult(allocator, result);
}
```

## Next Steps

- [Tools Guide](/guide/tools) - Creating powerful tools
- [Resources Guide](/guide/resources) - Exposing data resources
- [Examples](/examples/simple-server) - Complete server examples
