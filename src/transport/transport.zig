//! MCP Transport Layer
//!
//! Provides transport mechanisms for MCP client-server communication.
//! Supports STDIO transport for local process communication and HTTP
//! transport for remote server connections.

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const types = @import("../protocol/types.zig");

/// Generic transport interface for MCP communication.
/// Implementations must provide send, receive, and close operations.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) SendError!void,
        receive: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ReceiveError!?[]const u8,
        close: *const fn (ptr: *anyopaque) void,
        /// Release the implementation and the allocation holding it. Only
        /// valid for transports the caller handed ownership of.
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub const SendError = error{
        ConnectionClosed,
        WriteError,
        OutOfMemory,
    };

    pub const ReceiveError = error{
        ConnectionClosed,
        ReadError,
        MessageTooLarge,
        OutOfMemory,
        EndOfStream,
    };

    /// Sends a message through the transport.
    pub fn send(self: Transport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) SendError!void {
        return self.vtable.send(self.ptr, io, allocator, message);
    }

    /// Receives a message from the transport (blocking).
    pub fn receive(self: Transport, io: std.Io, allocator: std.mem.Allocator) ReceiveError!?[]const u8 {
        return self.vtable.receive(self.ptr, io, allocator);
    }

    /// Closes the transport connection.
    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }

    /// Releases the transport implementation and its allocation.
    pub fn deinit(self: Transport, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

/// STDIO transport for local process communication.
/// Messages are delimited by newlines and sent via stdin/stdout.
pub const StdioTransport = struct {
    /// Bytes pulled off the stream but not yet returned as a message. A
    /// buffered read can cross a newline, so the tail is kept here for the
    /// next `receive` rather than being re-read (it cannot be un-read).
    read_buffer: std.ArrayList(u8) = .empty,
    is_closed: bool = false,
    /// Set once the stream reports EOF, so a trailing message with no final
    /// newline is still delivered before `EndOfStream` is reported.
    at_end: bool = false,
    max_message_size: usize = 4 * 1024 * 1024,
    /// Stream to read messages from. `null` means this process's stdin, which
    /// is what a server wants. A client that spawns a server points this at
    /// the child's stdout instead.
    in: ?std.Io.File = null,
    /// Stream to write messages to. `null` means this process's stdout.
    out: ?std.Io.File = null,

    const Self = @This();

    /// Size of a single read syscall. Reading a byte at a time cost one
    /// syscall per byte, which dominated the cost of receiving a message.
    const read_chunk_size = 64 * 1024;

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.read_buffer.deinit(allocator);
    }

    /// Sends a JSON-RPC message to stdout with newline delimiter.
    pub fn send(self: *Self, io: std.Io, _: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        const out = self.out orelse std.Io.File.stdout();
        out.writeStreamingAll(io, message) catch return Transport.SendError.WriteError;
        out.writeStreamingAll(io, "\n") catch return Transport.SendError.WriteError;
    }

    /// Sends a JSON-RPC message object.
    pub fn sendMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        const json = try jsonrpc.serializeMessage(allocator, message);
        defer allocator.free(json);
        try self.send(io, allocator, json);
    }

    /// Removes and returns the next newline-delimited message already sitting
    /// in `read_buffer`, or null if it does not yet hold a whole one.
    fn takeBufferedMessage(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const idx = std.mem.indexOfScalar(u8, self.read_buffer.items, '\n') orelse return null;
        const message = try allocator.dupe(u8, self.read_buffer.items[0..idx]);
        const rest_start = idx + 1;
        const rest_len = self.read_buffer.items.len - rest_start;
        std.mem.copyForwards(u8, self.read_buffer.items[0..rest_len], self.read_buffer.items[rest_start..]);
        self.read_buffer.shrinkRetainingCapacity(rest_len);
        return message;
    }

    /// Receives a newline-delimited JSON-RPC message from the input stream.
    pub fn receive(self: *Self, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return Transport.ReceiveError.ConnectionClosed;

        if (try self.takeBufferedMessage(allocator)) |message| {
            if (message.len == 0) {
                allocator.free(message);
                return null;
            }
            return message;
        }

        const in = self.in orelse std.Io.File.stdin();

        while (true) {
            if (self.at_end) {
                // A final message with no trailing newline is still a message.
                if (self.read_buffer.items.len == 0) return Transport.ReceiveError.EndOfStream;
                const message = allocator.dupe(u8, self.read_buffer.items) catch {
                    return Transport.ReceiveError.OutOfMemory;
                };
                self.read_buffer.clearRetainingCapacity();
                return message;
            }

            var chunk: [read_chunk_size]u8 = undefined;
            // End of stream is reported as an error, not as a zero-length
            // read; the previous implementation mapped it to `ReadError` and
            // so never reported `EndOfStream` at all. A zero-length read is
            // also legal and does not mean the stream ended.
            const bytes_read = in.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => {
                    self.at_end = true;
                    continue;
                },
                else => return Transport.ReceiveError.ReadError,
            };
            if (bytes_read == 0) continue;

            // No newline is in the buffer at this point, so everything held is
            // one unterminated message and the cap applies to all of it.
            if (self.read_buffer.items.len + bytes_read > self.max_message_size) {
                return Transport.ReceiveError.MessageTooLarge;
            }
            self.read_buffer.appendSlice(allocator, chunk[0..bytes_read]) catch {
                return Transport.ReceiveError.OutOfMemory;
            };

            if (try self.takeBufferedMessage(allocator)) |message| {
                if (message.len == 0) {
                    allocator.free(message);
                    return null;
                }
                return message;
            }
        }
    }

    /// Closes the transport.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Writes a message to stderr for logging.
    pub fn writeStderr(_: *Self, io: std.Io, message: []const u8) void {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(io, message) catch {};
        stderr.writeStreamingAll(io, "\n") catch {};
    }

    /// Returns a Transport interface for this STDIO transport.
    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
                .deinit = deinitVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn deinitVtable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
        allocator.destroy(self);
    }
};

/// HTTP transport for remote server communication.
/// Sends requests via HTTP POST and receives responses.
pub const HttpTransport = struct {
    endpoint: []const u8,
    session_id: ?[]const u8 = null,
    authorization_token: ?[]const u8 = null,
    protocol_version: []const u8 = "2025-11-25",
    is_closed: bool = false,
    pending_responses: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    /// Initializes a new HTTP transport with the given endpoint URL.
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Self {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        return .{
            .endpoint = owned_endpoint,
        };
    }

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        for (self.pending_responses.items) |item| {
            allocator.free(item);
        }
        self.pending_responses.deinit(allocator);
        if (self.session_id) |sid| {
            allocator.free(sid);
        }
        if (self.authorization_token) |token| {
            allocator.free(token);
        }
    }

    /// Sends a JSON-RPC message via HTTP POST.
    pub fn send(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const uri = std.Uri.parse(self.endpoint) catch return Transport.SendError.WriteError;

        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(allocator);

        extra_headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" }) catch {
            return Transport.SendError.OutOfMemory;
        };
        extra_headers.append(allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" }) catch {
            return Transport.SendError.OutOfMemory;
        };
        extra_headers.append(allocator, .{ .name = "MCP-Protocol-Version", .value = self.protocol_version }) catch {
            return Transport.SendError.OutOfMemory;
        };

        var authorization_value: ?[]u8 = null;
        defer if (authorization_value) |owned| allocator.free(owned);

        if (self.authorization_token) |token| {
            authorization_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch {
                return Transport.SendError.OutOfMemory;
            };
            extra_headers.append(allocator, .{ .name = "Authorization", .value = authorization_value.? }) catch {
                return Transport.SendError.OutOfMemory;
            };
        }

        if (self.session_id) |sid| {
            extra_headers.append(allocator, .{ .name = "MCP-Session-Id", .value = sid }) catch {
                return Transport.SendError.OutOfMemory;
            };
        }

        // Do not follow redirects. This request carries a bearer token and a
        // session id, and both are credentials for *this* endpoint. Following a
        // `Location` would hand them to whatever host the response names.
        //
        // `privileged_headers` is not a way out: std stores it, asserts on it
        // and clears it across domains, but never writes it to the wire, so
        // putting credentials there drops them from every request instead.
        // Refusing the redirect is the only fail-closed option, and an MCP
        // client has a configured endpoint and no reason to be redirected off
        // it anyway.
        var req = client.request(.POST, uri, .{
            .headers = .{ .user_agent = .{ .override = "mcp.zig" } },
            .extra_headers = extra_headers.items,
            .redirect_behavior = .not_allowed,
        }) catch return Transport.SendError.WriteError;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = message.len };

        var body_writer = req.sendBodyUnflushed(&.{}) catch return Transport.SendError.WriteError;
        body_writer.writer.writeAll(message) catch return Transport.SendError.WriteError;
        body_writer.end() catch return Transport.SendError.WriteError;
        req.connection.?.flush() catch return Transport.SendError.WriteError;

        const redirect_buffer = allocator.alloc(u8, 8 * 1024) catch return Transport.SendError.OutOfMemory;
        defer allocator.free(redirect_buffer);

        var response = req.receiveHead(redirect_buffer) catch return Transport.SendError.WriteError;

        var content_type: ?[]const u8 = null;

        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                self.setSessionId(allocator, header.value) catch return Transport.SendError.OutOfMemory;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_type = header.value;
            }
        }

        var transfer_buffer: [1024]u8 = undefined;
        var reader = response.reader(&transfer_buffer);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&buf) catch return Transport.SendError.WriteError;
            if (n == 0) break;
            body.appendSlice(allocator, buf[0..n]) catch return Transport.SendError.OutOfMemory;
        }

        if (body.items.len == 0) return;

        if (content_type) |ctype| {
            if (std.mem.indexOf(u8, ctype, "text/event-stream") != null) {
                try self.enqueueSseEvents(allocator, body.items);
                return;
            }
        }

        const owned = allocator.dupe(u8, body.items) catch return Transport.SendError.OutOfMemory;
        self.pending_responses.append(allocator, owned) catch {
            allocator.free(owned);
            return Transport.SendError.OutOfMemory;
        };
    }

    /// Receives a response from the pending queue.
    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return Transport.ReceiveError.ConnectionClosed;

        if (self.pending_responses.items.len > 0) {
            return self.pending_responses.orderedRemove(0);
        }
        return null;
    }

    /// Closes the transport.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Sets the session ID from the MCP-Session-Id header.
    pub fn setSessionId(self: *Self, allocator: std.mem.Allocator, session_id: []const u8) !void {
        if (self.session_id) |old| {
            allocator.free(old);
        }
        self.session_id = try allocator.dupe(u8, session_id);
    }

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, allocator: std.mem.Allocator, token: []const u8) !void {
        if (self.authorization_token) |old| {
            allocator.free(old);
        }
        self.authorization_token = try allocator.dupe(u8, token);
    }

    fn enqueueSseEvents(self: *Self, allocator: std.mem.Allocator, body: []const u8) !void {
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(allocator);

        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) {
                if (current.items.len > 0) {
                    const owned = try allocator.dupe(u8, current.items);
                    try self.pending_responses.append(allocator, owned);
                    current.clearRetainingCapacity();
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "data:")) {
                var data_line = line[5..];
                if (data_line.len > 0 and data_line[0] == ' ') data_line = data_line[1..];
                if (current.items.len > 0) {
                    try current.append(allocator, '\n');
                }
                try current.appendSlice(allocator, data_line);
            }
        }

        if (current.items.len > 0) {
            const owned = try allocator.dupe(u8, current.items);
            try self.pending_responses.append(allocator, owned);
        }
    }

    /// Returns a Transport interface for this HTTP transport.
    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
                .deinit = deinitVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn deinitVtable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Transport type selection.
pub const TransportType = enum {
    stdio,
    http,
};

/// Creates a transport based on the specified type.
pub fn createTransport(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport_type: TransportType,
    options: TransportOptions,
) !Transport {
    _ = io;
    switch (transport_type) {
        .stdio => {
            const stdio = try allocator.create(StdioTransport);
            stdio.* = .{};
            return stdio.transport();
        },
        .http => {
            const url = options.url orelse return error.MissingUrl;
            const http_transport = try allocator.create(HttpTransport);
            http_transport.* = try .init(allocator, url);
            if (options.authorization_token) |token| {
                try http_transport.setAuthorizationToken(allocator, token);
            }
            return http_transport.transport();
        },
    }
}

/// Options for transport creation.
pub const TransportOptions = struct {
    url: ?[]const u8 = null,
    authorization_token: ?[]const u8 = null,
};

test "StdioTransport initialization" {
    var transport_impl: StdioTransport = .{};
    _ = &transport_impl;

    try std.testing.expect(!transport_impl.is_closed);
}

test "HttpTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try std.testing.expectEqualStrings("http://localhost:3000", transport_impl.endpoint);
}

test "HttpTransport session ID" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try transport_impl.setSessionId(allocator, "test-session-123");
    try std.testing.expectEqualStrings("test-session-123", transport_impl.session_id.?);
}

/// A minimal HTTP origin used to exercise `HttpTransport` against a real
/// socket. Serves one reply per connection and records the request head.
const TestHttpOrigin = struct {
    listener: *std.Io.net.Server,
    replies: []const []const u8,
    captured: [4][]u8 = @splat(&.{}),
    captured_count: usize = 0,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestHttpOrigin) void {
        for (self.captured[0..self.captured_count]) |c| self.allocator.free(c);
    }

    /// Connections that carried a real request, ignoring the sentinel used to
    /// release a pending `accept`.
    fn requestCount(self: *const TestHttpOrigin) usize {
        var n: usize = 0;
        for (self.captured[0..self.captured_count]) |c| {
            if (std.mem.indexOf(u8, c, "HTTP/1.1") != null) n += 1;
        }
        return n;
    }

    fn run(self: *TestHttpOrigin) void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        for (self.replies) |reply| {
            var stream = self.listener.accept(io) catch return;
            defer stream.close(io);

            var recv_buffer: [4096]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &recv_buffer);
            var writer = stream.writer(io, &send_buffer);

            // Only the head matters for these assertions.
            var head: std.ArrayList(u8) = .empty;
            defer head.deinit(self.allocator);
            while (std.mem.indexOf(u8, head.items, "\r\n\r\n") == null) {
                var byte: [1]u8 = undefined;
                const n = reader.interface.readSliceShort(&byte) catch break;
                if (n == 0) break;
                head.append(self.allocator, byte[0]) catch break;
            }

            if (self.captured_count < self.captured.len) {
                self.captured[self.captured_count] = self.allocator.dupe(u8, head.items) catch &.{};
                self.captured_count += 1;
            }

            writer.interface.writeAll(reply) catch {};
            writer.interface.flush() catch {};
        }
    }
};

/// Bind a loopback listener on the first free port at or above `base_port`.
fn bindTestListener(io: std.Io, base_port: u16, out_port: *u16) !std.Io.net.Server {
    var attempt: u16 = 0;
    while (attempt < 40) : (attempt += 1) {
        const port = base_port + attempt;
        const address = std.Io.net.IpAddress.resolve(io, "127.0.0.1", port) catch continue;
        const listener = std.Io.net.IpAddress.listen(&address, io, .{}) catch continue;
        out_port.* = port;
        return listener;
    }
    return error.NoFreePort;
}

test "HttpTransport sends credentials and records the issued session id" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var port: u16 = 0;
    var listener = try bindTestListener(io, 39100, &port);
    defer listener.deinit(io);

    const replies = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nmcp-session-id: issued-session\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}",
    };
    var origin: TestHttpOrigin = .{
        .listener = &listener,
        .replies = &replies,
        .allocator = allocator,
    };
    defer origin.deinit();

    const thread = try std.Thread.spawn(.{}, TestHttpOrigin.run, .{&origin});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(endpoint);

    var transport_impl = try HttpTransport.init(allocator, endpoint);
    defer transport_impl.deinit(allocator);
    try transport_impl.setAuthorizationToken(allocator, "test-token");

    try transport_impl.send(io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");

    try std.testing.expectEqual(@as(usize, 1), origin.captured_count);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(origin.captured[0], "authorization: Bearer test-token") != null);

    // The id the server issued must be recorded for subsequent requests.
    try std.testing.expectEqualStrings("issued-session", transport_impl.session_id.?);
}

test "HttpTransport refuses to follow a redirect" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var port: u16 = 0;
    var listener = try bindTestListener(io, 39200, &port);
    defer listener.deinit(io);

    // A server that answers with a `Location` it controls would otherwise be
    // handed the bearer token and the session id on the next hop.
    var redirect_buf: [256]u8 = undefined;
    const redirect_reply = try std.fmt.bufPrint(
        &redirect_buf,
        "HTTP/1.1 303 See Other\r\nLocation: http://localhost:{d}/steal\r\nContent-Length: 0\r\n\r\n",
        .{port},
    );
    const replies = [_][]const u8{
        redirect_reply,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}",
    };
    var origin: TestHttpOrigin = .{
        .listener = &listener,
        .replies = &replies,
        .allocator = allocator,
    };
    defer origin.deinit();

    const thread = try std.Thread.spawn(.{}, TestHttpOrigin.run, .{&origin});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(endpoint);

    var transport_impl = try HttpTransport.init(allocator, endpoint);
    defer transport_impl.deinit(allocator);
    try transport_impl.setAuthorizationToken(allocator, "test-token");
    try transport_impl.setSessionId(allocator, "secret-session");

    try std.testing.expectError(
        Transport.SendError.WriteError,
        transport_impl.send(io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"),
    );

    // The origin is willing to serve a second hop, so a regression that starts
    // following redirects again fails the assertion below instead of hanging
    // here. Release the pending accept with a connection that sends nothing.
    {
        const sentinel_address = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
        var sentinel = try std.Io.net.IpAddress.connect(&sentinel_address, io, .{ .mode = .stream });
        sentinel.close(io);
    }

    // Exactly one hop: the redirect was never followed, so the credentials
    // were never offered to the redirect target.
    try std.testing.expectEqual(@as(usize, 1), origin.requestCount());
    try std.testing.expect(std.ascii.indexOfIgnoreCase(origin.captured[0], "authorization:") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(origin.captured[0], "mcp-session-id:") != null);

    // Nothing was queued from a failed request.
    try std.testing.expectEqual(@as(usize, 0), transport_impl.pending_responses.items.len);
}

test "Client.connectHttp round-trips and frees everything it allocates" {
    // Exercises the whole client HTTP path under the testing allocator, which
    // fails on any leak. Nothing else in the tree instantiates HttpTransport,
    // and without a test like this Zig never analyses it at all.
    const client_mod = @import("../client/client.zig");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var port: u16 = 0;
    var listener = try bindTestListener(io, 39300, &port);
    defer listener.deinit(io);

    const init_result = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nmcp-session-id: issued-session\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}";
    const replies = [_][]const u8{ init_result, init_result };
    var origin: TestHttpOrigin = .{
        .listener = &listener,
        .replies = &replies,
        .allocator = allocator,
    };
    defer origin.deinit();

    const thread = try std.Thread.spawn(.{}, TestHttpOrigin.run, .{&origin});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(endpoint);

    var client: client_mod.Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(allocator);

    try client.connectHttp(io, allocator, endpoint);
    try client.listTools(io, allocator);

    try std.testing.expectEqual(@as(usize, 2), origin.requestCount());
    // The handshake response carried a session id; the next request replays it.
    try std.testing.expect(std.ascii.indexOfIgnoreCase(origin.captured[1], "mcp-session-id: issued-session") != null);
}

fn stdioFromFixture(dir: std.Io.Dir, io: std.Io, name: []const u8, contents: []const u8) !std.Io.File {
    const w = try dir.createFile(io, name, .{});
    try w.writeStreamingAll(io, contents);
    w.close(io);
    return try dir.openFile(io, name, .{});
}

test "stdio receive buffers ahead instead of reading a byte at a time" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in = try stdioFromFixture(tmp.dir, io, "in.jsonl", "one\ntwo\n");
    defer in.close(io);

    var t: StdioTransport = .{ .in = in };
    defer t.deinit(allocator);

    const first = (try t.receive(io, allocator)).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("one", first);

    // The byte-at-a-time reader stopped exactly at the newline, so it never
    // held anything after returning a message. A buffered read pulls the rest
    // of the chunk too, which is the whole point of the fix.
    try std.testing.expect(t.read_buffer.items.len > 0);

    const second = (try t.receive(io, allocator)).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("two", second);

    try std.testing.expectError(Transport.ReceiveError.EndOfStream, t.receive(io, allocator));
}

test "stdio receive delivers a trailing message that has no newline" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in = try stdioFromFixture(tmp.dir, io, "in.jsonl", "solo");
    defer in.close(io);

    var t: StdioTransport = .{ .in = in };
    defer t.deinit(allocator);

    const msg = (try t.receive(io, allocator)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("solo", msg);
    try std.testing.expectError(Transport.ReceiveError.EndOfStream, t.receive(io, allocator));
}

test "stdio receive rejects a message larger than the cap" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in = try stdioFromFixture(tmp.dir, io, "in.jsonl", "0123456789abcdef\n");
    defer in.close(io);

    var t: StdioTransport = .{ .in = in, .max_message_size = 8 };
    defer t.deinit(allocator);

    try std.testing.expectError(Transport.ReceiveError.MessageTooLarge, t.receive(io, allocator));
}

test "stdio send writes to the configured stream, not this process's stdout" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try tmp.dir.createFile(io, "out.jsonl", .{});
    var t: StdioTransport = .{ .out = out };
    defer t.deinit(allocator);
    try t.send(io, allocator, "{\"jsonrpc\":\"2.0\"}");
    out.close(io);

    const written = try tmp.dir.readFileAlloc(io, "out.jsonl", allocator, .limited(1024));
    defer allocator.free(written);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}\n", written);
}
