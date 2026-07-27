//! MCP Server Implementation (Spec 2025-11-25)
//!
//! Provides the main MCP Server that handles client connections, protocol
//! negotiation, capability advertisement, and request routing for tools,
//! resources, prompts, tasks, and all standard MCP methods.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
const transport_mod = @import("../transport/transport.zig");
const prompts_mod = @import("prompts.zig");
const resources_mod = @import("resources.zig");
const tools_mod = @import("tools.zig");

const HttpRequestTransport = struct {
    /// Owns `response_message`. Must outlive the whole request, because the
    /// `allocator` handed to `send` is a per-message arena that is destroyed
    /// before the response is written to the socket.
    owner_allocator: std.mem.Allocator,
    /// Every message the handler produced, in order.
    ///
    /// A handler may emit progress notifications before its result, so keeping
    /// only the last one silently dropped everything but the final message.
    messages: std.ArrayList([]const u8) = .empty,
    is_closed: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        for (self.messages.items) |msg| self.owner_allocator.free(msg);
        self.messages.deinit(self.owner_allocator);
        self.messages = .empty;
    }

    /// The final message, which for a request is its response.
    pub fn responseMessage(self: *const Self) ?[]const u8 {
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
    }

    pub fn send(self: *Self, _: std.Io, _: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        if (self.is_closed) return transport_mod.Transport.SendError.ConnectionClosed;

        const owned = self.owner_allocator.dupe(u8, message) catch return transport_mod.Transport.SendError.OutOfMemory;
        errdefer self.owner_allocator.free(owned);
        self.messages.append(self.owner_allocator, owned) catch return transport_mod.Transport.SendError.OutOfMemory;
    }

    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return transport_mod.Transport.ReceiveError.ConnectionClosed;
        return null;
    }

    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    pub fn transport(self: *Self) transport_mod.Transport {
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

    /// No-op: this transport lives on the connection handler's stack and is
    /// cleaned up by its own `defer`, so nothing here owns a heap allocation.
    fn deinitVtable(_: *anyopaque, _: std.mem.Allocator) void {}

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// Configuration for an MCP Server
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    /// Maximum items returned by one `*/list` request.
    ///
    /// `0` (the default) returns everything in a single page and never emits
    /// `nextCursor`, which is the historical behaviour.
    page_size: usize = 0,
};

/// One page of a `*/list` response.
const Page = struct {
    /// Sorted keys belonging to this page.
    keys: []const []const u8,
    /// Opaque cursor for the next page, or null if this is the last one.
    /// Allocated from the request allocator.
    next_cursor: ?[]const u8,
};

/// A cursor is the last key of the previous page, base64url-encoded so the
/// caller has no reason to construct or mutate one.
const cursor_codec = std.base64.url_safe_no_pad;

fn lessThanKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Selects the page of `keys` following `cursor`.
///
/// `keys` is sorted in place. Sorting matters: hash map iteration order is not
/// stable across insertions, so paging over the raw order could skip or repeat
/// entries whenever a tool is registered mid-walk. A total order over the keys
/// makes "everything after X" well defined regardless.
fn paginateKeys(
    allocator: std.mem.Allocator,
    keys: [][]const u8,
    cursor: ?[]const u8,
    page_size: usize,
) !Page {
    std.mem.sort([]const u8, keys, {}, lessThanKey);

    var start: usize = 0;
    if (cursor) |encoded| {
        const decoded_len = cursor_codec.Decoder.calcSizeForSlice(encoded) catch
            return error.InvalidCursor;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        cursor_codec.Decoder.decode(decoded, encoded) catch return error.InvalidCursor;

        // Resume strictly after the last key we handed out. A key that has
        // since been removed does not strand the walk.
        while (start < keys.len and std.mem.order(u8, keys[start], decoded) != .gt) {
            start += 1;
        }
    }

    if (page_size == 0) {
        return .{ .keys = keys[start..], .next_cursor = null };
    }

    const end = @min(start + page_size, keys.len);
    const window = keys[start..end];
    if (end >= keys.len or window.len == 0) {
        return .{ .keys = window, .next_cursor = null };
    }

    const last = window[window.len - 1];
    const encoded = try allocator.alloc(u8, cursor_codec.Encoder.calcSize(last.len));
    _ = cursor_codec.Encoder.encode(encoded, last);
    return .{ .keys = window, .next_cursor = encoded };
}

/// Reads the `cursor` param of a `*/list` request.
fn listCursor(request: jsonrpc.Request) ?[]const u8 {
    const params = request.params orelse return null;
    const obj = switch (params) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("cursor") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Lifecycle of the server process itself.
///
/// This is deliberately separate from `SessionState`: whether the server is
/// still accepting messages is a server-wide concern, while the MCP
/// initialization handshake is per-client.
pub const Lifecycle = enum {
    running,
    shutting_down,
    stopped,
};

/// Initialization state of a single client session.
pub const SessionState = enum {
    uninitialized,
    initializing,
    ready,
};

/// A request this server sent to a client and is still awaiting a reply for.
pub const PendingRequest = struct {
    method: []const u8,
    timestamp: i64,
};

const TaskEntry = struct {
    task: types.Task,
    result_json: []const u8,
};

/// Per-client state.
///
/// Everything a client can mutate lives here rather than on `Server`, so one
/// client cannot observe or clobber another's handshake, log level or tasks.
/// `Server` keeps only immutable registrations (tools/resources/prompts) and
/// the session table.
pub const Session = struct {
    /// Where replies for the request currently being served go.
    ///
    /// This is per-request state, not per-session: the HTTP transport builds a
    /// fresh reply sink for every request. It lives here rather than on
    /// `Server` because `Server` is shared by every connection, and a second
    /// connection would overwrite the first one's reply sink mid-request.
    /// `mutex` is held for the whole of a request, so concurrent requests on
    /// one session are serialized rather than interleaved.
    reply: ?transport_mod.Transport = null,
    /// Held for the duration of a request against this session.
    mutex: std.Io.Mutex = .init,
    /// Number of connections currently serving this session. Guarded by
    /// `Server.sessions_mutex`. A session with live references is never freed,
    /// so a concurrent idle sweep or `DELETE` cannot pull it out from under a
    /// request in flight.
    refs: usize = 0,
    /// Set when the session has been terminated but still has live references.
    /// The last reference to be released performs the teardown.
    closing: bool = false,
    /// Monotonic SSE event id for this session. Ids are session-global so a
    /// client can resume with `Last-Event-ID` regardless of which stream an
    /// event was originally delivered on.
    event_seq: u64 = 0,
    /// Recent events, retained so a reconnecting client can be caught up.
    /// Bounded by `max_replay_events`; older events are dropped, which is
    /// visible to the client as a gap it can recover from by re-initializing.
    replay: std.ArrayList(Event) = .empty,
    /// Set alongside `closing`. Long-running handlers should poll
    /// `isCancelled` and abandon work whose result can no longer be delivered.
    cancel_requested: bool = false,
    /// Session identifier handed to the client as `Mcp-Session-Id`.
    /// `null` for the implicit session used by stdio and custom transports,
    /// which are single-client by construction.
    id: ?[]const u8 = null,
    state: SessionState = .uninitialized,
    client_info: ?types.Implementation = null,
    client_capabilities: ?types.ClientCapabilities = null,
    log_level: protocol.LogLevel = .info,
    tasks: std.StringHashMap(TaskEntry),
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    next_request_id: i64 = 1,
    /// Ids of client requests currently being served, so a repeat can be
    /// rejected while the original is still outstanding. Keys are owned and
    /// dropped as soon as the response is sent, so this holds only genuinely
    /// concurrent work rather than growing for the life of the session.
    inflight: std.StringHashMap(void),
    /// Guards `inflight`. Requests on one session are serialized today, but
    /// the table is the seam a worker pool would contend on.
    inflight_mutex: std.Io.Mutex = .init,
    /// Seconds since the epoch when this session was last used.
    last_seen_s: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .tasks = .init(allocator),
            .pending_requests = .init(allocator),
            .inflight = .init(allocator),
        };
    }

    /// Number of client requests that may be in flight on one session at once.
    pub const max_inflight_requests = 256;

    /// A key that distinguishes integer id 5 from string id "5".
    fn inflightKey(allocator: std.mem.Allocator, id: types.RequestId) ![]u8 {
        return switch (id) {
            .integer => |value| std.fmt.allocPrint(allocator, "i:{d}", .{value}),
            .string => |value| std.fmt.allocPrint(allocator, "s:{s}", .{value}),
        };
    }

    const Claim = enum { claimed, duplicate, at_capacity };

    /// Take ownership of a request id for the duration of the request.
    ///
    /// The key is allocated from the session's own allocator, not from the
    /// caller's: the per-message allocator is an arena that is destroyed long
    /// before a concurrent request could observe the entry.
    fn claimRequestId(self: *Session, io: std.Io, id: types.RequestId) !Claim {
        const allocator = self.inflight.allocator;
        const key = try inflightKey(allocator, id);
        errdefer allocator.free(key);

        self.inflight_mutex.lock(io) catch return error.Canceled;
        defer self.inflight_mutex.unlock(io);

        if (self.inflight.contains(key)) {
            allocator.free(key);
            return .duplicate;
        }
        if (self.inflight.count() >= max_inflight_requests) {
            allocator.free(key);
            return .at_capacity;
        }
        try self.inflight.put(key, {});
        return .claimed;
    }

    fn releaseRequestId(self: *Session, io: std.Io, id: types.RequestId) void {
        const allocator = self.inflight.allocator;
        const key = inflightKey(allocator, id) catch return;
        defer allocator.free(key);

        self.inflight_mutex.lockUncancelable(io);
        defer self.inflight_mutex.unlock(io);

        if (self.inflight.fetchRemove(key)) |entry| allocator.free(entry.key);
    }

    /// Whether work for this session should stop early, because the client
    /// went away or asked for termination. Long-running handlers should poll it.
    pub fn isCancelled(self: *const Session) bool {
        return self.cancel_requested;
    }

    /// An SSE event queued for delivery on this session's streams.
    pub const Event = struct {
        id: u64,
        data: []const u8,
    };

    /// Number of events retained for `Last-Event-ID` resumption.
    pub const max_replay_events = 256;

    /// Record a message as an SSE event and return its id.
    pub fn pushEvent(self: *Session, allocator: std.mem.Allocator, data: []const u8) !u64 {
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);
        self.event_seq += 1;
        try self.replay.append(allocator, .{ .id = self.event_seq, .data = owned });
        if (self.replay.items.len > max_replay_events) {
            const dropped = self.replay.orderedRemove(0);
            allocator.free(dropped.data);
        }
        return self.event_seq;
    }

    fn deinitReplay(self: *Session, allocator: std.mem.Allocator) void {
        for (self.replay.items) |event| allocator.free(event.data);
        self.replay.deinit(allocator);
        self.replay = .empty;
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            // The map key aliases `task.taskId`, so it must not be freed twice.
            allocator.free(entry.value_ptr.task.taskId);
            allocator.free(entry.value_ptr.task.createdAt);
            allocator.free(entry.value_ptr.task.lastUpdatedAt);
            if (entry.value_ptr.task.statusMessage) |msg| allocator.free(msg);
            allocator.free(entry.value_ptr.result_json);
        }
        self.tasks.deinit();
        self.pending_requests.deinit();
        var inflight_it = self.inflight.keyIterator();
        while (inflight_it.next()) |key| allocator.free(key.*);
        self.inflight.deinit();
        self.deinitReplay(allocator);
        if (self.client_info) |ci| {
            allocator.free(ci.name);
            allocator.free(ci.version);
            self.client_info = null;
        }
        if (self.id) |sid| {
            allocator.free(sid);
            self.id = null;
        }
    }
};

/// Winsock socket options, which `std.posix` refuses to expose on Windows.
const winsock = struct {
    const sol_socket: i32 = 0xffff;
    const so_sndtimeo: i32 = 0x1005;
    const so_rcvtimeo: i32 = 0x1006;

    extern "ws2_32" fn setsockopt(
        s: std.Io.net.Socket.Handle,
        level: i32,
        optname: i32,
        optval: [*]const u8,
        optlen: i32,
    ) callconv(.winapi) i32;
};

/// MCP Server that handles client connections and routes requests
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    lifecycle: Lifecycle = .running,
    tools: std.StringHashMap(tools_mod.Tool),
    resources: std.StringHashMap(resources_mod.Resource),
    resource_templates: std.StringHashMap(resources_mod.ResourceTemplate),
    prompts: std.StringHashMap(prompts_mod.Prompt),
    capabilities: types.ServerCapabilities = .{},
    transport: ?transport_mod.Transport = null,
    stdio_transport: ?*transport_mod.StdioTransport = null,
    /// Sessions addressable by `Mcp-Session-Id`, used by the HTTP transport.
    sessions: std.StringHashMap(*Session),
    /// Ids of sessions that existed and were terminated, so a later request
    /// against one can be answered `410 Gone` — "re-initialize" — rather than
    /// `404`, which is indistinguishable from a fabricated id.
    terminated_sessions: std.StringHashMap(void),
    /// Insertion order for `terminated_sessions`, used to evict the oldest.
    terminated_order: std.ArrayList([]const u8) = .empty,
    /// Single implicit session for stdio and custom transports, which carry
    /// exactly one client and have no way to convey a session id.
    implicit_session: Session,
    /// Maximum number of concurrently tracked HTTP sessions.
    max_sessions: usize = 256,
    /// Idle time, in seconds, after which an HTTP session is reclaimed.
    session_idle_timeout_s: i64 = 5 * 60,
    /// Maximum number of tasks retained per session.
    max_tasks_per_session: usize = 256,
    /// Guards `sessions`. Connections are served concurrently, so the table is
    /// reachable from several threads at once.
    sessions_mutex: std.Io.Mutex = .init,
    /// Guards `active_connections`.
    connections_mutex: std.Io.Mutex = .init,
    /// HTTP connections currently being served.
    active_connections: usize = 0,
    /// Upper bound on concurrently served HTTP connections. Beyond this,
    /// accepted connections wait for a slot rather than spawning unbounded
    /// threads.
    max_connections: usize = 64,
    /// Listening socket, published while `runHttp` is active so `shutdown` can
    /// unblock a parked `accept` from another thread.
    http_listener: ?*std.Io.net.Server = null,
    /// Address the listener is bound to, used to wake a parked `accept`.
    http_bind_address: ?std.Io.net.IpAddress = null,
    pub const max_http_body_size: usize = 4 * 1024 * 1024;

    const Self = @This();

    /// Number of random bytes in a generated session id.
    const session_id_entropy_bytes = 32;

    /// Initialize a new MCP Server
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .tools = .init(allocator),
            .resources = .init(allocator),
            .resource_templates = .init(allocator),
            .prompts = .init(allocator),
            .sessions = .init(allocator),
            .terminated_sessions = .init(allocator),
            .implicit_session = .init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *Self) void {
        self.tools.deinit();
        self.resources.deinit();
        self.resource_templates.deinit();
        self.prompts.deinit();
        self.implicit_session.deinit(self.allocator);
        var sit = self.sessions.iterator();
        while (sit.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
        for (self.terminated_order.items) |key| self.allocator.free(key);
        self.terminated_order.deinit(self.allocator);
        self.terminated_sessions.deinit();
        if (self.stdio_transport) |stdio| {
            stdio.deinit(self.allocator);
            self.allocator.destroy(stdio);
            self.stdio_transport = null;
        }
    }

    fn nowSeconds(io: std.Io) i64 {
        return std.Io.Clock.real.now(io).toSeconds();
    }

    /// Derive the session-table key from a session id.
    ///
    /// The table is keyed by the SHA-256 digest of the id rather than the id
    /// itself so that lookups never run a short-circuiting comparison against
    /// the secret a client presented.
    fn sessionKey(id: []const u8, out: *[std.crypto.hash.sha2.Sha256.digest_length * 2]u8) []const u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            out[i * 2] = hex_chars[b >> 4];
            out[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        return out[0..];
    }

    const CreatedSession = struct {
        session: *Session,
        /// The id to hand to the client. Owned by the server allocator.
        plaintext_id: []u8,
    };

    /// Mint an unregistered session with a fresh CSPRNG identifier.
    fn createSession(self: *Self, io: std.Io) !CreatedSession {
        self.sessions_mutex.lock(io) catch return error.Canceled;
        defer self.sessions_mutex.unlock(io);
        self.sweepIdleSessions(io);
        if (self.sessions.count() >= self.max_sessions) return error.TooManySessions;

        // No fallback to a non-secure RNG here: the session id is an
        // authorization token, so a weak source must fail the request.
        var raw: [session_id_entropy_bytes]u8 = undefined;
        try io.randomSecure(&raw);
        const hex_chars = "0123456789abcdef";
        const plaintext = try self.allocator.alloc(u8, raw.len * 2);
        errdefer self.allocator.free(plaintext);
        for (raw, 0..) |b, i| {
            plaintext[i * 2] = hex_chars[b >> 4];
            plaintext[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        var key_buf: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
        const key = try self.allocator.dupe(u8, sessionKey(plaintext, &key_buf));
        errdefer self.allocator.free(key);

        const session = try self.allocator.create(Session);
        session.* = .init(self.allocator);
        session.id = key;
        session.last_seen_s = nowSeconds(io);
        return .{ .session = session, .plaintext_id = plaintext };
    }

    /// Queue a message on every live session's event stream.
    fn broadcastEvent(self: *Self, io: std.Io, json: []const u8) void {
        self.sessions_mutex.lock(io) catch return;
        defer self.sessions_mutex.unlock(io);
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.closing) continue;
            _ = session.pushEvent(self.allocator, json) catch continue;
        }
    }

    /// Append one `id:`/`data:` SSE frame.
    ///
    /// A JSON-RPC message is a single line, but split on newlines anyway: an
    /// embedded newline would otherwise terminate the frame early and let a
    /// message forge the ones after it.
    fn appendSseEvent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: u64, data: []const u8) !void {
        if (id != 0) try out.print(allocator, "id: {d}\n", .{id});
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            try out.print(allocator, "data: {s}\n", .{line});
        }
        try out.appendSlice(allocator, "\n");
    }

    /// Whether a client-presented `MCP-Protocol-Version` is one we speak.
    fn isSupportedProtocolVersion(version: []const u8) bool {
        for (protocol.SUPPORTED_VERSIONS) |supported| {
            if (std.mem.eql(u8, supported, version)) return true;
        }
        return false;
    }

    /// Look up a registered session by the id a client presented.
    ///
    /// Callers must hold `sessions_mutex` when other threads may be running.
    fn lookupSession(self: *Self, presented_id: []const u8) ?*Session {
        var key_buf: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
        return self.sessions.get(sessionKey(presented_id, &key_buf));
    }

    /// Whether an id belonged to a session that has since been terminated.
    fn wasTerminated(self: *Self, io: std.Io, presented_id: []const u8) bool {
        self.sessions_mutex.lock(io) catch return false;
        defer self.sessions_mutex.unlock(io);
        var key_buf: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
        return self.terminated_sessions.contains(sessionKey(presented_id, &key_buf));
    }

    /// Look up a session and pin it so it survives for the caller's request.
    ///
    /// Every successful call must be paired with `releaseSession`.
    fn acquireSession(self: *Self, io: std.Io, presented_id: []const u8) ?*Session {
        self.sessions_mutex.lock(io) catch return null;
        defer self.sessions_mutex.unlock(io);
        const session = self.lookupSession(presented_id) orelse return null;
        if (session.closing) return null;
        session.refs += 1;
        return session;
    }

    /// Drop a reference taken by `acquireSession`, tearing the session down if
    /// it was terminated while this reference was held.
    fn releaseSession(self: *Self, io: std.Io, session: *Session) void {
        self.sessions_mutex.lock(io) catch return;
        defer self.sessions_mutex.unlock(io);
        session.refs -= 1;
        if (session.closing and session.refs == 0) self.destroySession(session);
    }

    /// Remember that a registered session id existed, so a later request
    /// against it is answerable with `410 Gone`.
    ///
    /// Bounded by `max_sessions`: the oldest tombstone is evicted, which at
    /// worst degrades an old id back to `404`.
    fn recordTerminated(self: *Self, key: []const u8) void {
        if (self.terminated_sessions.contains(key)) return;
        const owned = self.allocator.dupe(u8, key) catch return;
        self.terminated_sessions.put(owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        self.terminated_order.append(self.allocator, owned) catch {
            _ = self.terminated_sessions.remove(owned);
            self.allocator.free(owned);
            return;
        };
        if (self.terminated_order.items.len > self.max_sessions) {
            const oldest = self.terminated_order.orderedRemove(0);
            _ = self.terminated_sessions.remove(oldest);
            self.allocator.free(oldest);
        }
    }

    /// Tear a session down, removing it from the table if it was registered.
    fn destroySession(self: *Self, session: *Session) void {
        if (session.id) |key| {
            if (self.sessions.remove(key)) self.recordTerminated(key);
        }
        session.deinit(self.allocator);
        self.allocator.destroy(session);
    }

    /// Drop sessions that have been idle past `session_idle_timeout_s`.
    fn sweepIdleSessions(self: *Self, io: std.Io) void {
        if (self.sessions.count() == 0) return;
        const now = nowSeconds(io);
        var expired: std.ArrayList(*Session) = .empty;
        defer expired.deinit(self.allocator);
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.closing) continue;
            if (now -| entry.value_ptr.*.last_seen_s > self.session_idle_timeout_s) {
                expired.append(self.allocator, entry.value_ptr.*) catch return;
            }
        }
        for (expired.items) |session| {
            // A session being served right now is left alone; the connection
            // holding it performs the teardown when it finishes.
            if (session.refs > 0) {
                session.closing = true;
                session.cancel_requested = true;
                _ = self.sessions.remove(session.id.?);
                self.recordTerminated(session.id.?);
                continue;
            }
            self.destroySession(session);
        }
    }

    /// Add a tool to the server
    pub fn addTool(self: *Self, tool: tools_mod.Tool) !void {
        try self.tools.put(tool.name, tool);
        self.capabilities.tools = .{ .listChanged = true };
    }

    /// Add a resource to the server
    pub fn addResource(self: *Self, resource: resources_mod.Resource) !void {
        try self.resources.put(resource.uri, resource);
        self.capabilities.resources = .{ .listChanged = true, .subscribe = false };
    }

    /// Add a resource template to the server
    pub fn addResourceTemplate(self: *Self, template: resources_mod.ResourceTemplate) !void {
        try self.resource_templates.put(template.name, template);
        if (self.capabilities.resources == null) {
            self.capabilities.resources = .{};
        }
    }

    /// Add a prompt to the server
    pub fn addPrompt(self: *Self, prompt: prompts_mod.Prompt) !void {
        try self.prompts.put(prompt.name, prompt);
        self.capabilities.prompts = .{ .listChanged = true };
    }

    /// Enable logging capability
    pub fn enableLogging(self: *Self) void {
        self.capabilities.logging = .{};
    }

    /// Enable completion capability
    pub fn enableCompletions(self: *Self) void {
        self.capabilities.completions = .{};
    }

    /// Enable task-augmented tools/call support
    pub fn enableTasks(self: *Self) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{
                .tools = .{
                    .call = .{},
                },
            },
        };
    }

    /// Options for running the server
    pub const HttpRunConfig = struct {
        port: u16 = 8080,
        host: []const u8 = "localhost",

        /// Bearer token that every request must present in `Authorization`.
        ///
        /// May be left null for a loopback bind, where the operating system
        /// already limits reachability to processes on this machine. It is
        /// mandatory for any other bind.
        auth_token: ?[]const u8 = null,

        /// Opt in to binding an address reachable from outside this machine.
        ///
        /// Defaults to false, and deliberately so: an MCP server exposes every
        /// registered tool, so binding a routable interface by accident hands
        /// those tools to whoever can reach the port. Setting this also
        /// requires `auth_token`.
        allow_non_loopback: bool = false,

        /// Origins permitted to make browser-initiated requests, e.g.
        /// `"https://app.example.com"`.
        ///
        /// Defaults to empty, which rejects any request carrying an `Origin`
        /// header. Ordinary MCP clients are not browsers and send no `Origin`
        /// at all, so the default is transparent for them while closing the
        /// door on web pages the user happens to visit.
        allowed_origins: []const []const u8 = &.{},

        /// Read and write deadline applied to every connection, in seconds.
        ///
        /// Without it a client can open a socket, dribble out a request head
        /// forever and hold a connection slot indefinitely. Set to 0 to
        /// disable, which is only sensible behind a proxy that imposes its own.
        connection_timeout_s: u32 = 30,

        /// How long `shutdown` waits for in-flight connections to drain, in
        /// milliseconds, before returning anyway.
        shutdown_grace_ms: u64 = 5_000,

        /// Set `SO_REUSEADDR` on the listening socket.
        ///
        /// On by default: without it a restart fails with `AddressInUse` for
        /// as long as the previous socket sits in `TIME_WAIT`.
        reuse_address: bool = true,

        /// Shortest accepted token. Long enough that an online guessing attack
        /// against a high-entropy token is not worth attempting.
        pub const min_auth_token_len = 32;

        pub const ValidateError = error{
            NonLoopbackBindRequiresOptIn,
            NonLoopbackBindRequiresAuthToken,
            AuthTokenTooShort,
        };

        /// Rejects configurations that would expose tools without
        /// authentication. Called by `runHttp` before the listener is created,
        /// so a misconfigured server refuses to start rather than starting
        /// insecurely.
        pub fn validate(config: HttpRunConfig) ValidateError!void {
            if (config.auth_token) |token| {
                if (token.len < min_auth_token_len) return error.AuthTokenTooShort;
            }

            if (isLoopbackHost(config.host)) return;

            if (!config.allow_non_loopback) return error.NonLoopbackBindRequiresOptIn;
            if (config.auth_token == null) return error.NonLoopbackBindRequiresAuthToken;
        }
    };

    /// Whether `host` names an address that only this machine can reach.
    ///
    /// Fails closed: anything that cannot be shown to be loopback, including
    /// names this function cannot resolve without doing I/O, is treated as
    /// routable. That is the safe direction to be wrong in, because the only
    /// consequence is that the operator must set `allow_non_loopback`.
    fn isLoopbackHost(host: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;

        const trimmed = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
            host[1 .. host.len - 1]
        else
            host;

        if (std.Io.net.Ip4Address.parse(trimmed, 0)) |ip4| {
            // The whole of 127.0.0.0/8 is loopback, not just 127.0.0.1.
            return ip4.bytes[0] == 127;
        } else |_| {}

        if (std.Io.net.Ip6Address.parse(trimmed, 0)) |ip6| {
            const loopback6 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            if (std.mem.eql(u8, &ip6.bytes, &loopback6)) return true;

            // ::ffff:127.0.0.0/8, the IPv4-mapped form of loopback.
            const v4_mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.startsWith(u8, &ip6.bytes, &v4_mapped_prefix)) {
                return ip6.bytes[12] == 127;
            }
            return false;
        } else |_| {}

        return false;
    }

    pub const RunOptions = union(enum) {
        stdio: void,
        http: HttpRunConfig,
    };

    /// Run the server with the specified transport
    pub fn run(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void {
        switch (options) {
            .stdio => {
                self.log(io, "Server listening on STDIO");
                const stdio = try allocator.create(transport_mod.StdioTransport);
                stdio.* = .{};
                self.stdio_transport = stdio;
                self.transport = stdio.transport();
                try self.messageLoop(io, allocator);
            },
            .http => |config| {
                try self.runHttp(io, allocator, config);
            },
        }
    }

    fn runHttp(self: *Self, io: std.Io, allocator: std.mem.Allocator, config: HttpRunConfig) !void {
        try config.validate();

        const bind_host = if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;

        const address = std.Io.net.IpAddress.resolve(io, bind_host, config.port) catch {
            return error.AddressResolutionError;
        };

        var listener = try std.Io.net.IpAddress.listen(&address, io, .{
            .reuse_address = config.reuse_address,
        });
        defer listener.deinit(io);

        self.connections_mutex.lock(io) catch return error.Canceled;
        self.http_listener = &listener;
        self.http_bind_address = address;
        self.connections_mutex.unlock(io);
        defer {
            self.connections_mutex.lock(io) catch {};
            self.http_listener = null;
            self.http_bind_address = null;
            self.connections_mutex.unlock(io);
        }

        // Repeated accept failures must not become a hot spin loop.
        var accept_backoff_ms: i64 = 0;

        while (self.lifecycle == .running) {
            const stream = listener.accept(io) catch |err| switch (err) {
                // `shutdown` on the listening socket unblocks a parked accept.
                error.SocketNotListening, error.Canceled => break,
                else => {
                    std.log.err("HTTP accept failed: {s}", .{@errorName(err)});
                    accept_backoff_ms = nextAcceptBackoffMs(accept_backoff_ms);
                    io.sleep(.fromMilliseconds(accept_backoff_ms), .awake) catch break;
                    continue;
                },
            };
            accept_backoff_ms = 0;

            _ = setSocketTimeouts(stream.socket.handle, config.connection_timeout_s);

            // Serve on its own thread so one slow client cannot stall every
            // other client behind it. At capacity we serve inline instead of
            // spawning without bound or dropping the connection.
            if (self.tryAcquireConnectionSlot(io)) {
                if (self.spawnConnection(io, allocator, stream, config)) continue;
                self.releaseConnectionSlot(io);
            }

            self.serveHttpConnection(io, allocator, stream, config) catch |err| {
                std.log.err("HTTP connection error: {s}", .{@errorName(err)});
            };
        }

        self.drainConnections(io, config.shutdown_grace_ms);
    }

    /// Backoff schedule for repeated accept failures: 1ms doubling to 1s.
    fn nextAcceptBackoffMs(current: i64) i64 {
        if (current == 0) return 1;
        return @min(current * 2, 1000);
    }

    /// Apply a read and write deadline to a connection.
    ///
    /// Best effort: a platform that rejects the option leaves the connection
    /// without a deadline rather than dropping it, since the bounded connection
    /// count already caps the damage.
    fn setSocketTimeouts(handle: std.Io.net.Socket.Handle, seconds: u32) bool {
        if (seconds == 0) return false;
        const posix = std.posix;
        if (builtin.os.tag == .windows) {
            // `std.posix.setsockopt` is a compile error on Windows and std.Io
            // exposes no socket options, so call Winsock directly. Windows
            // takes a millisecond DWORD here, not a `timeval`.
            const millis: u32 = seconds *| 1000;
            const bytes = std.mem.asBytes(&millis);
            if (winsock.setsockopt(handle, winsock.sol_socket, winsock.so_rcvtimeo, bytes.ptr, bytes.len) != 0) return false;
            if (winsock.setsockopt(handle, winsock.sol_socket, winsock.so_sndtimeo, bytes.ptr, bytes.len) != 0) return false;
        } else {
            const timeout: posix.timeval = .{ .sec = @intCast(seconds), .usec = 0 };
            const bytes = std.mem.asBytes(&timeout);
            posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, bytes) catch return false;
            posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, bytes) catch return false;
        }
        return true;
    }

    /// Stop accepting new connections and unblock a parked `accept`.
    ///
    /// Safe to call from any thread, including a signal handler thread, which
    /// is the point: without it the accept loop only notices a state change
    /// after the next connection happens to arrive.
    pub fn shutdown(self: *Self, io: std.Io) void {
        self.lifecycle = .shutting_down;
        self.connections_mutex.lock(io) catch return;
        defer self.connections_mutex.unlock(io);
        if (self.http_listener) |listener| {
            // Documented by std as a concurrent cancellation mechanism for
            // `accept`, which otherwise blocks until a client happens to connect.
            // It does not unblock a parked `accept` on every platform, though,
            // so also dial the listener: whichever mechanism works first wins,
            // and the accept loop closes the wake-up connection and stops.
            const listening: std.Io.net.Stream = .{ .socket = listener.socket };
            listening.shutdown(io, .both) catch {};
        }
        const bind_address = self.http_bind_address;
        self.connections_mutex.unlock(io);
        if (bind_address) |addr| {
            if (addr.getPort() != 0) {
                if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream })) |stream| {
                    stream.close(io);
                } else |_| {}
            }
        }
        self.connections_mutex.lock(io) catch return;
    }

    /// Wait for in-flight connections to finish, up to `grace_ms`.
    fn drainConnections(self: *Self, io: std.Io, grace_ms: u64) void {
        const poll_ms: i64 = 10;
        var waited: u64 = 0;
        while (waited < grace_ms) {
            self.connections_mutex.lock(io) catch return;
            const active = self.active_connections;
            self.connections_mutex.unlock(io);
            if (active == 0) return;
            io.sleep(.fromMilliseconds(poll_ms), .awake) catch return;
            waited += @intCast(poll_ms);
        }
        std.log.warn("HTTP shutdown grace period elapsed with connections still in flight", .{});
    }

    const ConnectionContext = struct {
        server: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        stream: std.Io.net.Stream,
        config: HttpRunConfig,
    };

    /// Take a connection slot if the server is below `max_connections`.
    fn tryAcquireConnectionSlot(self: *Self, io: std.Io) bool {
        self.connections_mutex.lock(io) catch return false;
        defer self.connections_mutex.unlock(io);
        if (self.active_connections >= self.max_connections) return false;
        self.active_connections += 1;
        return true;
    }

    fn releaseConnectionSlot(self: *Self, io: std.Io) void {
        self.connections_mutex.lock(io) catch return;
        defer self.connections_mutex.unlock(io);
        self.active_connections -= 1;
    }

    /// Hand a connection to a worker thread. Returns false if it could not be
    /// spawned, in which case the caller still owns the connection.
    fn spawnConnection(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        stream: std.Io.net.Stream,
        config: HttpRunConfig,
    ) bool {
        const ctx = allocator.create(ConnectionContext) catch return false;
        ctx.* = .{
            .server = self,
            .io = io,
            .allocator = allocator,
            .stream = stream,
            .config = config,
        };
        const thread = std.Thread.spawn(.{}, connectionWorker, .{ctx}) catch {
            allocator.destroy(ctx);
            return false;
        };
        thread.detach();
        return true;
    }

    fn connectionWorker(ctx: *ConnectionContext) void {
        defer {
            ctx.server.releaseConnectionSlot(ctx.io);
            ctx.allocator.destroy(ctx);
        }
        ctx.server.serveHttpConnection(ctx.io, ctx.allocator, ctx.stream, ctx.config) catch |err| {
            std.log.err("HTTP connection error: {s}", .{@errorName(err)});
        };
    }

    fn serveHttpConnection(self: *Self, io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, config: HttpRunConfig) !void {
        defer stream.close(io);

        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        // POST carries JSON-RPC; DELETE terminates a session.
        if (request.head.method != .POST and request.head.method != .DELETE and request.head.method != .GET) {
            try request.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        // Reject browser-initiated requests from unapproved origins before
        // doing anything else. Binding loopback is no defence against these,
        // because the request originates from the victim's own machine.
        if (originHeader(&request)) |origin| {
            if (!originIsAllowed(origin, config.allowed_origins)) {
                try request.respond("Forbidden", .{
                    .status = .forbidden,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            }
        }

        // `application/json` is not a CORS-simple content type, so requiring it
        // forces a preflight that this server never answers. That is what stops
        // a page from POSTing here with `text/plain` and no preflight at all.
        if (request.head.method == .POST and !hasJsonContentType(&request)) {
            try request.respond("Expected Content-Type: application/json", .{
                .status = .unsupported_media_type,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        // Authenticate before reading the body, so an unauthenticated peer
        // cannot make the server allocate for it.
        if (config.auth_token) |expected| {
            if (!requestIsAuthorized(&request, expected)) {
                try request.respond("Unauthorized", .{
                    .status = .unauthorized,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                        .{ .name = "WWW-Authenticate", .value = "Bearer" },
                    },
                });
                return;
            }
        }

        if (request.head.method == .GET) {
            try self.handleHttpEventStream(io, allocator, &request, config);
            return;
        }

        if (request.head.method == .DELETE) {
            try self.handleHttpSessionDelete(io, &request);
            return;
        }

        try self.handleHttpJsonRpcRequest(io, allocator, &request);
    }

    /// Handle `GET` — the server-to-client event stream.
    ///
    /// This is the channel the spec reserves for server-initiated messages.
    /// Without it, notifications and progress can only ride along with a
    /// response the client happened to ask for.
    fn handleHttpEventStream(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: *http.Server.Request,
        config: HttpRunConfig,
    ) !void {
        var session_id: ?[]const u8 = null;
        var last_event_id: u64 = 0;
        var accepts_sse = false;
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                session_id = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "last-event-id")) {
                last_event_id = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                if (std.mem.indexOf(u8, header.value, "text/event-stream") != null) accepts_sse = true;
            }
        }

        if (!accepts_sse) {
            try request.respond("GET requires Accept: text/event-stream", .{
                .status = .not_acceptable,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            });
            return;
        }

        const sid = session_id orelse {
            // A stream is per-session by definition; there is nothing to
            // deliver on a stream that is not attached to one.
            try request.respond("Mcp-Session-Id required", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            });
            return;
        };

        const session = self.acquireSession(io, sid) orelse {
            if (self.wasTerminated(io, sid)) {
                try request.respond("MCP session terminated; re-initialize", .{
                    .status = .gone,
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
                });
                return;
            }
            try request.respond("Unknown or expired MCP session", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            });
            return;
        };
        defer self.releaseSession(io, session);

        var send_buffer: [4096]u8 = undefined;
        var body = try request.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                    .{ .name = "Cache-Control", .value = "no-cache" },
                },
            },
        });

        // `Last-Event-ID` resumption: everything newer than what the client
        // already saw, from the bounded replay buffer.
        var delivered = last_event_id;
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(allocator);

        var idle_ms: i64 = 0;
        while (self.lifecycle == .running and !session.closing) {
            frame.clearRetainingCapacity();

            self.sessions_mutex.lock(io) catch break;
            for (session.replay.items) |event| {
                if (event.id <= delivered) continue;
                appendSseEvent(allocator, &frame, event.id, event.data) catch break;
                delivered = event.id;
            }
            self.sessions_mutex.unlock(io);

            if (frame.items.len > 0) {
                idle_ms = 0;
                body.writer.writeAll(frame.items) catch break;
                body.flush() catch break;
                continue;
            }

            // A comment is a no-op to the client but keeps proxies and NAT
            // tables from reaping an idle stream.
            if (idle_ms >= stream_keepalive_ms) {
                idle_ms = 0;
                body.writer.writeAll(": keepalive\n\n") catch break;
                body.flush() catch break;
            }

            io.sleep(.fromMilliseconds(stream_poll_ms), .awake) catch break;
            idle_ms += stream_poll_ms;
            _ = config;
        }

        body.end() catch {};
    }

    /// How often the event stream checks for new events.
    const stream_poll_ms: i64 = 25;
    /// How long an event stream may be silent before a keepalive comment.
    const stream_keepalive_ms: i64 = 15_000;

    /// Handle `DELETE` — explicit session termination.
    ///
    /// Without this a client has no way to release its state early and the
    /// table only drains on the idle sweep.
    fn handleHttpSessionDelete(self: *Self, io: std.Io, request: *http.Server.Request) !void {
        var deleted_session_id: ?[]const u8 = null;
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            deleted_session_id = header.value;
            self.sessions_mutex.lock(io) catch return error.Canceled;
            const session = self.lookupSession(header.value) orelse {
                self.sessions_mutex.unlock(io);
                break;
            };
            const draining = session.refs > 0;
            if (draining) {
                // Still in use: unpublish now, tear down on last release.
                session.closing = true;
                session.cancel_requested = true;
                _ = self.sessions.remove(session.id.?);
                self.recordTerminated(session.id.?);
            } else {
                self.destroySession(session);
            }
            self.sessions_mutex.unlock(io);
            // `202` says the session is gone as far as the client is concerned
            // but work is still unwinding; `204` says it is fully torn down.
            try request.respond("", .{ .status = if (draining) .accepted else .no_content });
            return;
        }
        if (deleted_session_id) |sid| {
            if (self.wasTerminated(io, sid)) {
                try request.respond("MCP session terminated; re-initialize", .{
                    .status = .gone,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            }
        }
        try request.respond("Unknown or expired MCP session", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    /// Whether the request carries `Authorization: Bearer <expected>`.
    ///
    /// The comparison hashes both sides and compares the digests in constant
    /// time. Comparing the tokens directly would leak how long a shared prefix
    /// the attacker guessed, and comparing lengths first would leak the token
    /// length; hashing to a fixed 32 bytes avoids both.
    fn requestIsAuthorized(request: *http.Server.Request, expected: []const u8) bool {
        const prefix = "Bearer ";

        var presented: ?[]const u8 = null;
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            if (header.value.len <= prefix.len) continue;
            if (!std.ascii.startsWithIgnoreCase(header.value, prefix)) continue;
            presented = header.value[prefix.len..];
            break;
        }

        const token = presented orelse return false;

        var presented_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var expected_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &presented_digest, .{});
        std.crypto.hash.sha2.Sha256.hash(expected, &expected_digest, .{});

        return std.crypto.timing_safe.eql(
            [std.crypto.hash.sha2.Sha256.digest_length]u8,
            presented_digest,
            expected_digest,
        );
    }

    /// The request's `Origin` header, or null when it sends none.
    ///
    /// An empty or `null` origin counts as present and unapproved: those are
    /// what a sandboxed iframe or a redirected request produces, and neither
    /// should be able to reach the tools.
    fn originHeader(request: *http.Server.Request) ?[]const u8 {
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "origin")) return header.value;
        }
        return null;
    }

    fn originIsAllowed(origin: []const u8, allowed: []const []const u8) bool {
        for (allowed) |candidate| {
            // Origins are compared case-insensitively because scheme and host
            // are case-insensitive; the port, if any, is digits either way.
            if (std.ascii.eqlIgnoreCase(origin, candidate)) return true;
        }
        return false;
    }

    /// Whether the request declares a JSON body.
    ///
    /// Parameters such as `; charset=utf-8` are tolerated. A missing header is
    /// rejected: the MCP HTTP transport requires `application/json`, and every
    /// real client sends it.
    fn hasJsonContentType(request: *http.Server.Request) bool {
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;

            const media_type = std.mem.trim(
                u8,
                header.value[0 .. std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len],
                " \t",
            );
            return std.ascii.eqlIgnoreCase(media_type, "application/json");
        }
        return false;
    }

    fn handleHttpJsonRpcRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: *http.Server.Request) !void {
        var wants_sse = false;
        var provided_session_id: ?[]const u8 = null;
        var protocol_version: ?[]const u8 = null;
        var header_it = http.HeaderIterator.init(request.head_buffer);
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                if (std.mem.indexOf(u8, header.value, "text/event-stream") != null) {
                    wants_sse = true;
                }
            } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                provided_session_id = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "mcp-protocol-version")) {
                protocol_version = header.value;
            }
        }

        // Absent means the client predates the header, which the spec says to
        // read as 2025-03-26. Present but unsupported is a client error: a
        // client could otherwise negotiate one version at `initialize` and then
        // speak whatever it liked.
        const negotiated_version = protocol_version orelse protocol.SUPPORTED_VERSIONS[2];
        if (protocol_version != null and !isSupportedProtocolVersion(negotiated_version)) {
            try request.respond("Unsupported MCP-Protocol-Version", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        var session: *Session = undefined;
        // Pinned for the rest of the request so a concurrent idle sweep or
        // `DELETE` cannot free it while this connection is still using it.
        var acquired: ?*Session = null;
        defer if (acquired) |a| self.releaseSession(io, a);
        if (provided_session_id) |sid| {
            session = self.acquireSession(io, sid) orelse {
                if (self.wasTerminated(io, sid)) {
                    try request.respond("MCP session terminated; re-initialize", .{
                        .status = .gone,
                        .extra_headers = &.{
                            .{ .name = "Content-Type", .value = "text/plain" },
                        },
                    });
                    return;
                }
                try request.respond("Unknown or expired MCP session", .{
                    .status = .not_found,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
            acquired = session;
            session.last_seen_s = nowSeconds(io);
        }

        // `Content-Length` is absent for a chunked body, which is legal
        // HTTP/1.1 and is what a client emits when it streams a message it has
        // not fully buffered. The size cap is enforced on bytes actually read,
        // so a declared length is an early reject rather than the only check.
        if (request.head.content_length) |declared| {
            if (declared > max_http_body_size) {
                try request.respond("Request body too large", .{
                    .status = .payload_too_large,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            }
        }

        var read_buffer: [2048]u8 = undefined;
        var body_reader = request.readerExpectContinue(&read_buffer) catch {
            try request.respond("Invalid request body", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        // One over the cap, so a body that exceeds it is detectable rather
        // than silently truncated into a parse error.
        // `allocRemaining`, not `readAlloc`: the latter reads *exactly* the
        // length asked for and reports `EndOfStream` for anything shorter,
        // which is every request body a client actually sends.
        //
        // The limit is one over the cap, and `allocRemaining` stops as soon as
        // it is reached, so a body at exactly the cap is accepted and the first
        // byte past it is rejected without reading the rest.
        const body_items = body_reader.allocRemaining(
            allocator,
            .limited(max_http_body_size + 1),
        ) catch |err| {
            const too_large = err == error.StreamTooLong;
            try request.respond(
                if (too_large) "Request body too large" else "Failed to read request body",
                .{
                    .status = if (too_large) .payload_too_large else .bad_request,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                },
            );
            return;
        };
        defer allocator.free(body_items);

        if (body_items.len == 0) {
            try request.respond("Empty JSON-RPC payload", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        // A request that arrives without a session id is only meaningful if it
        // is `initialize`. Rather than pre-parsing the body, serve it with an
        // unregistered session and keep that session only if the handshake
        // actually happened. Anything else gets `Server not initialized`.
        var provisional: ?*Session = null;
        var provisional_plaintext_id: ?[]u8 = null;
        defer if (provisional_plaintext_id) |pid| self.allocator.free(pid);
        var keep_provisional = false;
        defer if (provisional) |p| {
            if (!keep_provisional) self.destroySession(p);
        };

        if (provided_session_id == null) {
            const created = self.createSession(io) catch {
                try request.respond("Too many active MCP sessions", .{
                    .status = .service_unavailable,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
            provisional = created.session;
            provisional_plaintext_id = created.plaintext_id;
            session = created.session;
        }

        var request_transport: HttpRequestTransport = .{ .owner_allocator = allocator };
        defer request_transport.deinit();

        // The reply sink is per-request state, so it hangs off the session
        // being served rather than off `Server`, which every connection shares.
        // The session mutex is held for the whole exchange so two concurrent
        // requests on one session cannot overwrite each other's sink.
        session.mutex.lock(io) catch return error.Canceled;
        defer session.mutex.unlock(io);
        session.reply = request_transport.transport();
        defer session.reply = null;

        self.handleMessage(session, io, allocator, body_items) catch {
            const internal_error = jsonrpc.createParseError(.{ .string = "Internal server error" });
            const json = jsonrpc.serializeMessage(allocator, .{ .error_response = internal_error }) catch {
                try request.respond("Internal server error", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
            defer allocator.free(json);

            try request.respond(json, .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
            return;
        };

        // Only a completed handshake earns a durable session. Anything else
        // leaves the provisional session to be discarded by the deferred
        // cleanup above, so unauthenticated traffic cannot grow the table.
        var emit_session_id: ?[]const u8 = null;
        if (provisional) |p| {
            if (p.state != .uninitialized) {
                self.sessions_mutex.lock(io) catch return error.Canceled;
                defer self.sessions_mutex.unlock(io);
                try self.sessions.put(p.id.?, p);
                keep_provisional = true;
                emit_session_id = provisional_plaintext_id.?;
            }
        }

        // Echoing the version lets a client detect a mismatched or intercepting
        // endpoint rather than discovering it through malformed payloads.
        var header_buf: [3]http.Header = undefined;
        header_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        header_buf[1] = .{ .name = "MCP-Protocol-Version", .value = negotiated_version };
        var header_len: usize = 2;
        if (emit_session_id) |sid| {
            header_buf[2] = .{ .name = "Mcp-Session-Id", .value = sid };
            header_len = 3;
        }

        if (request_transport.messages.items.len > 0) {
            if (wants_sse) {
                // Every message the handler emitted becomes its own event, so
                // progress notifications sent before the result survive. Each
                // carries an id, which is what makes `Last-Event-ID` work.
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(allocator);
                for (request_transport.messages.items) |message| {
                    const id = session.pushEvent(self.allocator, message) catch 0;
                    try appendSseEvent(allocator, &body, id, message);
                }
                header_buf[0] = .{ .name = "Content-Type", .value = "text/event-stream" };
                try request.respond(body.items, .{
                    .status = .ok,
                    .extra_headers = header_buf[0..header_len],
                });
                return;
            }

            try request.respond(request_transport.responseMessage().?, .{
                .status = .ok,
                .extra_headers = header_buf[0..header_len],
            });
            return;
        }

        try request.respond("", .{
            .status = .accepted,
            .extra_headers = header_buf[0..header_len],
        });
    }

    /// Run the server with a custom transport
    pub fn runWithTransport(self: *Self, io: std.Io, allocator: std.mem.Allocator, t: transport_mod.Transport) !void {
        self.transport = t;
        try self.messageLoop(io, allocator);
    }

    /// Everything a server produced in reply to one message.
    ///
    /// A handler may emit progress notifications before its result, so this is
    /// a list rather than a single message.
    pub const Reply = struct {
        allocator: std.mem.Allocator,
        /// In the order the server produced them. Empty for a notification, or
        /// for a request the server chose not to answer.
        messages: []const []const u8,

        pub fn deinit(self: Reply) void {
            for (self.messages) |message| self.allocator.free(message);
            self.allocator.free(self.messages);
        }

        /// The response to a request, which is the last message produced.
        pub fn response(self: Reply) ?[]const u8 {
            if (self.messages.len == 0) return null;
            return self.messages[self.messages.len - 1];
        }
    };

    /// Handles one JSON-RPC message and returns what the server produced,
    /// without involving a transport.
    ///
    /// This is the seam the transports themselves sit on. It exists so a host
    /// that already owns its I/O can use the server, and so a test can assert
    /// on the exact bytes a method produces without standing up a socket
    /// first.
    ///
    /// Messages are allocated from `allocator` and owned by the returned
    /// `Reply`. Uses the implicit session, the same one stdio and custom
    /// transports use.
    pub fn handleMessageAlloc(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        message: []const u8,
    ) !Reply {
        const session = &self.implicit_session;

        var capture: HttpRequestTransport = .{ .owner_allocator = allocator };
        errdefer capture.deinit();

        // Held for the whole exchange so two callers cannot overwrite each
        // other's sink, exactly as the http path does.
        session.mutex.lock(io) catch return error.Canceled;
        defer session.mutex.unlock(io);

        const previous = session.reply;
        session.reply = capture.transport();
        defer session.reply = previous;

        try self.handleMessage(session, io, allocator, message);

        return .{
            .allocator = allocator,
            .messages = try capture.messages.toOwnedSlice(allocator),
        };
    }

    /// Main message processing loop
    fn messageLoop(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        // stdio and custom transports carry exactly one client, so they share
        // the implicit session for the lifetime of the process.
        const session = &self.implicit_session;
        while (self.lifecycle == .running) {
            const message_data = self.transport.?.receive(io, allocator) catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        self.lifecycle = .shutting_down;
                        break;
                    },
                    else => |e| {
                        var buf: [128]u8 = undefined;
                        if (std.fmt.bufPrint(&buf, "Transport receive error: {s}", .{@errorName(e)})) |msg| {
                            self.logError(io, msg);
                        } else |_| {
                            self.logError(io, "Transport receive error");
                        }
                        self.lifecycle = .shutting_down;
                        break;
                    },
                }
            };

            if (message_data) |data| {
                defer allocator.free(data);
                try self.handleMessage(session, io, allocator, data);
            }
        }

        self.lifecycle = .stopped;
    }

    /// Handle an incoming message
    fn handleMessage(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed_message = jsonrpc.parseMessage(aa, data) catch {
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(session, io, aa, .{ .error_response = error_response });
            return;
        };

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(session, io, aa, req),
            .notification => |notif| try self.handleNotification(session, io, notif),
            .response => |resp| self.handleResponse(session, resp),
            .error_response => |err| self.handleErrorResponse(session, io, err),
        }
    }

    /// Handle an incoming request
    fn handleRequest(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Received request: {s}", .{request.method})) |msg| {
            self.log(io, msg);
        } else |_| {}

        if (session.state == .uninitialized and !std.mem.eql(u8, request.method, "initialize")) {
            const error_response = jsonrpc.createErrorResponse(
                request.id,
                jsonrpc.ErrorCode.SERVER_NOT_INITIALIZED,
                "Server not initialized",
                null,
            );
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
            return;
        }

        // JSON-RPC ids identify an exchange, so accepting a repeat while the
        // original is outstanding would make the two responses ambiguous.
        switch (try session.claimRequestId(io, request.id)) {
            .claimed => {},
            .duplicate => {
                const error_response = jsonrpc.createErrorResponse(
                    request.id,
                    jsonrpc.ErrorCode.INVALID_REQUEST,
                    "Duplicate request id",
                    null,
                );
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            },
            .at_capacity => {
                const error_response = jsonrpc.createErrorResponse(
                    request.id,
                    jsonrpc.ErrorCode.INTERNAL_ERROR,
                    "Too many requests in flight",
                    null,
                );
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            },
        }
        defer session.releaseRequestId(io, request.id);

        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.handleInitialize(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try self.handlePing(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            self.handleToolsList(session, io, allocator, request) catch |err| switch (err) {
                // A cursor the client did not get from us is bad input, not a
                // reason to drop the connection.
                error.InvalidCursor => try self.sendInvalidCursor(session, io, allocator, request),
                else => |e| return e,
            };
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolsCall(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/list")) {
            self.handleResourcesList(session, io, allocator, request) catch |err| switch (err) {
                // A cursor the client did not get from us is bad input, not a
                // reason to drop the connection.
                error.InvalidCursor => try self.sendInvalidCursor(session, io, allocator, request),
                else => |e| return e,
            };
        } else if (std.mem.eql(u8, request.method, "resources/read")) {
            try self.handleResourcesRead(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/templates/list")) {
            self.handleResourceTemplatesList(session, io, allocator, request) catch |err| switch (err) {
                // A cursor the client did not get from us is bad input, not a
                // reason to drop the connection.
                error.InvalidCursor => try self.sendInvalidCursor(session, io, allocator, request),
                else => |e| return e,
            };
        } else if (std.mem.eql(u8, request.method, "resources/subscribe")) {
            try self.handleSubscribe(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/unsubscribe")) {
            try self.handleUnsubscribe(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            self.handlePromptsList(session, io, allocator, request) catch |err| switch (err) {
                // A cursor the client did not get from us is bad input, not a
                // reason to drop the connection.
                error.InvalidCursor => try self.sendInvalidCursor(session, io, allocator, request),
                else => |e| return e,
            };
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
            try self.handleSetLogLevel(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "completion/complete")) {
            try self.handleCompletion(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/get")) {
            try self.handleTasksGet(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/result")) {
            try self.handleTasksResult(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/list")) {
            try self.handleTasksList(session, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/cancel")) {
            try self.handleTasksCancel(session, io, allocator, request);
        } else {
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        session.state = .initializing;

        if (request.params) |params| {
            if (params == .object) {
                const obj = params.object;

                if (obj.get("clientInfo")) |client_info_val| {
                    if (client_info_val == .object) {
                        const ci = client_info_val.object;
                        const name = if (ci.get("name")) |n| if (n == .string) n.string else "unknown" else "unknown";
                        const version = if (ci.get("version")) |v| if (v == .string) v.string else "0.0.0" else "0.0.0";
                        if (session.client_info) |existing| {
                            self.allocator.free(existing.name);
                            self.allocator.free(existing.version);
                        }
                        session.client_info = .{
                            .name = try self.allocator.dupe(u8, name),
                            .version = try self.allocator.dupe(u8, version),
                        };
                    }
                }
            }
        }

        // use client's requested version if supported
        var negotiated_version: []const u8 = protocol.VERSION;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("protocolVersion")) |pv| {
                    if (pv == .string) {
                        for (protocol.SUPPORTED_VERSIONS) |sv| {
                            if (std.mem.eql(u8, pv.string, sv)) {
                                negotiated_version = sv;
                                break;
                            }
                        }
                    }
                }
            }
        }

        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        try result.put(allocator, "protocolVersion", .{ .string = negotiated_version });

        var caps: std.json.ObjectMap = .empty;
        if (self.capabilities.tools) |t| {
            var tools_cap: std.json.ObjectMap = .empty;
            try tools_cap.put(allocator, "listChanged", .{ .bool = t.listChanged });
            try caps.put(allocator, "tools", .{ .object = tools_cap });
        }
        if (self.capabilities.resources) |r| {
            var res_cap: std.json.ObjectMap = .empty;
            try res_cap.put(allocator, "listChanged", .{ .bool = r.listChanged });
            try res_cap.put(allocator, "subscribe", .{ .bool = r.subscribe });
            try caps.put(allocator, "resources", .{ .object = res_cap });
        }
        if (self.capabilities.prompts) |p| {
            var prompts_cap: std.json.ObjectMap = .empty;
            try prompts_cap.put(allocator, "listChanged", .{ .bool = p.listChanged });
            try caps.put(allocator, "prompts", .{ .object = prompts_cap });
        }
        if (self.capabilities.logging != null) {
            try caps.put(allocator, "logging", .{ .object = .empty });
        }
        if (self.capabilities.completions != null) {
            try caps.put(allocator, "completions", .{ .object = .empty });
        }
        if (self.capabilities.tasks != null) {
            var tasks_cap: std.json.ObjectMap = .empty;
            try tasks_cap.put(allocator, "list", .{ .object = .empty });
            try tasks_cap.put(allocator, "cancel", .{ .object = .empty });
            var requests_cap: std.json.ObjectMap = .empty;
            var tools_req: std.json.ObjectMap = .empty;
            try tools_req.put(allocator, "call", .{ .object = .empty });
            try requests_cap.put(allocator, "tools", .{ .object = tools_req });
            try tasks_cap.put(allocator, "requests", .{ .object = requests_cap });
            try caps.put(allocator, "tasks", .{ .object = tasks_cap });
        }
        try result.put(allocator, "capabilities", .{ .object = caps });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(allocator, "name", .{ .string = self.config.name });
        try server_info.put(allocator, "version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try server_info.put(allocator, "title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try server_info.put(allocator, "description", .{ .string = d });
        }
        if (self.config.icons) |icons| {
            try putIcons(allocator, &server_info, icons);
        }
        if (self.config.websiteUrl) |u| {
            try server_info.put(allocator, "websiteUrl", .{ .string = u });
        }
        try result.put(allocator, "serverInfo", .{ .object = server_info });

        if (self.config.instructions) |inst| {
            try result.put(allocator, "instructions", .{ .string = inst });
        }

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle ping request
    fn handlePing(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle tools/list request
    fn sendInvalidCursor(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const error_response = jsonrpc.createErrorResponse(
            request.id,
            jsonrpc.ErrorCode.INVALID_PARAMS,
            "Invalid cursor",
            null,
        );
        try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
    }

    /// Collects the keys of `map`, sorts them and returns the page selected by
    /// the request's `cursor`.
    fn pageOf(self: *Self, map: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !Page {
        const keys = try allocator.alloc([]const u8, map.count());
        var iter = map.keyIterator();
        var i: usize = 0;
        while (iter.next()) |k| : (i += 1) keys[i] = k.*;
        return paginateKeys(allocator, keys, listCursor(request), self.config.page_size);
    }

    fn handleToolsList(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tools_array: std.json.Array = .init(allocator);

        const page = try self.pageOf(self.tools, allocator, request);
        for (page.keys) |page_key| {
            const entry = self.tools.getEntry(page_key).?;
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try tool_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try tool_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.icons) |icons| {
                try putIcons(allocator, &tool_obj, icons);
            }

            var input_schema: std.json.ObjectMap = .empty;
            if (entry.value_ptr.inputSchema) |schema| {
                try input_schema.put(allocator, "type", .{ .string = schema.type });

                if (schema.@"$schema") |s| try input_schema.put(allocator, "$schema", .{ .string = s });
                if (schema.description) |d| try input_schema.put(allocator, "description", .{ .string = d });
                if (schema.properties) |p| try input_schema.put(allocator, "properties", p);

                if (schema.required) |req| {
                    var arr: std.json.Array = .init(allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try input_schema.put(allocator, "required", .{ .array = arr });
                }
            } else {
                try input_schema.put(allocator, "type", .{ .string = "object" });
            }
            try tool_obj.put(allocator, "inputSchema", .{ .object = input_schema });

            if (entry.value_ptr.outputSchema) |schema| {
                var output_schema: std.json.ObjectMap = .empty;
                try output_schema.put(allocator, "type", .{ .string = schema.type });
                if (schema.@"$schema") |s| try output_schema.put(allocator, "$schema", .{ .string = s });
                if (schema.properties) |p| try output_schema.put(allocator, "properties", p);
                if (schema.required) |req| {
                    var arr: std.json.Array = .init(allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try output_schema.put(allocator, "required", .{ .array = arr });
                }
                try tool_obj.put(allocator, "outputSchema", .{ .object = output_schema });
            }

            if (entry.value_ptr.annotations) |ann| {
                var ann_obj: std.json.ObjectMap = .empty;
                if (ann.title) |t| try ann_obj.put(allocator, "title", .{ .string = t });
                try ann_obj.put(allocator, "readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put(allocator, "destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put(allocator, "idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put(allocator, "openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put(allocator, "annotations", .{ .object = ann_obj });
            }

            if (entry.value_ptr.execution) |exec| {
                var exec_obj: std.json.ObjectMap = .empty;
                if (exec.taskSupport) |ts| {
                    try exec_obj.put(allocator, "taskSupport", .{ .string = ts });
                }
                try tool_obj.put(allocator, "execution", .{ .object = exec_obj });
            }

            try tools_array.append(.{ .object = tool_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "tools", .{ .array = tools_array });
        if (page.next_cursor) |next| try result.put(allocator, "nextCursor", .{ .string = next });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle tools/call request
    fn handleToolsCall(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tool_name: []const u8 = "";
        var arguments: ?std.json.Value = null;
        var task_meta: ?types.TaskMetadata = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        tool_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
                if (params.object.get("task")) |task_val| {
                    if (task_val == .object) {
                        var ttl: ?i64 = null;
                        if (task_val.object.get("ttl")) |ttl_val| {
                            if (ttl_val == .integer) {
                                ttl = @intCast(ttl_val.integer);
                            }
                        }
                        task_meta = .{ .ttl = ttl };
                    }
                }
            }
        }

        if (self.tools.get(tool_name)) |tool| {
            const tasks_enabled = self.capabilities.tasks != null and self.capabilities.tasks.?.requests != null and self.capabilities.tasks.?.requests.?.tools != null and self.capabilities.tasks.?.requests.?.tools.?.call != null;
            const task_support = if (tool.execution) |exec| exec.taskSupport else null;

            if (tasks_enabled and task_support != null and std.mem.eql(u8, task_support.?, "required") and task_meta == null) {
                const error_response = jsonrpc.createMethodNotFound(request.id, "tools/call");
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            }

            if (tasks_enabled and task_meta != null) {
                if (task_support == null or std.mem.eql(u8, task_support.?, "forbidden")) {
                    const error_response = jsonrpc.createMethodNotFound(request.id, "tools/call");
                    try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                    return;
                }

                var status_message: ?[]const u8 = null;
                if (session.tasks.count() >= self.max_tasks_per_session) {
                    const error_response = jsonrpc.createErrorResponse(
                        request.id,
                        jsonrpc.ErrorCode.INTERNAL_ERROR,
                        "Task limit reached for this session",
                        null,
                    );
                    try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                    return;
                }
                const tool_result: tools_mod.ToolResult = tool.handler(tool.user_data, io, allocator, arguments) catch |err| blk: {
                    const msg = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
                    status_message = msg;
                    var content = try self.allocator.alloc(types.ContentBlock, 1);
                    content[0] = .{ .text = .{ .text = msg } };
                    break :blk tools_mod.ToolResult{ .content = content, .is_error = true };
                };

                const result_json = try self.serializeToolCallResult(tool_result);
                const task_id = try generateTaskId(io, self.allocator);
                const created_at = try nowIsoTimestamp(io, self.allocator);
                const updated_at = try self.allocator.dupe(u8, created_at);

                const task: types.Task = .{
                    .taskId = task_id,
                    .status = if (tool_result.is_error) .failed else .completed,
                    .statusMessage = status_message,
                    .createdAt = created_at,
                    .lastUpdatedAt = updated_at,
                    .ttl = if (task_meta) |meta| meta.ttl else null,
                    .pollInterval = null,
                };

                try session.tasks.put(task_id, .{ .task = task, .result_json = result_json });

                const task_obj = try buildTaskObject(allocator, task);
                var result: std.json.ObjectMap = .empty;
                try result.put(allocator, "task", .{ .object = task_obj });

                const response = jsonrpc.createResponse(request.id, .{ .object = result });
                try self.sendResponse(session, io, allocator, .{ .response = response });
                return;
            }

            const tool_result = tool.handler(tool.user_data, io, allocator, arguments) catch |err| {
                var content = try allocator.alloc(types.ContentBlock, 1);
                content[0] = .{ .text = .{ .text = @errorName(err) } };
                const result_value = try buildToolCallResultValue(allocator, .{ .content = content, .is_error = true });
                const response = jsonrpc.createResponse(request.id, result_value);
                try self.sendResponse(session, io, allocator, .{ .response = response });
                return;
            };

            const result_value = try buildToolCallResultValue(allocator, tool_result);
            const response = jsonrpc.createResponse(request.id, result_value);
            try self.sendResponse(session, io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/list request
    fn handleResourcesList(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var resources_array: std.json.Array = .init(allocator);

        const page = try self.pageOf(self.resources, allocator, request);
        for (page.keys) |page_key| {
            const entry = self.resources.getEntry(page_key).?;
            var resource_obj: std.json.ObjectMap = .empty;
            try resource_obj.put(allocator, "uri", .{ .string = entry.value_ptr.uri });
            try resource_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try resource_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try resource_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try resource_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (entry.value_ptr.icons) |icons| {
                try putIcons(allocator, &resource_obj, icons);
            }
            if (entry.value_ptr.annotations) |ann| {
                try putAnnotations(allocator, &resource_obj, ann);
            }
            if (entry.value_ptr.size) |s| {
                try resource_obj.put(allocator, "size", .{ .integer = @intCast(s) });
            }
            if (entry.value_ptr._meta) |meta| {
                try resource_obj.put(allocator, "_meta", meta);
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resources", .{ .array = resources_array });
        if (page.next_cursor) |next| try result.put(allocator, "nextCursor", .{ .string = next });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle resources/read request
    fn handleResourcesRead(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var uri: []const u8 = "";

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("uri")) |uri_val| {
                    if (uri_val == .string) {
                        uri = uri_val.string;
                    }
                }
            }
        }

        if (self.resources.get(uri)) |resource| {
            const content = resource.handler(resource.user_data, io, allocator, uri) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            };

            var contents_array: std.json.Array = .init(allocator);
            var content_obj: std.json.ObjectMap = .empty;
            try content_obj.put(allocator, "uri", .{ .string = uri });
            if (content.text) |text| {
                try content_obj.put(allocator, "text", .{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put(allocator, "blob", .{ .string = blob });
            }
            if (content.mimeType) |mime| {
                try content_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (content._meta) |meta| {
                try content_obj.put(allocator, "_meta", meta);
            }
            try contents_array.append(.{ .object = content_obj });

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "contents", .{ .array = contents_array });

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(session, io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/templates/list request
    fn handleResourceTemplatesList(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var templates_array: std.json.Array = .init(allocator);

        const page = try self.pageOf(self.resource_templates, allocator, request);
        for (page.keys) |page_key| {
            const entry = self.resource_templates.getEntry(page_key).?;
            var template_obj: std.json.ObjectMap = .empty;
            try template_obj.put(allocator, "uriTemplate", .{ .string = entry.value_ptr.uriTemplate });
            try template_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try template_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try template_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try template_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (entry.value_ptr.icons) |icons| {
                try putIcons(allocator, &template_obj, icons);
            }
            if (entry.value_ptr.annotations) |ann| {
                try putAnnotations(allocator, &template_obj, ann);
            }
            if (entry.value_ptr._meta) |meta| {
                try template_obj.put(allocator, "_meta", meta);
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resourceTemplates", .{ .array = templates_array });
        if (page.next_cursor) |next| try result.put(allocator, "nextCursor", .{ .string = next });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle resources/subscribe request
    fn handleSubscribe(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle resources/unsubscribe request
    fn handleUnsubscribe(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompts_array: std.json.Array = .init(allocator);

        const page = try self.pageOf(self.prompts, allocator, request);
        for (page.keys) |page_key| {
            const entry = self.prompts.getEntry(page_key).?;
            var prompt_obj: std.json.ObjectMap = .empty;
            try prompt_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try prompt_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try prompt_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.icons) |icons| {
                try putIcons(allocator, &prompt_obj, icons);
            }

            if (entry.value_ptr.arguments) |args| {
                var args_array: std.json.Array = .init(allocator);
                for (args) |arg| {
                    var arg_obj: std.json.ObjectMap = .empty;
                    try arg_obj.put(allocator, "name", .{ .string = arg.name });
                    if (arg.title) |t| {
                        try arg_obj.put(allocator, "title", .{ .string = t });
                    }
                    if (arg.description) |d| {
                        try arg_obj.put(allocator, "description", .{ .string = d });
                    }
                    try arg_obj.put(allocator, "required", .{ .bool = arg.required });
                    try args_array.append(.{ .object = arg_obj });
                }
                try prompt_obj.put(allocator, "arguments", .{ .array = args_array });
            }

            if (entry.value_ptr._meta) |meta| {
                try prompt_obj.put(allocator, "_meta", meta);
            }

            try prompts_array.append(.{ .object = prompt_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "prompts", .{ .array = prompts_array });
        if (page.next_cursor) |next| try result.put(allocator, "nextCursor", .{ .string = next });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle prompts/get request
    fn handlePromptsGet(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompt_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        prompt_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
            }
        }

        if (self.prompts.get(prompt_name)) |prompt| {
            const messages = prompt.handler(prompt.user_data, io, allocator, arguments) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            };

            var messages_array: std.json.Array = .init(allocator);
            for (messages) |msg| {
                var msg_obj: std.json.ObjectMap = .empty;
                try msg_obj.put(allocator, "role", .{ .string = msg.role.toString() });
                var content_obj: std.json.ObjectMap = .empty;
                switch (msg.content) {
                    .text => |text| {
                        try content_obj.put(allocator, "type", .{ .string = "text" });
                        try content_obj.put(allocator, "text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try content_obj.put(allocator, "type", .{ .string = "image" });
                        try content_obj.put(allocator, "data", .{ .string = img.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try content_obj.put(allocator, "type", .{ .string = "audio" });
                        try content_obj.put(allocator, "data", .{ .string = aud.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try content_obj.put(allocator, "type", .{ .string = "resource_link" });
                        try content_obj.put(allocator, "uri", .{ .string = link.uri });
                        try content_obj.put(allocator, "name", .{ .string = link.name });
                    },
                    .resource => |res| {
                        try content_obj.put(allocator, "type", .{ .string = "resource" });
                        var res_inner: std.json.ObjectMap = .empty;
                        try res_inner.put(allocator, "uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_inner.put(allocator, "text", .{ .string = text });
                        try content_obj.put(allocator, "resource", .{ .object = res_inner });
                    },
                }
                try msg_obj.put(allocator, "content", .{ .object = content_obj });
                try messages_array.append(.{ .object = msg_obj });
            }

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "messages", .{ .array = messages_array });
            if (prompt.description) |desc| {
                try result.put(allocator, "description", .{ .string = desc });
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(session, io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle logging/setLevel request
    fn handleSetLogLevel(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("level")) |level_val| {
                    if (level_val == .string) {
                        const level_str = level_val.string;
                        if (std.mem.eql(u8, level_str, "debug")) {
                            session.log_level = .debug;
                        } else if (std.mem.eql(u8, level_str, "info")) {
                            session.log_level = .info;
                        } else if (std.mem.eql(u8, level_str, "notice")) {
                            session.log_level = .notice;
                        } else if (std.mem.eql(u8, level_str, "warning")) {
                            session.log_level = .warning;
                        } else if (std.mem.eql(u8, level_str, "error")) {
                            session.log_level = .@"error";
                        } else if (std.mem.eql(u8, level_str, "critical")) {
                            session.log_level = .critical;
                        } else if (std.mem.eql(u8, level_str, "alert")) {
                            session.log_level = .alert;
                        } else if (std.mem.eql(u8, level_str, "emergency")) {
                            session.log_level = .emergency;
                        }
                    }
                }
            }
        }

        const result: std.json.ObjectMap = .empty;
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle completion/complete request
    fn handleCompletion(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var completion: std.json.ObjectMap = .empty;
        const values_array: std.json.Array = .init(allocator);
        try completion.put(allocator, "values", .{ .array = values_array });
        try completion.put(allocator, "hasMore", .{ .bool = false });

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "completion", .{ .object = completion });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle tasks/get request
    fn handleTasksGet(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
            return;
        };

        if (session.tasks.get(id)) |entry| {
            const task_obj = try buildTaskObject(allocator, entry.task);
            const response = jsonrpc.createResponse(request.id, .{ .object = task_obj });
            try self.sendResponse(session, io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle tasks/result request
    fn handleTasksResult(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
            return;
        };

        if (session.tasks.get(id)) |entry| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.result_json, .{});
            defer parsed.deinit();

            if (parsed.value == .object) {
                var result_obj = parsed.value.object;
                if (result_obj.get("_meta") == null) {
                    var meta_obj: std.json.ObjectMap = .empty;
                    var related_obj: std.json.ObjectMap = .empty;
                    try related_obj.put(allocator, "taskId", .{ .string = entry.task.taskId });
                    try meta_obj.put(allocator, "io.modelcontextprotocol/related-task", .{ .object = related_obj });
                    try result_obj.put(allocator, "_meta", .{ .object = meta_obj });
                }
                const response = jsonrpc.createResponse(request.id, .{ .object = result_obj });
                try self.sendResponse(session, io, allocator, .{ .response = response });
                return;
            }

            const error_response = jsonrpc.createInternalError(request.id, .{ .string = "Invalid task result" });
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle tasks/list request
    fn handleTasksList(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        var tasks_array: std.json.Array = .init(allocator);

        var iter = session.tasks.iterator();
        while (iter.next()) |entry| {
            const task_obj = try buildTaskObject(allocator, entry.value_ptr.task);
            try tasks_array.append(.{ .object = task_obj });
        }
        try result.put(allocator, "tasks", .{ .array = tasks_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(session, io, allocator, .{ .response = response });
    }

    /// Handle tasks/cancel request
    fn handleTasksCancel(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
            return;
        };

        if (session.tasks.getPtr(id)) |entry| {
            if (entry.task.status == .completed or entry.task.status == .failed or entry.task.status == .cancelled) {
                const error_response = jsonrpc.createInvalidParams(request.id, "Task already in terminal status");
                try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
                return;
            }

            entry.task.status = .cancelled;
            const updated = try nowIsoTimestamp(io, self.allocator);
            self.allocator.free(entry.task.lastUpdatedAt);
            entry.task.lastUpdatedAt = updated;

            const task_obj = try buildTaskObject(allocator, entry.task);
            const response = jsonrpc.createResponse(request.id, .{ .object = task_obj });
            try self.sendResponse(session, io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(session, io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle incoming notifications
    fn handleNotification(self: *Self, session: *Session, io: std.Io, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
            session.state = .ready;
            self.log(io, "Server initialized and ready");
        } else if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        _ = req_id;
                    }
                }
            }
        } else if (std.mem.eql(u8, notification.method, "notifications/roots/list_changed")) {
            self.log(io, "Roots list changed");
        }
    }

    /// Handle incoming response to a request we sent
    fn handleResponse(_: *Self, session: *Session, response: jsonrpc.Response) void {
        const id = switch (response.id) {
            .integer => |i| i,
            .string => return,
        };
        _ = session.pending_requests.remove(id);
    }

    /// Handle incoming error response
    fn handleErrorResponse(self: *Self, session: *Session, io: std.Io, err: jsonrpc.ErrorResponse) void {
        if (err.id) |id| {
            const int_id = switch (id) {
                .integer => |i| i,
                .string => return,
            };
            _ = session.pending_requests.remove(int_id);
        }
        self.logError(io, err.@"error".message);
    }

    /// Send a notification to the client
    pub fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        const json = jsonrpc.serializeMessage(allocator, .{ .notification = notification }) catch {
            self.logError(io, "Failed to serialize notification");
            return;
        };
        defer allocator.free(json);

        // Server-initiated notifications are not a reply to any request. stdio
        // and custom transports have one client on the server-wide transport;
        // HTTP clients pick them up on their `GET` event stream.
        if (self.transport) |t| {
            t.send(io, allocator, json) catch self.logError(io, "Failed to send notification");
        }
        self.broadcastEvent(io, json);
    }

    /// Send a log message notification
    pub fn sendLogMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, level: protocol.LogLevel, message: []const u8) !void {
        if (@intFromEnum(level) < @intFromEnum(self.implicit_session.log_level)) return;

        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "level", .{ .string = level.toString() });
        try params.put(allocator, "data", .{ .string = message });

        try self.sendNotification(io, allocator, "notifications/message", .{ .object = params });
    }

    /// Send a progress notification
    pub fn sendProgress(self: *Self, io: std.Io, allocator: std.mem.Allocator, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "progressToken", token);
        try params.put(allocator, "progress", .{ .float = prog });
        if (total) |t| {
            try params.put(allocator, "total", .{ .float = t });
        }
        if (message) |m| {
            try params.put(allocator, "message", .{ .string = m });
        }
        try self.sendNotification(io, allocator, "notifications/progress", .{ .object = params });
    }

    /// Notify clients that tools have changed
    pub fn notifyToolsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/tools/list_changed", null);
    }

    /// Notify clients that resources have changed
    pub fn notifyResourcesChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/resources/list_changed", null);
    }

    /// Notify clients that a resource has been updated
    pub fn notifyResourceUpdated(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendNotification(io, allocator, "notifications/resources/updated", .{ .object = params });
    }

    /// Notify clients that prompts have changed
    pub fn notifyPromptsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/prompts/list_changed", null);
    }

    /// Send a response message back to the session that made the request.
    fn sendResponse(self: *Self, session: *Session, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        // `session.reply` is set by the HTTP path per request; stdio and
        // custom transports have a single server-wide transport instead.
        return self.sendVia(session.reply orelse self.transport, io, allocator, message);
    }

    /// Serialize and write a message to an explicit transport.
    fn sendVia(self: *Self, dest: ?transport_mod.Transport, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        if (dest) |t| {
            const json = jsonrpc.serializeMessage(allocator, message) catch {
                self.logError(io, "Failed to serialize response");
                return;
            };
            defer allocator.free(json);
            t.send(io, allocator, json) catch {
                self.logError(io, "Failed to send response");
                return;
            };
        }
    }

    fn nowIsoTimestamp(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
        const now_ts = std.Io.Clock.real.now(io);
        const now_secs: i64 = now_ts.toSeconds();
        const secs: u64 = if (now_secs < 0) 0 else @intCast(now_secs);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        const year: u16 = year_day.year;
        const month: u4 = month_day.month.numeric();
        const day: u5 = month_day.day_index + 1;
        const hour: u5 = day_seconds.getHoursIntoDay();
        const minute: u6 = day_seconds.getMinutesIntoHour();
        const second: u6 = day_seconds.getSecondsIntoMinute();

        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year,
            month,
            day,
            hour,
            minute,
            second,
        });
    }

    fn generateTaskId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
        var bytes: [16]u8 = undefined;
        io.randomSecure(&bytes) catch io.random(&bytes);

        var hex_buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{bytes[i]}) catch unreachable;
        }
        return allocator.dupe(u8, &hex_buf);
    }

    fn buildToolCallResultValue(allocator: std.mem.Allocator, tool_result: tools_mod.ToolResult) !std.json.Value {
        var content_array: std.json.Array = .init(allocator);
        for (tool_result.content) |content_item| {
            var item_obj: std.json.ObjectMap = .empty;
            switch (content_item) {
                .text => |text| {
                    try item_obj.put(allocator, "type", .{ .string = "text" });
                    try item_obj.put(allocator, "text", .{ .string = text.text });
                },
                .image => |img| {
                    try item_obj.put(allocator, "type", .{ .string = "image" });
                    try item_obj.put(allocator, "data", .{ .string = img.data });
                    try item_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
                },
                .audio => |aud| {
                    try item_obj.put(allocator, "type", .{ .string = "audio" });
                    try item_obj.put(allocator, "data", .{ .string = aud.data });
                    try item_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
                },
                .resource_link => |link| {
                    try item_obj.put(allocator, "type", .{ .string = "resource_link" });
                    try item_obj.put(allocator, "uri", .{ .string = link.uri });
                    try item_obj.put(allocator, "name", .{ .string = link.name });
                    if (link.title) |t| try item_obj.put(allocator, "title", .{ .string = t });
                    if (link.description) |d| try item_obj.put(allocator, "description", .{ .string = d });
                    if (link.mimeType) |m| try item_obj.put(allocator, "mimeType", .{ .string = m });
                },
                .resource => |res| {
                    try item_obj.put(allocator, "type", .{ .string = "resource" });
                    var res_obj: std.json.ObjectMap = .empty;
                    try res_obj.put(allocator, "uri", .{ .string = res.resource.uri });
                    if (res.resource.text) |text| try res_obj.put(allocator, "text", .{ .string = text });
                    if (res.resource.mimeType) |mime| try res_obj.put(allocator, "mimeType", .{ .string = mime });
                    try item_obj.put(allocator, "resource", .{ .object = res_obj });
                },
            }
            try content_array.append(.{ .object = item_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "content", .{ .array = content_array });
        try result.put(allocator, "isError", .{ .bool = tool_result.is_error });
        if (tool_result.structuredContent) |sc| {
            try result.put(allocator, "structuredContent", sc);
        }
        return .{ .object = result };
    }

    fn serializeToolCallResult(self: *Self, tool_result: tools_mod.ToolResult) ![]const u8 {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();

        const result_value = try buildToolCallResultValue(arena.allocator(), tool_result);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        try jsonrpc.serializeValue(self.allocator, &buffer, result_value);
        return buffer.toOwnedSlice(self.allocator);
    }

    fn buildTaskObject(allocator: std.mem.Allocator, task: types.Task) !std.json.ObjectMap {
        var task_obj: std.json.ObjectMap = .empty;
        try task_obj.put(allocator, "taskId", .{ .string = task.taskId });
        try task_obj.put(allocator, "status", .{ .string = task.status.toString() });
        if (task.statusMessage) |msg| {
            try task_obj.put(allocator, "statusMessage", .{ .string = msg });
        }
        try task_obj.put(allocator, "createdAt", .{ .string = task.createdAt });
        try task_obj.put(allocator, "lastUpdatedAt", .{ .string = task.lastUpdatedAt });
        if (task.ttl) |ttl| {
            try task_obj.put(allocator, "ttl", .{ .integer = ttl });
        }
        if (task.pollInterval) |interval| {
            try task_obj.put(allocator, "pollInterval", .{ .integer = interval });
        }
        return task_obj;
    }

    fn putIcons(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, icons: []const types.Icon) !void {
        var icons_array: std.json.Array = .init(allocator);
        for (icons) |icon| {
            var icon_obj: std.json.ObjectMap = .empty;
            try icon_obj.put(allocator, "src", .{ .string = icon.src });
            if (icon.mimeType) |mime| {
                try icon_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (icon.sizes) |sizes| {
                var sizes_array: std.json.Array = .init(allocator);
                for (sizes) |size| {
                    try sizes_array.append(.{ .string = size });
                }
                try icon_obj.put(allocator, "sizes", .{ .array = sizes_array });
            }
            if (icon.theme) |theme| {
                try icon_obj.put(allocator, "theme", .{ .string = @tagName(theme) });
            }
            try icons_array.append(.{ .object = icon_obj });
        }
        try obj.put(allocator, "icons", .{ .array = icons_array });
    }

    fn putAnnotations(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, annotations: types.Annotations) !void {
        var ann_obj: std.json.ObjectMap = .empty;
        if (annotations.audience) |aud| {
            var aud_array: std.json.Array = .init(allocator);
            for (aud) |role| {
                try aud_array.append(.{ .string = role.toString() });
            }
            try ann_obj.put(allocator, "audience", .{ .array = aud_array });
        }
        if (annotations.priority) |priority| {
            try ann_obj.put(allocator, "priority", .{ .float = priority });
        }
        if (annotations.lastModified) |last_modified| {
            try ann_obj.put(allocator, "lastModified", .{ .string = last_modified });
        }
        try obj.put(allocator, "annotations", .{ .object = ann_obj });
    }

    fn log(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(io, message);
        }
    }

    fn logError(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(io, formatted);
        }
    }
};

test "Server initialization" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expectEqual(SessionState.uninitialized, server.implicit_session.state);
    try std.testing.expectEqual(Lifecycle.running, server.lifecycle);
    try std.testing.expectEqualStrings("test-server", server.config.name);
}

test "Server add tool" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const tool: tools_mod.Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !tools_mod.ToolResult {
                return .{ .content = &.{} };
            }
        }.handler,
    };

    try server.addTool(tool);
    try std.testing.expect(server.tools.contains("test_tool"));
    try std.testing.expect(server.capabilities.tools != null);
}

test "Server add resource" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResource(.{
        .uri = "file:///test",
        .name = "Test",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !resources_mod.ResourceContent {
                return .{ .uri = uri };
            }
        }.handler,
    });
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const prompts_mod.PromptMessage {
                return &.{};
            }
        }.handler,
    });
    try std.testing.expect(server.prompts.contains("test_prompt"));
    try std.testing.expect(server.capabilities.prompts != null);
}

test "Server enable capabilities" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    server.enableLogging();
    server.enableCompletions();
    server.enableTasks();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
    try std.testing.expect(server.capabilities.tasks != null);
}

test "HttpRequestTransport response outlives the per-message arena" {
    // Regression test for the use-after-free / invalid free in
    // handleHttpJsonRpcRequest: handleMessage wraps each message in an
    // ArenaAllocator and passes the arena allocator down to Transport.send.
    // If the transport dupes the response with that arena allocator, the
    // buffer is freed by arena.deinit() before the caller reads it and is
    // then freed a second time by the transport's own deinit.
    //
    // Two sequential messages are required: with the bug present the first
    // one still appears to succeed, because the arena's backing pages are
    // still mapped and nothing has reused them yet.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    for (0..2) |i| {
        var request_transport: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
        defer request_transport.deinit();

        const previous_transport = server.transport;
        server.transport = request_transport.transport();
        defer server.transport = previous_transport;

        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}", .{i});

        try server.handleMessage(&server.implicit_session, io, std.testing.allocator, body);

        // Read the response after handleMessage has returned, i.e. after its
        // arena has been destroyed. This is the use-after-free.
        const response = request_transport.responseMessage() orelse
            return error.NoResponseProduced;
        try std.testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
    }
}

test "HttpRequestTransport replaces an earlier response without leaking" {
    // send() may be called more than once for a single message; the previous
    // buffer must be freed with the same allocator that allocated it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var request_transport: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer request_transport.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const aa = arena.allocator();

    try request_transport.send(io, aa, "first");
    try request_transport.send(io, aa, "second");

    // Destroying the scratch arena must not invalidate the stored response.
    arena.deinit();

    try std.testing.expectEqualStrings("second", request_transport.responseMessage().?);
}

test "isLoopbackHost recognises loopback forms" {
    const loopback = [_][]const u8{
        "localhost",
        "LOCALHOST",
        "127.0.0.1",
        // The whole of 127.0.0.0/8 is loopback, not just .0.1.
        "127.0.0.2",
        "127.1.2.3",
        "127.255.255.254",
        "::1",
        "[::1]",
        // IPv4-mapped loopback.
        "::ffff:127.0.0.1",
    };
    for (loopback) |host| {
        try std.testing.expect(Server.isLoopbackHost(host));
    }
}

test "isLoopbackHost treats routable and unknown hosts as non-loopback" {
    const routable = [_][]const u8{
        // Wildcard binds are reachable from off-machine.
        "0.0.0.0",
        "::",
        "[::]",
        "192.168.1.10",
        "10.0.0.1",
        "8.8.8.8",
        // 128.x is deliberately adjacent to 127.x.
        "128.0.0.1",
        "126.255.255.255",
        "::ffff:8.8.8.8",
        "example.com",
        // Anything unparseable must fail closed.
        "",
        "not a host",
        "localhost.evil.com",
    };
    for (routable) |host| {
        try std.testing.expect(!Server.isLoopbackHost(host));
    }
}

test "HttpRunConfig allows an unauthenticated loopback bind" {
    // The default configuration must keep working without ceremony.
    try (Server.HttpRunConfig{}).validate();
    try (Server.HttpRunConfig{ .host = "127.0.0.1" }).validate();
    try (Server.HttpRunConfig{ .host = "::1" }).validate();
}

test "HttpRunConfig requires opt-in for a non-loopback bind" {
    try std.testing.expectError(
        error.NonLoopbackBindRequiresOptIn,
        (Server.HttpRunConfig{ .host = "0.0.0.0" }).validate(),
    );
    try std.testing.expectError(
        error.NonLoopbackBindRequiresOptIn,
        (Server.HttpRunConfig{ .host = "0.0.0.0", .auth_token = "x" ** 32 }).validate(),
    );
}

test "HttpRunConfig requires a token once a non-loopback bind is opted into" {
    try std.testing.expectError(
        error.NonLoopbackBindRequiresAuthToken,
        (Server.HttpRunConfig{ .host = "0.0.0.0", .allow_non_loopback = true }).validate(),
    );

    // Opted in and authenticated is the one accepted combination.
    try (Server.HttpRunConfig{
        .host = "0.0.0.0",
        .allow_non_loopback = true,
        .auth_token = "x" ** 32,
    }).validate();
}

test "HttpRunConfig rejects a short token even on loopback" {
    // A weak token is worse than none, because it invites reliance on it.
    try std.testing.expectError(
        error.AuthTokenTooShort,
        (Server.HttpRunConfig{ .auth_token = "short" }).validate(),
    );
    try std.testing.expectError(
        error.AuthTokenTooShort,
        (Server.HttpRunConfig{
            .host = "0.0.0.0",
            .allow_non_loopback = true,
            .auth_token = "x" ** 31,
        }).validate(),
    );
    try (Server.HttpRunConfig{ .auth_token = "x" ** 32 }).validate();
}

test "originIsAllowed matches only listed origins" {
    const allowed = [_][]const u8{ "https://app.example.com", "http://localhost:3000" };

    try std.testing.expect(Server.originIsAllowed("https://app.example.com", &allowed));
    try std.testing.expect(Server.originIsAllowed("http://localhost:3000", &allowed));
    // Scheme and host are case-insensitive.
    try std.testing.expect(Server.originIsAllowed("HTTPS://APP.EXAMPLE.COM", &allowed));

    const rejected = [_][]const u8{
        // Wrong scheme, wrong port, and lookalike hosts must all fail.
        "http://app.example.com",
        "https://app.example.com:8443",
        "https://evil.com",
        "https://app.example.com.evil.com",
        "https://evilapp.example.com",
        "http://localhost:3001",
        "null",
        "",
    };
    for (rejected) |origin| {
        try std.testing.expect(!Server.originIsAllowed(origin, &allowed));
    }
}

test "originIsAllowed rejects everything when no origins are configured" {
    const none: []const []const u8 = &.{};
    try std.testing.expect(!Server.originIsAllowed("https://app.example.com", none));
    try std.testing.expect(!Server.originIsAllowed("null", none));
    try std.testing.expect(!Server.originIsAllowed("", none));
}

/// Drive one JSON-RPC message through `server` on `session` and return the
/// response body. Caller owns the returned slice.
fn testRoundTrip(server: *Server, session: *Session, io: std.Io, message: []const u8) ![]u8 {
    var request_transport: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer request_transport.deinit();

    const previous_reply = session.reply;
    session.reply = request_transport.transport();
    defer session.reply = previous_reply;

    try server.handleMessage(session, io, std.testing.allocator, message);
    const response = request_transport.responseMessage() orelse return error.NoResponseProduced;
    return std.testing.allocator.dupe(u8, response);
}

/// Create a session and register it, as a completed handshake would.
fn testRegisterSession(server: *Server, io: std.Io) !*Session {
    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);
    return created.session;
}

const test_initialize_message =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
;

test "initialize on one session does not initialize another" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const a = try testRegisterSession(&server, io);
    const b = try testRegisterSession(&server, io);

    const resp_a = try testRoundTrip(&server, a, io, test_initialize_message);
    defer std.testing.allocator.free(resp_a);
    try std.testing.expect(std.mem.indexOf(u8, resp_a, "\"result\"") != null);
    try std.testing.expect(a.state != .uninitialized);

    // The handshake belongs to `a` alone. Before per-session state this was a
    // single field on Server, so `b` inherited it and skipped initialize.
    try std.testing.expectEqual(SessionState.uninitialized, b.state);

    const resp_b = try testRoundTrip(&server, b, io,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    defer std.testing.allocator.free(resp_b);
    try std.testing.expect(std.mem.indexOf(u8, resp_b, "Server not initialized") != null);
}

test "tasks are not readable across sessions" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const a = try testRegisterSession(&server, io);
    const b = try testRegisterSession(&server, io);
    for ([_]*Session{ a, b }) |s| {
        const resp = try testRoundTrip(&server, s, io, test_initialize_message);
        std.testing.allocator.free(resp);
    }

    // Strings here are freed by Session.deinit, which mirrors the real
    // ownership: the map key aliases task.taskId.
    const task_id = try std.testing.allocator.dupe(u8, "task-abc");
    const created_at = try std.testing.allocator.dupe(u8, "2026-01-01T00:00:00Z");
    const updated_at = try std.testing.allocator.dupe(u8, "2026-01-01T00:00:00Z");
    const result_json = try std.testing.allocator.dupe(u8, "{}");
    try a.tasks.put(task_id, .{
        .task = .{
            .taskId = task_id,
            .status = .completed,
            .statusMessage = null,
            .createdAt = created_at,
            .lastUpdatedAt = updated_at,
            .ttl = null,
            .pollInterval = null,
        },
        .result_json = result_json,
    });

    const get_msg =
        \\{"jsonrpc":"2.0","id":3,"method":"tasks/get","params":{"taskId":"task-abc"}}
    ;

    const owner_resp = try testRoundTrip(&server, a, io, get_msg);
    defer std.testing.allocator.free(owner_resp);
    try std.testing.expect(std.mem.indexOf(u8, owner_resp, "task-abc") != null);

    // A second client must not be able to read another client's task.
    const other_resp = try testRoundTrip(&server, b, io, get_msg);
    defer std.testing.allocator.free(other_resp);
    try std.testing.expect(std.mem.indexOf(u8, other_resp, "task-abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, other_resp, "\"error\"") != null);
}

test "logging/setLevel is scoped to the calling session" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const a = try testRegisterSession(&server, io);
    const b = try testRegisterSession(&server, io);
    for ([_]*Session{ a, b }) |s| {
        const resp = try testRoundTrip(&server, s, io, test_initialize_message);
        std.testing.allocator.free(resp);
    }

    const resp = try testRoundTrip(&server, a, io,
        \\{"jsonrpc":"2.0","id":4,"method":"logging/setLevel","params":{"level":"emergency"}}
    );
    defer std.testing.allocator.free(resp);

    try std.testing.expectEqual(protocol.LogLevel.emergency, a.log_level);
    // One client must not be able to silence another's notifications.
    try std.testing.expectEqual(protocol.LogLevel.info, b.log_level);
}

test "session lookup only succeeds for the exact issued id" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);

    // 32 random bytes rendered as hex.
    try std.testing.expectEqual(@as(usize, 64), created.plaintext_id.len);
    for (created.plaintext_id) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }

    try std.testing.expect(server.lookupSession(created.plaintext_id) == created.session);
    try std.testing.expect(server.lookupSession("") == null);
    try std.testing.expect(server.lookupSession("not-a-session") == null);
    // The table is keyed by digest, so the digest is not itself a valid id.
    try std.testing.expect(server.lookupSession(created.session.id.?) == null);
}

test "session ids are unique per session" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const first = try server.createSession(io);
    defer std.testing.allocator.free(first.plaintext_id);
    try server.sessions.put(first.session.id.?, first.session);

    const second = try server.createSession(io);
    defer std.testing.allocator.free(second.plaintext_id);
    try server.sessions.put(second.session.id.?, second.session);

    try std.testing.expect(!std.mem.eql(u8, first.plaintext_id, second.plaintext_id));
}

test "idle sessions are reclaimed" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const session = try testRegisterSession(&server, io);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.count());

    session.last_seen_s = 0;
    server.session_idle_timeout_s = 1;
    server.sweepIdleSessions(io);

    try std.testing.expectEqual(@as(usize, 0), server.sessions.count());
}

test "session table is capped" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();
    server.max_sessions = 1;

    _ = try testRegisterSession(&server, io);
    try std.testing.expectError(error.TooManySessions, server.createSession(io));
}

test "destroySession removes the session from the table" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);

    server.destroySession(created.session);
    try std.testing.expectEqual(@as(usize, 0), server.sessions.count());
    try std.testing.expect(server.lookupSession(created.plaintext_id) == null);
}

test "an unregistered provisional session is freed cleanly" {
    // Every request that arrives without a session id mints a provisional
    // session that is discarded unless the handshake succeeds. The testing
    // allocator fails this test if that discard path leaks.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1.0.0" });
    defer server.deinit();

    for (0..8) |_| {
        const created = try server.createSession(io);
        defer std.testing.allocator.free(created.plaintext_id);
        try std.testing.expectEqual(SessionState.uninitialized, created.session.state);
        server.destroySession(created.session);
    }

    try std.testing.expectEqual(@as(usize, 0), server.sessions.count());
}

test "a response goes to the requesting session's reply sink" {
    // Regression: the HTTP path used to stash the per-request reply sink on the
    // shared `Server.transport`. Two connections in flight at once clobbered
    // each other, so one client could receive another client's response.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const a = try testRegisterSession(&server, io);
    const b = try testRegisterSession(&server, io);

    var sink_a: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer sink_a.deinit();
    var sink_b: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer sink_b.deinit();

    // Both connections are mid-request, B having arrived second.
    a.reply = sink_a.transport();
    b.reply = sink_b.transport();

    try server.handleMessage(a, io, std.testing.allocator, test_initialize_message);

    try std.testing.expect(sink_a.responseMessage() != null);
    try std.testing.expect(sink_b.responseMessage() == null);
}

test "an idle sweep does not free a session that is currently being served" {
    // Regression: sessions were freed out from under in-flight requests, so a
    // sweep or a `DELETE` on one connection was a use-after-free on another.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);

    const session = server.acquireSession(io, created.plaintext_id).?;
    try std.testing.expectEqual(@as(usize, 1), session.refs);

    session.last_seen_s = 0;
    server.sweepIdleSessions(io);

    // Unpublished so no new request can find it, but not yet freed.
    try std.testing.expect(session.closing);
    try std.testing.expect(server.acquireSession(io, created.plaintext_id) == null);
    try std.testing.expectEqual(@as(usize, 0), server.sessions.count());

    // The last reference performs the teardown; the leak check proves it.
    server.releaseSession(io, session);
}

test "acquireSession pins a session against a concurrent DELETE" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);

    const session = server.acquireSession(io, created.plaintext_id).?;

    // What `handleHttpSessionDelete` does when the session is still referenced.
    server.sessions_mutex.lock(io) catch unreachable;
    session.closing = true;
    _ = server.sessions.remove(session.id.?);
    server.sessions_mutex.unlock(io);

    // Still usable by the connection holding it.
    try std.testing.expectEqual(@as(usize, 1), session.refs);
    server.releaseSession(io, session);
}

test "connection slots are bounded" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();
    server.max_connections = 2;

    try std.testing.expect(server.tryAcquireConnectionSlot(io));
    try std.testing.expect(server.tryAcquireConnectionSlot(io));
    try std.testing.expect(!server.tryAcquireConnectionSlot(io));

    server.releaseConnectionSlot(io);
    try std.testing.expect(server.tryAcquireConnectionSlot(io));
    server.releaseConnectionSlot(io);
    server.releaseConnectionSlot(io);
}

test "accept backoff grows and is capped" {
    // A bare `continue` on accept failure turns a persistently failing listener
    // into a hot spin loop.
    try std.testing.expectEqual(@as(i64, 1), Server.nextAcceptBackoffMs(0));
    try std.testing.expectEqual(@as(i64, 2), Server.nextAcceptBackoffMs(1));
    try std.testing.expectEqual(@as(i64, 1000), Server.nextAcceptBackoffMs(512));
    try std.testing.expectEqual(@as(i64, 1000), Server.nextAcceptBackoffMs(1000));
}

test "shutdown unblocks a parked accept" {
    // Regression: the accept loop only re-checked lifecycle between
    // connections, so a server with no traffic could not be stopped at all.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    // A fixed port, because the wake-up connection has to be able to dial the
    // listener back. `reuse_address` keeps a repeat run from tripping over
    // `TIME_WAIT`.
    const port: u16 = 47821;
    const Runner = struct {
        fn run(s: *Server, run_io: std.Io, allocator: std.mem.Allocator, p: u16) void {
            s.runHttp(run_io, allocator, .{ .port = p, .shutdown_grace_ms = 200 }) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ &server, io, std.testing.allocator, port });

    // Wait for the listener to be published, i.e. accept is parked.
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        server.connections_mutex.lock(io) catch unreachable;
        const listening = server.http_listener != null;
        server.connections_mutex.unlock(io);
        if (listening) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try std.testing.expect(spins < 500);

    server.shutdown(io);
    // Hangs forever without the listener shutdown, since no client ever connects.
    thread.join();
    try std.testing.expectEqual(Lifecycle.shutting_down, server.lifecycle);
}

test "connection timeouts are applied to accepted sockets" {
    if (builtin.os.tag == .windows) return;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.Ip4Address.loopback(0);
    var listener = try std.Io.net.IpAddress.listen(&.{ .ip4 = address }, io, .{});
    defer listener.deinit(io);

    // The kernel accepted the deadline for a real TCP socket.
    try std.testing.expect(Server.setSocketTimeouts(listener.socket.handle, 7));
    // Disabled means disabled: no option is set at all.
    try std.testing.expect(!Server.setSocketTimeouts(listener.socket.handle, 0));
}

test "MCP-Protocol-Version is validated against the supported set" {
    for (protocol.SUPPORTED_VERSIONS) |version| {
        try std.testing.expect(Server.isSupportedProtocolVersion(version));
    }
    try std.testing.expect(!Server.isSupportedProtocolVersion("2199-01-01"));
    try std.testing.expect(!Server.isSupportedProtocolVersion(""));
}

test "a terminated session id is remembered so it can be answered 410" {
    // A destroyed session and a fabricated id used to be indistinguishable;
    // both got 404, so a client could not tell "re-initialize" from "wrong id".
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const created = try server.createSession(io);
    const plaintext = created.plaintext_id;
    defer std.testing.allocator.free(plaintext);
    try server.sessions.put(created.session.id.?, created.session);

    try std.testing.expect(!server.wasTerminated(io, plaintext));
    server.destroySession(created.session);
    try std.testing.expect(server.wasTerminated(io, plaintext));
    try std.testing.expect(!server.wasTerminated(io, "never-existed"));
}

test "terminated session ids are bounded" {
    // The tombstone table must not become an unbounded memory sink for a
    // server that churns sessions.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();
    server.max_sessions = 4;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const created = try server.createSession(io);
        std.testing.allocator.free(created.plaintext_id);
        try server.sessions.put(created.session.id.?, created.session);
        server.destroySession(created.session);
    }

    try std.testing.expectEqual(@as(usize, 4), server.terminated_order.items.len);
    try std.testing.expectEqual(@as(usize, 4), server.terminated_sessions.count());
}

test "retiring a busy session asks its in-flight work to stop" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const created = try server.createSession(io);
    defer std.testing.allocator.free(created.plaintext_id);
    try server.sessions.put(created.session.id.?, created.session);

    const session = server.acquireSession(io, created.plaintext_id).?;
    try std.testing.expect(!session.isCancelled());

    session.last_seen_s = 0;
    server.sweepIdleSessions(io);

    // The handler still holds the session, but is now told its result has
    // nowhere to go.
    try std.testing.expect(session.isCancelled());
    try std.testing.expect(server.wasTerminated(io, created.plaintext_id));

    server.releaseSession(io, session);
}

test "a handler's progress notifications survive alongside its response" {
    // Regression: `HttpRequestTransport` kept only the most recent message and
    // freed the rest, so everything a handler emitted before its result was
    // silently dropped.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var transport: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer transport.deinit();

    try transport.send(io, std.testing.allocator, "progress-1");
    try transport.send(io, std.testing.allocator, "progress-2");
    try transport.send(io, std.testing.allocator, "result");

    try std.testing.expectEqual(@as(usize, 3), transport.messages.items.len);
    try std.testing.expectEqualStrings("progress-1", transport.messages.items[0]);
    try std.testing.expectEqualStrings("result", transport.responseMessage().?);
}

test "SSE frames carry event ids and cannot be forged by an embedded newline" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);

    try Server.appendSseEvent(std.testing.allocator, &body, 7, "{\"a\":1}");
    try std.testing.expectEqualStrings("id: 7\ndata: {\"a\":1}\n\n", body.items);

    // A newline inside a message must not end the frame and start a new one.
    body.clearRetainingCapacity();
    try Server.appendSseEvent(std.testing.allocator, &body, 8, "line1\nline2");
    try std.testing.expectEqualStrings("id: 8\ndata: line1\ndata: line2\n\n", body.items);
}

test "session events are numbered and retained for resumption" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const session = try testRegisterSession(&server, io);

    try std.testing.expectEqual(@as(u64, 1), try session.pushEvent(std.testing.allocator, "one"));
    try std.testing.expectEqual(@as(u64, 2), try session.pushEvent(std.testing.allocator, "two"));

    // What a stream resuming from `Last-Event-ID: 1` would send.
    var resumed: std.ArrayList([]const u8) = .empty;
    defer resumed.deinit(std.testing.allocator);
    for (session.replay.items) |event| {
        if (event.id <= 1) continue;
        try resumed.append(std.testing.allocator, event.data);
    }
    try std.testing.expectEqual(@as(usize, 1), resumed.items.len);
    try std.testing.expectEqualStrings("two", resumed.items[0]);
}

test "the replay buffer is bounded" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const session = try testRegisterSession(&server, io);

    var i: usize = 0;
    while (i < Session.max_replay_events + 10) : (i += 1) {
        _ = try session.pushEvent(std.testing.allocator, "event");
    }

    try std.testing.expectEqual(Session.max_replay_events, session.replay.items.len);
    // Ids keep advancing, so a client can tell it missed some.
    try std.testing.expectEqual(@as(u64, Session.max_replay_events + 10), session.event_seq);
    try std.testing.expectEqual(@as(u64, 11), session.replay.items[0].id);
}

test "server notifications reach every live session's stream" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();

    const a = try testRegisterSession(&server, io);
    const b = try testRegisterSession(&server, io);

    try server.sendNotification(io, std.testing.allocator, "notifications/tools/list_changed", null);

    try std.testing.expectEqual(@as(usize, 1), a.replay.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.replay.items.len);
    try std.testing.expect(std.mem.indexOf(u8, a.replay.items[0].data, "list_changed") != null);

    // A session on its way out is not queued more work.
    b.closing = true;
    try server.sendNotification(io, std.testing.allocator, "notifications/tools/list_changed", null);
    try std.testing.expectEqual(@as(usize, 2), a.replay.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.replay.items.len);
}

fn testNoopTool(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) tools_mod.ToolError!tools_mod.ToolResult {
    return tools_mod.textResult(allocator, "ok") catch tools_mod.ToolError.OutOfMemory;
}

fn testAddNamedTool(server: *Server, name: []const u8) !void {
    try server.addTool(.{ .name = name, .description = "x", .handler = testNoopTool });
}

test "tools/list pages through a bounded page_size" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{
        .name = "t",
        .version = "1",
        .page_size = 2,
    });
    defer server.deinit();
    server.implicit_session.state = .ready;

    for ([_][]const u8{ "e", "a", "d", "b", "c" }) |name| try testAddNamedTool(&server, name);

    // Walk every page and collect the names in the order the server hands
    // them out.
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(std.testing.allocator);

    var cursor: ?[]const u8 = null;
    var cursor_buf: [128]u8 = undefined;
    var round_trips: usize = 0;
    while (round_trips < 10) {
        var body_buf: [256]u8 = undefined;
        const body = if (cursor) |c|
            try std.fmt.bufPrint(&body_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{{\"cursor\":\"{s}\"}}}}", .{c})
        else
            try std.fmt.bufPrint(&body_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}}", .{});

        const response = try testRoundTrip(&server, &server.implicit_session, io, body);
        defer std.testing.allocator.free(response);
        round_trips += 1;

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const result = parsed.value.object.get("result").?.object;
        const tools = result.get("tools").?.array;
        try std.testing.expect(tools.items.len <= 2);
        for (tools.items) |tool| {
            try seen.appendSlice(std.testing.allocator, tool.object.get("name").?.string);
        }

        const next = result.get("nextCursor") orelse break;
        cursor = try std.fmt.bufPrint(&cursor_buf, "{s}", .{next.string});
    }

    // Every tool exactly once, in the sorted order that makes paging stable.
    try std.testing.expectEqualStrings("abcde", seen.items);
    try std.testing.expectEqual(@as(usize, 3), round_trips);
}

test "page_size 0 returns everything with no cursor" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1" });
    defer server.deinit();
    server.implicit_session.state = .ready;

    for ([_][]const u8{ "a", "b", "c" }) |name| try testAddNamedTool(&server, name);

    const response = try testRoundTrip(&server, &server.implicit_session, io, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    defer std.testing.allocator.free(response);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 3), result.get("tools").?.array.items.len);
    try std.testing.expect(result.get("nextCursor") == null);
}

test "a cursor the server never issued is invalid params, not a dropped connection" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "t", .version = "1", .page_size = 1 });
    defer server.deinit();
    server.implicit_session.state = .ready;
    try testAddNamedTool(&server, "a");

    const response = try testRoundTrip(
        &server,
        &server.implicit_session,
        io,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"cursor\":\"not base64!!\"}}",
    );
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Invalid cursor") != null);
}

test "paginateKeys resumes after a key that has since been removed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Cursor points at "b", which is no longer in the set.
    var encoded: [16]u8 = undefined;
    const cursor = encoded[0..cursor_codec.Encoder.calcSize(1)];
    _ = cursor_codec.Encoder.encode(cursor, "b");

    var keys = [_][]const u8{ "c", "a", "d" };
    const page = try paginateKeys(aa, &keys, cursor, 5);
    try std.testing.expectEqual(@as(usize, 2), page.keys.len);
    try std.testing.expectEqualStrings("c", page.keys[0]);
    try std.testing.expectEqualStrings("d", page.keys[1]);
}

test "handleMessageAlloc answers a request without a transport" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();

    const init_reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    defer init_reply.deinit();
    const init_body = init_reply.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, init_body, "\"protocolVersion\":\"2025-11-25\"") != null);

    const ping_reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    defer ping_reply.deinit();
    const ping_body = ping_reply.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, ping_body, "\"id\":2") != null);
}

test "handleMessageAlloc produces nothing for a notification" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();

    const reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer reply.deinit();
    try std.testing.expectEqual(@as(usize, 0), reply.messages.len);
    try std.testing.expect(reply.response() == null);
}

test "handleMessageAlloc leaves an existing reply sink in place" {
    // The http path sets `session.reply` for the duration of a request; a
    // caller reaching in must put back what it found rather than clearing it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();

    var outer: HttpRequestTransport = .{ .owner_allocator = std.testing.allocator };
    defer outer.deinit();
    server.implicit_session.reply = outer.transport();

    const reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer reply.deinit();

    try std.testing.expect(server.implicit_session.reply != null);
    // The response went to the caller, not to the sink that was already there.
    try std.testing.expectEqual(@as(usize, 0), outer.messages.items.len);
}

/// Initialize `server` through its public message API so later requests are
/// accepted, discarding the handshake response.
fn testInitialize(server: *Server, io: std.Io) !void {
    const reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    reply.deinit();
}

test "a repeated request id is rejected while the original is in flight" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();
    try testInitialize(&server, io);

    // Stand in for a request that is still being served.
    const claim = try server.implicit_session.claimRequestId(io, .{ .integer = 1 });
    try std.testing.expectEqual(Session.Claim.claimed, claim);

    const clash = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer clash.deinit();
    const clash_body = clash.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, clash_body, "-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, clash_body, "Duplicate request id") != null);

    // Once the original completes the id is usable again.
    server.implicit_session.releaseRequestId(io, .{ .integer = 1 });
    const ok = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer ok.deinit();
    const ok_body = ok.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, ok_body, "\"result\"") != null);
}

test "a request id is released as soon as its response is sent" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();
    try testInitialize(&server, io);

    for (0..3) |_| {
        const reply = try server.handleMessageAlloc(io, std.testing.allocator,
            \\{"jsonrpc":"2.0","id":7,"method":"ping"}
        );
        defer reply.deinit();
        const body = reply.response() orelse return error.NoResponse;
        try std.testing.expect(std.mem.indexOf(u8, body, "\"result\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), server.implicit_session.inflight.count());
}

test "integer and string request ids with the same digits do not collide" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();
    try testInitialize(&server, io);

    try std.testing.expectEqual(Session.Claim.claimed, try server.implicit_session.claimRequestId(io, .{ .integer = 5 }));
    defer server.implicit_session.releaseRequestId(io, .{ .integer = 5 });

    const reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":"5","method":"ping"}
    );
    defer reply.deinit();
    const body = reply.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"result\"") != null);
}

test "the in-flight table is bounded" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();
    try testInitialize(&server, io);

    for (0..Session.max_inflight_requests) |i| {
        const claimed = try server.implicit_session.claimRequestId(io, .{ .integer = @intCast(1000 + i) });
        try std.testing.expectEqual(Session.Claim.claimed, claimed);
    }
    defer for (0..Session.max_inflight_requests) |i| {
        server.implicit_session.releaseRequestId(io, .{ .integer = @intCast(1000 + i) });
    };

    const reply = try server.handleMessageAlloc(io, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer reply.deinit();
    const body = reply.response() orelse return error.NoResponse;
    try std.testing.expect(std.mem.indexOf(u8, body, "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Too many requests in flight") != null);
}
