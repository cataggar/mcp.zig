# Client

The `Client` allows you to connect to MCP servers and interact with their capabilities.

## Creating a Client

```zig
const mcp = @import("mcp");

var client: mcp.Client = .init(io, allocator, .{
    .name = "my-client",
    .version = "1.0.0",
});
defer client.deinit(io, allocator);
```

## Configuration

| Option      | Type         | Description               |
| ----------- | ------------ | ------------------------- |
| `name`      | `[]const u8` | Client name (required)    |
| `version`   | `[]const u8` | Client version (required) |

## Connecting to a Server

### STDIO Transport

```zig
try client.connectStdio(io, allocator, "path/to/server", &.{});
```

### HTTP Transport

```zig
// Connect to localhost on port 8080
try client.connectHttp(io, allocator, "http://localhost:8080");

// Connect to a custom host and port
try client.connectHttp(io, allocator, "http://192.168.1.50:9000");
```

## Capabilities

### Enable Roots

```zig
client.enableRoots(true);
```

### Enable Sampling

```zig
client.enableSampling();
```

## Pagination

`*/list` methods are cursor-paginated. `listTools`, `listResources`,
`listResourceTemplates` and `listPrompts` each return **one page** and take a
`ListOptions` carrying the cursor:

```zig
var cursor: ?[]const u8 = null;
while (true) {
    const page = try client.listTools(io, allocator, .{ .cursor = cursor });
    defer page.deinit();
    // ...
    cursor = switch (page.get("nextCursor") orelse .null) {
        .string => |c| c,
        else => break,
    };
}
```

Most callers want everything, so prefer the `listAll*` helpers, which walk
every page and return the concatenated items:

```zig
const tools = try client.listAllTools(io, allocator);
defer tools.deinit();
for (tools.items) |tool| { ... }
```

`items` are views into the retained page responses, so they stay valid until
`deinit`. The walk is bounded: a server that repeats a cursor fails with
`error.CursorNotAdvancing` and one that never stops fails with
`error.TooManyPages`, rather than hanging the caller.

Cursors are opaque. Do not construct one; a cursor the server did not issue is
answered with `-32602 Invalid cursor`.

## Using Tools

### List Available Tools

```zig
const tools = try client.listAllTools(io, allocator);
defer tools.deinit();

for (tools.items) |tool| {
    std.debug.print("{s}\n", .{tool.object.get("name").?.string});
}
```

### Call a Tool

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

var args: std.json.ObjectMap = .empty;
try args.put(arena.allocator(), "name", .{ .string = "World" });

const result = try client.callTool(io, allocator, "greet", .{ .object = args });
defer result.deinit();

const text = result.get("content").?.array.items[0].object.get("text").?.string;
```

## Using Resources

### List Resources

```zig
try client.listAllResources(io, allocator);
```

### Read a Resource

```zig
try client.readResource(io, allocator, "file:///data.json");
```

## Using Prompts

### List Prompts

```zig
try client.listAllPrompts(io, allocator);
```

### Get a Prompt

```zig
var args: std.json.ObjectMap = .empty;
try args.put(allocator, "topic", .{ .string = "Zig programming" });

const prompt = try client.getPrompt(io, allocator, "summarize", .{ .object = args });
defer prompt.deinit();
```

## Handling Responses

Request methods return a `Response`. `result` is the JSON-RPC `result` member,
and it lives in the response's arena, so it is valid until `deinit`.

```zig
const tools = try client.listAllTools(io, allocator);
defer tools.deinit();

for (tools.items) |tool| { ... }
```

If the server replies with a JSON-RPC error, the call returns
`error.ServerError` and the details are on the client:

```zig
const result = client.callTool(io, allocator, "greet", null) catch |err| switch (err) {
    error.ServerError => {
        const e = client.last_error.?;
        std.debug.print("server said {d}: {s}\n", .{ e.code, e.message });
        return;
    },
    else => return err,
};
defer result.deinit();
```

## Handling Server-Initiated Traffic

The server can send the client requests (`sampling/createMessage`,
`elicitation/create`, `roots/list`) and notifications. They arrive interleaved
with the replies to the client's own requests, and are dispatched to handlers
registered by method:

```zig
fn sample(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) anyerror!std.json.Value {
    _ = params;
    var content: std.json.ObjectMap = .empty;
    try content.put(allocator, "type", .{ .string = "text" });
    try content.put(allocator, "text", .{ .string = "hello from the model" });

    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "role", .{ .string = "assistant" });
    try result.put(allocator, "content", .{ .object = content });
    try result.put(allocator, "model", .{ .string = "demo" });
    return .{ .object = result };
}

try client.onRequest(allocator, "sampling/createMessage", null, sample);
```

The returned value becomes the JSON-RPC `result`. It is built with the
allocator handed to the handler, which is an arena freed as soon as the reply
is serialized — nothing needs to be freed by the handler, and nothing may be
retained past it. The `ctx` pointer passed to `onRequest` is handed back
unchanged, which is how a handler reaches application state.

Notifications are registered the same way with `onNotification`; the handler
returns `void` because a notification has no reply.

```zig
try client.onNotification(allocator, "notifications/tools/list_changed", null, onToolsChanged);
```

Rules the client applies:

- A request with **no registered handler** is answered `-32601 Method not
  found`. A handler that **fails** is answered `-32603 Internal error`. Either
  way the server gets an answer rather than waiting forever.
- A notification with no handler is ignored, and a failing notification handler
  is swallowed — there is no channel to report it on.
- A reply belonging to a **different outstanding request** is parked and
  returned to whoever asks for that id next, so out-of-order replies are not
  lost. Up to 64 replies are parked; beyond that the oldest excess is dropped.

### Capabilities Require Handlers

`sampling` and `elicitation` are pure callbacks: a client that advertises them
without a handler tells the server it supports a feature it will then refuse.
`initialize` therefore fails with `error.MissingSamplingHandler` or
`error.MissingElicitationHandler` instead of completing a handshake that lies.
Register the handler before connecting:

```zig
try client.onRequest(allocator, "sampling/createMessage", null, sample);
client.enableSampling();
```

`roots` is exempt: it is answered by a built-in handler backed by the roots
registered with `addRoot`, so `enableRoots(true)` alone is enough. Registering
an explicit `roots/list` handler overrides the built-in one.

## Managing Roots

Roots define the file system areas the client has access to:

```zig
try client.addRoot(allocator, "file:///home/user/project", "Project Root");
try client.addRoot(allocator, "file:///home/user/data", "Data Directory");
```

With the `roots` capability enabled, a server-initiated `roots/list` is
answered from this list automatically.

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    if (run(init.io, init.gpa)) {
        // Success
    } else |err| {
        mcp.reportError(err);
    }
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client: mcp.Client = .init(io, allocator, .{
        .name = "demo-client",
        .version = "1.0.0",
    });
    defer client.deinit(io, allocator);

    // Enable capabilities
    client.enableRoots(true);

    // Add roots
    try client.addRoot(allocator, "file:///home/user/documents", "Documents");

    // Connect to a server
    try client.connectStdio(io, allocator, "./my-server", &.{});

    // List and call tools
    const tools = try client.listAllTools(io, allocator);
    defer tools.deinit();
    std.debug.print("Available tools: {d}\n", .{tools.get("tools").?.array.items.len});

    // Call a tool
    const result = try client.callTool(io, allocator, "hello", null);
    defer result.deinit();
    std.debug.print("Result: {f}\n", .{std.json.fmt(result.result, .{})});
}
```

## Next Steps

- [Server Guide](/guide/server) - Create servers to connect to
- [Tools Guide](/guide/tools) - Understand tool interactions
- [Examples](/examples/simple-client) - See complete client examples
