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
| `connection_timeout_s` | `30` | Read/write deadline per connection. `0` disables. |
| `shutdown_grace_ms` | `5000` | How long `shutdown` waits for in-flight connections to drain. |
| `reuse_address` | `true` | Sets `SO_REUSEADDR`, so a restart is not blocked by `TIME_WAIT`. |

Session limits are fields on `Server` rather than on the run config:

| Field | Default | Purpose |
| ----- | ------- | ------- |
| `max_sessions` | `256` | Concurrently tracked HTTP sessions. Further handshakes get `503`. |
| `session_idle_timeout_s` | `300` | Idle seconds before a session is reclaimed. |
| `max_tasks_per_session` | `256` | Tasks retained per session. |
| `max_connections` | `64` | HTTP connections served on their own thread at once. |

### Concurrency

Each accepted HTTP connection is served on its own thread, so one slow client
cannot stall the others behind it. Once `max_connections` connections are in
flight the accept loop serves the next one inline rather than spawning without
bound or refusing it, which caps thread growth while still making progress.

Requests against the *same* session are serialized: the session is locked for
the duration of a request, so two requests sharing an `Mcp-Session-Id` cannot
interleave their mutations of that session's tasks, log level or handshake.

A session that is being served is reference-counted, so a concurrent idle sweep
or `DELETE` unpublishes it immediately — no new request can find it — but frees
it only once the last in-flight request finishes.

Every accepted connection gets a `connection_timeout_s` read and write deadline,
so a client cannot hold a connection slot by dribbling out a request head. This
is best effort: a platform that rejects the socket option leaves the connection
without a deadline rather than refusing it.

### Shutdown

`Server.shutdown(io)` is safe to call from any thread:

```zig
server.shutdown(io); // e.g. from a signal handler thread
```

It marks the server as shutting down and shuts the listening socket down, which
unblocks a parked `accept`. Without that, a server with no traffic could not be
stopped at all, because the accept loop only re-checks state between
connections. `runHttp` then waits up to `shutdown_grace_ms` for in-flight
connections to finish before returning.

Repeated accept failures back off from 1 ms to a cap of 1 s rather than spinning.

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

| Endpoint | Method | Description             |
| -------- | ------ | ----------------------- |
| `/`      | POST   | JSON-RPC endpoint       |
| `/`      | DELETE | Terminate a session     |

### Sessions

Each client gets its own state. The handshake, the negotiated client info, the
log level set via `logging/setLevel` and any tasks belong to one session and are
invisible to every other client.

`initialize` is answered with an `Mcp-Session-Id` header. Every later request
must repeat that header, or the server answers `-32002 Server not initialized`;
an unrecognised or expired id is answered with `404`. The id is 32 bytes from
the secure random source, rendered as hex, and the session table is keyed by its
SHA-256 digest so a lookup never compares the value a client presented.

Treat the id as a credential: anything holding it can act as that client.

`stdio` and custom transports carry exactly one client, so they use a single
implicit session and need no header.

### HTTP Request Format

Send JSON-RPC payloads as `application/json` with HTTP `POST`:

```bash
# Handshake. The response carries the session id.
curl -sD - -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'

# Every later request repeats it.
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: <id from the handshake>" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Release the session early. Otherwise it expires on the idle timeout.
curl -X DELETE http://localhost:8080 -H "Mcp-Session-Id: <id>"
```

The response body contains the JSON-RPC response. `connectHttp` records and
replays the session id for you.

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

`StdioTransport` is a plain struct with defaults, so it is constructed with
`.{}` and configured by setting fields:

```zig
var stdio_transport: mcp.transport.StdioTransport = .{};
defer stdio_transport.deinit(allocator);
```

| Field | Default | Meaning |
|-------|---------|---------|
| `in` | `null` (this process's stdin) | Stream to read messages from |
| `out` | `null` (this process's stdout) | Stream to write messages to |
| `max_message_size` | 4 MiB | Largest single message accepted; a longer one fails with `MessageTooLarge` |

The defaults are what a **server** wants: it is spawned with its standard
streams already wired to its parent. A **client** that spawns a server must
instead point `in` at the child's stdout and `out` at the child's stdin:

```zig
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
});
var stdio_transport: mcp.transport.StdioTransport = .{
    .in = child.stdout.?,
    .out = child.stdin.?,
};
```

Messages are newline-delimited, and reads are buffered, so `receive` may pull
more than one message off the stream in a single syscall. The extra bytes are
retained and returned by the following `receive` calls.

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
