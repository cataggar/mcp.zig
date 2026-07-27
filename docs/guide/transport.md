# Transport

Transports handle the communication layer between MCP clients and servers.

## Available Transports

| Transport | Use Case        | Protocol     |
| --------- | --------------- | ------------ |
| **STDIO** | Local processes | stdin/stdout |
| **HTTP**  | Remote servers  | HTTP/HTTPS   |

## STDIO Transport

The most common transport for local MCP servers.

### Server Side

```zig
try server.run(io, allocator, .stdio);
```

### Client Side

```zig
try client.connectStdio(io, allocator, "./my-server", &.{});
```

### How It Works

1. Client spawns the server as a child process
2. Communication happens via stdin/stdout
3. JSON-RPC messages are exchanged line by line

### Message Format

Each message is a single line of JSON followed by a newline:

```
{"jsonrpc":"2.0","method":"initialize","id":1,"params":{...}}\n
```

## HTTP Transport

For remote MCP servers or web-based integration.

### Server Side

Loopback binds need no ceremony:

```zig
try server.run(io, allocator, .{ .http = .{ .port = 8080 } });
```

Exposing the server beyond this machine is opt-in and requires a token:

```zig
try server.run(io, allocator, .{ .http = .{
    .host = "0.0.0.0",
    .port = 8443,
    .allow_non_loopback = true,
    .auth_token = my_secret, // at least 32 characters
} });
```

| Field | Default | Meaning |
| ----- | ------- | ------- |
| `host` | `"localhost"` | Address to bind. Loopback forms (`localhost`, `127.0.0.0/8`, `::1`) need no opt-in. |
| `allow_non_loopback` | `false` | Required to bind any other address. |
| `auth_token` | `null` | Bearer token required on every request. Mandatory for non-loopback binds; minimum 32 characters. |
| `allowed_origins` | `&.{}` | Origins allowed to make browser-initiated requests. Empty rejects any request carrying `Origin`. |

When `auth_token` is set, every request must carry
`Authorization: Bearer <token>`; anything else is answered with `401` before
the body is read. The configuration is validated before the listener is
created, so a server that would expose tools without authentication refuses to
start.

### Browser-originated requests

Two checks run before authentication:

- Any request carrying an `Origin` header is rejected with `403` unless that
  origin is listed in `allowed_origins`. Ordinary MCP clients are not browsers
  and send no `Origin`, so the empty default is transparent for them.
- The body must be declared `application/json`, or the request is rejected with
  `415`. Parameters such as `; charset=utf-8` are fine.

The `Content-Type` requirement is what blocks cross-site requests, not merely a
formality. `text/plain`, `application/x-www-form-urlencoded` and
`multipart/form-data` are the CORS-*simple* content types, which browsers send
with **no preflight**. Requiring `application/json` forces a preflight that
this server never answers.

Binding loopback is no protection against either of these, because the request
originates from the victim's own browser.

### Client Side

```zig
try client.connectHttp(io, allocator, "http://localhost:8080");
```

### Endpoints

| Endpoint | Method | Description       |
| -------- | ------ | ----------------- |
| `/`      | POST   | JSON-RPC endpoint |

### HTTP Request Format

Send JSON-RPC payloads as `application/json` with HTTP `POST`:

```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

The response body contains the JSON-RPC response.

### Example Pattern

Most examples default to `stdio` and include optional HTTP run lines.
Switch to HTTP by changing the run call in the example source.

## Streamable HTTP (SSE)

If the client sends `Accept: text/event-stream`, the server responds with a
single Server-Sent Events payload containing the JSON-RPC response.

```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

## Custom Transports

Implement the `Transport` interface for custom transports:

```zig
const MyTransport = struct {
    pub fn send(self: *MyTransport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) !void {
        // Send the message
    }

    pub fn receive(self: *MyTransport, io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
        // Receive a message
    }

    pub fn close(self: *MyTransport) void {
        // Close the transport
    }

    pub fn transport(self: *MyTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send_wrapper,
                .receive = receive_wrapper,
                .close = close_wrapper,
            },
        };
    }
};
```

## Transport Options

### STDIO Options

```zig
const stdio_transport = mcp.transport.StdioTransport.init(allocator);
```

### HTTP Options

```zig
const http_transport = mcp.transport.HttpTransport.init(
    allocator,
    "http://localhost:8080",
);
```

## Best Practices

### STDIO

::: tip Recommended for

- Command-line tools
- Local development
- IDE integrations
- Desktop applications
  :::

### HTTP

::: tip Recommended for

- Remote servers
- Microservices
- Cloud deployments
- Multi-client scenarios
  :::

## Error Handling

```zig
const message = transport.receive(io, allocator) catch |err| {
    switch (err) {
        error.ConnectionClosed => {
            // Handle disconnect
        },
        error.EndOfStream => {
            // Handle graceful end of input
        },
        else => return err,
    }
};
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    // Create server
    var server: mcp.Server = .init(allocator, .{
        .name = "multi-transport-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Get transport mode from args
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse "stdio";

    if (std.mem.eql(u8, mode, "http")) {
        std.debug.print("Starting HTTP server on port 8080...\n", .{});
        try server.run(io, allocator, .{ .http = .{ .port = 8080 } });
    } else {
        std.debug.print("Starting STDIO server...\n", .{});
        try server.run(io, allocator, .stdio);
    }
}
```

## Next Steps

- [JSON-RPC Protocol](/guide/jsonrpc) - Understand the protocol
- [Error Handling](/guide/error-handling) - Handle transport errors
- [API Reference](/api/protocol#transport) - Transport API details
