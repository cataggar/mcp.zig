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
