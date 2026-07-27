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

## Using Tools

### List Available Tools

```zig
const tools = try client.listTools(io, allocator);
defer tools.deinit();

for (tools.get("tools").?.array.items) |tool| {
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
try client.listResources(io, allocator);
```

### Read a Resource

```zig
try client.readResource(io, allocator, "file:///data.json");
```

## Using Prompts

### List Prompts

```zig
try client.listPrompts(io, allocator);
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
const tools = try client.listTools(io, allocator);
defer tools.deinit();

// `get` reads a field of the result object.
const list = tools.get("tools") orelse return error.MissingTools;
for (list.array.items) |tool| { ... }
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

Messages that are not the awaited response are currently discarded, so
server-initiated requests (sampling, elicitation, `roots/list`) are not yet
answered.

## Managing Roots

Roots define the file system areas the client has access to:

```zig
try client.addRoot(allocator, "file:///home/user/project", "Project Root");
try client.addRoot(allocator, "file:///home/user/data", "Data Directory");
```

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
    const tools = try client.listTools(io, allocator);
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
