//! MCP Client Implementation (Spec 2025-11-25)
//!
//! Provides an MCP client that connects to MCP servers via STDIO or HTTP transport.
//! The client handles protocol negotiation, capability advertisement, and provides
//! methods for listing and invoking tools, reading resources, and fetching prompts.
//! Supports task-augmented requests, sampling, elicitation, and roots.

const builtin = @import("builtin");
const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
const report = @import("../report.zig");
const transport_mod = @import("../transport/transport.zig");

/// Configuration options for creating an MCP client.
pub const ClientConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
    /// Opt in to a background check against GitHub Releases for a newer
    /// mcp.zig. Off by default: constructing a client must not contact a
    /// third-party host the caller never asked to reach.
    check_for_updates: bool = false,
    /// What to do with a spawned server's stderr.
    ///
    /// Defaults to discarding it. MCP servers commonly log there, and
    /// inheriting mixes that into the host application's own stderr -- which
    /// corrupts anything structured the host writes. `.pipe` is deliberately
    /// not the default: nothing drains it, so a chatty server would fill the
    /// pipe buffer and block forever.
    server_stderr: std.process.SpawnOptions.StdIo = .ignore,
};

/// A single environment variable passed to a spawned server.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Controls how `connectStdioOptions` spawns the server process.
pub const StdioOptions = struct {
    args: []const []const u8 = &.{},
    /// Variables layered on top of `base_environ`. A name already present
    /// there is overwritten.
    env: []const EnvVar = &.{},
    /// The environment the child starts from.
    ///
    /// Pass `init.environ_map` from `std.process.Init` to build on this
    /// process's environment. std does not expose the environment as a global
    /// in 0.16 -- it is handed to `main` -- so a caller that wants to *add* to
    /// the inherited environment has to supply it here.
    ///
    /// Null plus `inherit_environ = true` (the defaults) leaves the
    /// inheritance to the OS, which is what plain `connectStdio` does.
    base_environ: ?*const std.process.Environ.Map = null,
    /// When false the child receives only `base_environ` + `env`.
    ///
    /// Set this to false to withhold the parent's environment: a server you
    /// did not write should not automatically receive every secret the host
    /// happens to hold.
    inherit_environ: bool = true,
    /// Working directory for the child. Defaults to inheriting the parent's.
    /// Accepts either a path or an open directory handle.
    cwd: std.process.Child.Cwd = .inherit,
};

/// Builds the environment block for a spawned server, or null to let the OS
/// inherit the parent's.
fn buildEnvironMap(
    allocator: std.mem.Allocator,
    options: StdioOptions,
) !?std.process.Environ.Map {
    if (options.inherit_environ and options.env.len == 0 and options.base_environ == null) {
        return null;
    }

    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();

    if (options.base_environ) |base| {
        for (base.keys(), base.values()) |name, value| {
            try map.put(name, value);
        }
    }

    for (options.env) |v| {
        if (!std.process.Environ.Map.validateKeyForPut(v.name)) {
            return error.InvalidEnvironmentVariableName;
        }
        try map.put(v.name, v.value);
    }
    return map;
}

/// A successful JSON-RPC response.
///
/// `result` is a view into `parsed`, so it is only valid until `deinit`.
pub const Response = struct {
    parsed: std.json.Parsed(std.json.Value),
    result: std.json.Value,

    pub fn deinit(self: Response) void {
        self.parsed.deinit();
    }

    /// Looks up a field of the result object, or null if the result is not an
    /// object or has no such field.
    pub fn get(self: Response, name: []const u8) ?std.json.Value {
        return switch (self.result) {
            .object => |o| o.get(name),
            else => null,
        };
    }
};

/// Answers a server-initiated request. The returned value becomes the JSON-RPC
/// `result`; it is built with the allocator passed in and is not retained
/// after the reply is serialized.
pub const RequestHandler = *const fn (
    ctx: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) anyerror!std.json.Value;

/// Observes a server-initiated notification.
pub const NotificationHandler = *const fn (
    ctx: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) anyerror!void;

fn RegistryEntry(comptime Handler: type) type {
    return struct {
        ctx: ?*anyopaque,
        handler: Handler,
    };
}

/// Selects one page of a `*/list` response.
pub const ListOptions = struct {
    /// Cursor from a previous page's `nextCursor`. Null requests the first
    /// page. Cursors are opaque; do not construct one.
    cursor: ?[]const u8 = null,
};

/// The concatenated items of every page of a `*/list` method.
///
/// `items` are views into `responses`, which are retained so the values stay
/// valid until `deinit`.
pub const PagedItems = struct {
    allocator: std.mem.Allocator,
    responses: []Response,
    items: []std.json.Value,

    pub fn deinit(self: PagedItems) void {
        for (self.responses) |r| r.deinit();
        self.allocator.free(self.responses);
        self.allocator.free(self.items);
    }
};

/// A JSON-RPC error returned by the server.
pub const ServerError = struct {
    code: i64,
    message: []const u8,
};

/// How many consecutive empty reads to tolerate while waiting for a response
/// before giving up with `error.NoResponse`.
const max_empty_reads = 128;

/// Upper bound on pages walked by the `listAll*` helpers. A server that never
/// stops emitting `nextCursor` must not hang the caller.
const max_list_pages = 1024;

/// Upper bound on replies held for a request other than the one being awaited.
/// Without a bound a server that answers ids nobody asked for grows this
/// forever.
const max_parked_responses = 64;

/// Connection state of the client.
pub const ClientState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// MCP Client for connecting to and interacting with MCP servers.
///
/// Supports STDIO and HTTP transports, capability negotiation, and provides
/// methods for all standard MCP operations including tool calls, resource
/// reads, prompt fetches, and task management.
pub const Client = struct {
    config: ClientConfig,
    state: ClientState = .disconnected,
    transport: ?transport_mod.Transport = null,
    server_info: ?types.Implementation = null,
    server_capabilities: ?types.ServerCapabilities = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    capabilities: types.ClientCapabilities = .{},
    authorization_token: ?[]const u8 = null,
    /// Server process spawned by `connectStdio`, owned by this client.
    child: ?std.process.Child = null,
    /// The `initialize` response, retained so `serverCapabilities` and
    /// `serverInfo` stay valid for the life of the connection.
    handshake: ?Response = null,
    /// Protocol version agreed during the handshake.
    negotiated_version: ?[]const u8 = null,
    /// Details of the most recent `error.ServerError`.
    last_error: ?ServerError = null,
    roots_list: std.ArrayList(types.Root),
    update_thread: ?std.Thread = null,
    /// Handlers for server-initiated requests, keyed by method. Keys are owned.
    request_handlers: std.StringHashMap(RegistryEntry(RequestHandler)),
    /// Handlers for server-initiated notifications, keyed by method.
    notification_handlers: std.StringHashMap(RegistryEntry(NotificationHandler)),
    /// Responses that arrived while a different request was being awaited.
    /// Raw JSON, owned; drained by a later `awaitResponse`.
    parked_responses: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    /// Represents a request awaiting a response from the server.
    pub const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: ?std.json.Value, err: ?jsonrpc.ErrorResponse.Error) void = null,
    };

    /// Initializes a new client with the given configuration.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Self {
        return .{
            .config = config,
            .pending_requests = .init(allocator),
            .roots_list = .empty,
            .request_handlers = .init(allocator),
            .notification_handlers = .init(allocator),
            .update_thread = if (config.check_for_updates) report.checkForUpdates(io, allocator) else null,
        };
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
        self.pending_requests.deinit();
        self.roots_list.deinit(allocator);
        var request_keys = self.request_handlers.keyIterator();
        while (request_keys.next()) |k| allocator.free(k.*);
        self.request_handlers.deinit();
        var notification_keys = self.notification_handlers.keyIterator();
        while (notification_keys.next()) |k| allocator.free(k.*);
        self.notification_handlers.deinit();
        for (self.parked_responses.items) |raw| allocator.free(raw);
        self.parked_responses.deinit(allocator);
        if (self.authorization_token) |token| {
            allocator.free(token);
        }
        // `connectStdio`/`connectHttp` allocate the transport, so the client
        // owns it. Without this the endpoint, the session id and every queued
        // response leak.
        if (self.handshake) |h| {
            h.deinit();
            self.handshake = null;
        }
        self.clearServerError(allocator);
        if (self.transport) |t| {
            t.deinit(allocator);
            self.transport = null;
        }
        // The spawned server would otherwise linger as an orphan holding the
        // pipes open.
        if (self.child) |*c| {
            c.kill(io);
            self.child = null;
        }
        // Join rather than detach. The worker borrows this allocator, so
        // detaching lets it run on past the caller's `gpa.deinit()` and touch
        // freed memory.
        if (self.update_thread) |t| {
            t.join();
            self.update_thread = null;
        }
    }

    /// Enables the sampling capability, allowing the server to request LLM completions.
    pub fn enableSampling(self: *Self) void {
        self.capabilities.sampling = .{};
    }

    /// Enables the sampling capability with context and/or tools support.
    pub fn enableSamplingAdvanced(self: *Self, context: bool, tools_support: bool) void {
        self.capabilities.sampling = .{
            .context = if (context) .{} else null,
            .tools = if (tools_support) .{} else null,
        };
    }

    /// Enables the roots capability for providing filesystem boundaries to the server.
    pub fn enableRoots(self: *Self, listChanged: bool) void {
        self.capabilities.roots = .{ .listChanged = listChanged };
    }

    /// Enables the elicitation capability for handling server-initiated user input requests.
    pub fn enableElicitation(self: *Self) void {
        self.capabilities.elicitation = .{ .form = .{}, .url = .{} };
    }

    /// Enables form-only elicitation.
    pub fn enableElicitationForm(self: *Self) void {
        self.capabilities.elicitation = .{ .form = .{} };
    }

    /// Enables URL-only elicitation.
    pub fn enableElicitationUrl(self: *Self) void {
        self.capabilities.elicitation = .{ .url = .{} };
    }

    /// Enables the tasks capability for managing long-running operations.
    pub fn enableTasks(self: *Self) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
        };
    }

    /// Enables task-augmented requests for sampling and elicitation.
    pub fn enableTasksAdvanced(self: *Self, sampling: bool, elicitation: bool) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{
                .sampling = if (sampling) .{ .createMessage = .{} } else null,
                .elicitation = if (elicitation) .{ .create = .{} } else null,
            },
        };
    }

    /// Adds a filesystem root that the server can access.
    pub fn addRoot(self: *Self, allocator: std.mem.Allocator, uri: []const u8, name: ?[]const u8) !void {
        try self.roots_list.append(allocator, .{ .uri = uri, .name = name });
    }

    /// Connects to a server by spawning a process and communicating via STDIO.
    ///
    /// The child inherits this process's environment and working directory.
    /// Use `connectStdioOptions` to control either.
    pub fn connectStdio(self: *Self, io: std.Io, allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !void {
        return self.connectStdioOptions(io, allocator, command, .{ .args = args });
    }

    /// Connects to a server by spawning a process, with control over the
    /// child's environment and working directory.
    pub fn connectStdioOptions(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        command: []const u8,
        options: StdioOptions,
    ) !void {
        self.state = .connecting;
        errdefer self.state = .error_state;

        const argv = try allocator.alloc([]const u8, options.args.len + 1);
        defer allocator.free(argv);
        argv[0] = command;
        @memcpy(argv[1..], options.args);

        var environ_map = try buildEnvironMap(allocator, options);
        // The block is copied into the child at spawn time, so the map is only
        // needed for the duration of the call.
        defer if (environ_map) |*m| m.deinit();

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = self.config.server_stderr,
            .environ_map = if (environ_map) |*m| m else null,
            .cwd = options.cwd,
        });
        errdefer child.kill(io);

        const stdio = try allocator.create(transport_mod.StdioTransport);
        errdefer allocator.destroy(stdio);
        // Read the server's stdout and write to its stdin. Leaving these at
        // their defaults would point the client at its own streams.
        stdio.* = .{ .in = child.stdout.?, .out = child.stdin.? };

        self.child = child;
        errdefer self.child = null;
        self.transport = stdio.transport();
        errdefer self.transport = null;

        try self.initialize(io, allocator);
    }

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, allocator: std.mem.Allocator, token: []const u8) !void {
        if (self.authorization_token) |old| {
            allocator.free(old);
        }
        self.authorization_token = try allocator.dupe(u8, token);
    }

    /// Connects to a server via HTTP at the specified URL.
    pub fn connectHttp(self: *Self, io: std.Io, allocator: std.mem.Allocator, url: []const u8) !void {
        return self.connectHttpOptions(io, allocator, url, .{});
    }

    /// Options for `connectHttpOptions`.
    pub const HttpOptions = struct {
        /// Headers sent with every request, for auth schemes and routing
        /// headers the transport does not model itself. See
        /// `HttpTransport.setExtraHeaders` for the validation rules.
        extra_headers: []const std.http.Header = &.{},
    };

    /// Connects to a server via HTTP, with caller-supplied request headers.
    pub fn connectHttpOptions(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        url: []const u8,
        options: HttpOptions,
    ) !void {
        self.state = .connecting;
        errdefer self.state = .error_state;

        const http = try allocator.create(transport_mod.HttpTransport);
        errdefer allocator.destroy(http);
        http.* = try transport_mod.HttpTransport.init(allocator, url);
        errdefer http.deinit(allocator);
        if (options.extra_headers.len > 0) {
            try http.setExtraHeaders(allocator, options.extra_headers);
        }
        if (self.authorization_token) |token| {
            try http.setAuthorizationToken(allocator, token);
        }
        self.transport = http.transport();
        // The transport is now reachable from `self`, but the `errdefer`s above
        // still own it. Unpublish it on failure so it is freed by one owner or
        // the other and never by both.
        errdefer self.transport = null;

        try self.initialize(io, allocator);
    }

    /// Sends the initialize request to begin the MCP handshake.
    fn initialize(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.validateCapabilityHandlers();

        // The params are a throwaway tree. `ObjectMap.deinit` is not
        // recursive, so freeing only the root leaked every nested map.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var params: std.json.ObjectMap = .empty;

        try params.put(aa, "protocolVersion", .{ .string = protocol.VERSION });

        var caps: std.json.ObjectMap = .empty;
        if (self.capabilities.sampling != null) {
            var sampling_cap: std.json.ObjectMap = .empty;
            if (self.capabilities.sampling.?.context != null) {
                try sampling_cap.put(aa, "context", .{ .object = .empty });
            }
            if (self.capabilities.sampling.?.tools != null) {
                try sampling_cap.put(aa, "tools", .{ .object = .empty });
            }
            try caps.put(aa, "sampling", .{ .object = sampling_cap });
        }
        if (self.capabilities.roots) |r| {
            var roots_cap: std.json.ObjectMap = .empty;
            try roots_cap.put(aa, "listChanged", .{ .bool = r.listChanged });
            try caps.put(aa, "roots", .{ .object = roots_cap });
        }
        if (self.capabilities.elicitation) |e| {
            var elicit_cap: std.json.ObjectMap = .empty;
            if (e.form != null) {
                try elicit_cap.put(aa, "form", .{ .object = .empty });
            }
            if (e.url != null) {
                try elicit_cap.put(aa, "url", .{ .object = .empty });
            }
            try caps.put(aa, "elicitation", .{ .object = elicit_cap });
        }
        if (self.capabilities.tasks != null) {
            var tasks_cap: std.json.ObjectMap = .empty;
            try tasks_cap.put(aa, "list", .{ .object = .empty });
            try tasks_cap.put(aa, "cancel", .{ .object = .empty });
            if (self.capabilities.tasks.?.requests) |reqs| {
                var requests_obj: std.json.ObjectMap = .empty;
                if (reqs.sampling != null) {
                    var sampling_obj: std.json.ObjectMap = .empty;
                    try sampling_obj.put(aa, "createMessage", .{ .object = .empty });
                    try requests_obj.put(aa, "sampling", .{ .object = sampling_obj });
                }
                if (reqs.elicitation != null) {
                    var elicitation_obj: std.json.ObjectMap = .empty;
                    try elicitation_obj.put(aa, "create", .{ .object = .empty });
                    try requests_obj.put(aa, "elicitation", .{ .object = elicitation_obj });
                }
                try tasks_cap.put(aa, "requests", .{ .object = requests_obj });
            }
            try caps.put(aa, "tasks", .{ .object = tasks_cap });
        }
        try params.put(aa, "capabilities", .{ .object = caps });

        var client_info: std.json.ObjectMap = .empty;
        try client_info.put(aa, "name", .{ .string = self.config.name });
        try client_info.put(aa, "version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try client_info.put(aa, "title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try client_info.put(aa, "description", .{ .string = d });
        }
        if (self.config.icons) |icons| {
            var icons_array: std.json.Array = .init(allocator);
            for (icons) |icon| {
                var icon_obj: std.json.ObjectMap = .empty;
                try icon_obj.put(aa, "src", .{ .string = icon.src });
                if (icon.mimeType) |mime| {
                    try icon_obj.put(aa, "mimeType", .{ .string = mime });
                }
                if (icon.sizes) |sizes| {
                    var sizes_array: std.json.Array = .init(allocator);
                    for (sizes) |size| {
                        try sizes_array.append(.{ .string = size });
                    }
                    try icon_obj.put(aa, "sizes", .{ .array = sizes_array });
                }
                if (icon.theme) |theme| {
                    try icon_obj.put(aa, "theme", .{ .string = @tagName(theme) });
                }
                try icons_array.append(.{ .object = icon_obj });
            }
            try client_info.put(aa, "icons", .{ .array = icons_array });
        }
        if (self.config.websiteUrl) |u| {
            try client_info.put(aa, "websiteUrl", .{ .string = u });
        }
        try params.put(aa, "clientInfo", .{ .object = client_info });

        var response = try self.request(io, allocator, "initialize", .{ .object = params });
        errdefer response.deinit();

        // Validate the handshake rather than discarding it: the version the
        // server picked decides what the rest of the session may use.
        const version = switch (response.get("protocolVersion") orelse
            return error.MissingProtocolVersion) {
            .string => |v| v,
            else => return error.InvalidResponse,
        };
        if (!isSupportedVersion(version)) return error.UnsupportedProtocolVersion;

        self.negotiated_version = version;
        self.handshake = response;
        self.state = .connected;

        // The spec requires this before any other request.
        try self.notifyInitialized(io, allocator);
    }

    fn isSupportedVersion(version: []const u8) bool {
        for (protocol.SUPPORTED_VERSIONS) |supported| {
            if (std.mem.eql(u8, supported, version)) return true;
        }
        return false;
    }

    /// Sends a JSON-RPC request and waits for the matching response.
    ///
    /// The caller owns the returned `Response` and must `deinit` it.
    pub fn request(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !Response {
        const t = self.transport orelse return error.NotConnected;

        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{ .method = method });
        errdefer _ = self.pending_requests.remove(id);

        const req = jsonrpc.createRequest(.{ .integer = id }, method, params);
        const json = try jsonrpc.serializeMessage(allocator, .{ .request = req });
        defer allocator.free(json);

        try t.send(io, allocator, json);

        const response = try self.awaitResponse(io, allocator, id);
        _ = self.pending_requests.remove(id);
        return response;
    }

    /// Registers a handler for a server-initiated request.
    ///
    /// Replacing an existing handler for the same method is allowed. Without a
    /// handler the client answers `-32601 Method not found`, which is at least
    /// a correct answer; before this registry existed the request was dropped
    /// and the server waited forever.
    pub fn onRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        method: []const u8,
        ctx: ?*anyopaque,
        handler: RequestHandler,
    ) !void {
        try registerHandler(RequestHandler, &self.request_handlers, allocator, method, ctx, handler);
    }

    /// Registers a handler for a server-initiated notification.
    pub fn onNotification(
        self: *Self,
        allocator: std.mem.Allocator,
        method: []const u8,
        ctx: ?*anyopaque,
        handler: NotificationHandler,
    ) !void {
        try registerHandler(NotificationHandler, &self.notification_handlers, allocator, method, ctx, handler);
    }

    fn registerHandler(
        comptime Handler: type,
        map: *std.StringHashMap(RegistryEntry(Handler)),
        allocator: std.mem.Allocator,
        method: []const u8,
        ctx: ?*anyopaque,
        handler: Handler,
    ) !void {
        // The caller's `method` may be a temporary, and the map outlives it.
        const gop = try map.getOrPut(method);
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, method) catch |err| {
                _ = map.remove(method);
                return err;
            };
        }
        gop.value_ptr.* = .{ .ctx = ctx, .handler = handler };
    }

    /// Whether a handler is registered for `method`.
    pub fn hasRequestHandler(self: *const Self, method: []const u8) bool {
        return self.request_handlers.contains(method);
    }

    /// Reads from the transport until the response with `id` arrives.
    ///
    /// Anything else that arrives on the way is handled rather than dropped:
    /// server-initiated requests are dispatched to `request_handlers` and
    /// answered, notifications are dispatched to `notification_handlers`, and
    /// a reply belonging to a different outstanding request is parked for
    /// whoever is waiting on it.
    fn awaitResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, id: i64) !Response {
        if (try self.takeParkedResponse(allocator, id)) |response| return response;

        const t = self.transport orelse return error.NotConnected;

        var empty_reads: usize = 0;
        while (true) {
            const raw = t.receive(io, allocator) catch |err| switch (err) {
                error.EndOfStream, error.ConnectionClosed => return error.ConnectionClosed,
                else => |e| return e,
            } orelse {
                // A transport with nothing queued would otherwise spin here
                // forever waiting for a reply that is never coming.
                empty_reads += 1;
                if (empty_reads > max_empty_reads) return error.NoResponse;
                continue;
            };
            var free_raw = true;
            defer if (free_raw) allocator.free(raw);
            empty_reads = 0;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return error.InvalidResponse;
            var keep = false;
            defer if (!keep) parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return error.InvalidResponse,
            };

            const id_value = obj.get("id");

            if (obj.get("method")) |method_value| {
                const method = switch (method_value) {
                    .string => |m| m,
                    else => continue,
                };
                const params = obj.get("params");
                if (id_value) |request_id| {
                    try self.dispatchServerRequest(io, allocator, method, request_id, params);
                } else {
                    try self.dispatchNotification(io, allocator, method, params);
                }
                continue;
            }

            const response_id = switch (id_value orelse continue) {
                .integer => |i| i,
                else => continue,
            };

            if (response_id != id) {
                // Another request's reply. Keep it: discarding it is what made
                // more than one outstanding request impossible.
                if (self.parked_responses.items.len < max_parked_responses) {
                    try self.parked_responses.append(allocator, raw);
                    free_raw = false;
                }
                continue;
            }

            if (obj.get("error")) |err_value| {
                try self.recordServerError(allocator, err_value);
                return error.ServerError;
            }

            const result = obj.get("result") orelse return error.InvalidResponse;
            keep = true;
            return .{ .parsed = parsed, .result = result };
        }
    }

    /// Returns a previously parked reply for `id`, if one arrived while
    /// another request was being awaited.
    fn takeParkedResponse(self: *Self, allocator: std.mem.Allocator, id: i64) !?Response {
        for (self.parked_responses.items, 0..) |raw, i| {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch continue;
            var keep = false;
            defer if (!keep) parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const response_id = switch (obj.get("id") orelse .null) {
                .integer => |v| v,
                else => continue,
            };
            if (response_id != id) continue;

            allocator.free(self.parked_responses.orderedRemove(i));

            if (obj.get("error")) |err_value| {
                try self.recordServerError(allocator, err_value);
                return error.ServerError;
            }
            const result = obj.get("result") orelse return error.InvalidResponse;
            keep = true;
            return .{ .parsed = parsed, .result = result };
        }
        return null;
    }

    /// Runs the registered handler for a server-initiated request and replies.
    fn dispatchServerRequest(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        request_id: std.json.Value,
        params: ?std.json.Value,
    ) !void {
        const id: types.RequestId = switch (request_id) {
            .integer => |i| .{ .integer = i },
            .string => |str| .{ .string = str },
            else => return,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const entry = self.request_handlers.get(method) orelse blk: {
            // `roots/list` is answerable from state the client already holds,
            // so advertising the capability is enough to service it.
            if (self.capabilities.roots != null and std.mem.eql(u8, method, "roots/list")) {
                const result = self.buildRootsResult(arena.allocator()) catch {
                    const response = jsonrpc.createErrorResponse(
                        id,
                        jsonrpc.ErrorCode.INTERNAL_ERROR,
                        "Handler failed",
                        null,
                    );
                    return self.sendMessage(io, allocator, .{ .error_response = response });
                };
                const response = jsonrpc.createResponse(id, result);
                return self.sendMessage(io, allocator, .{ .response = response });
            }
            break :blk null;
        } orelse {
            const response = jsonrpc.createErrorResponse(
                id,
                jsonrpc.ErrorCode.METHOD_NOT_FOUND,
                "Method not found",
                null,
            );
            return self.sendMessage(io, allocator, .{ .error_response = response });
        };

        const result = entry.handler(entry.ctx, io, arena.allocator(), params) catch {
            // A failing handler is the client's problem, not a reason to leave
            // the server blocked.
            const response = jsonrpc.createErrorResponse(
                id,
                jsonrpc.ErrorCode.INTERNAL_ERROR,
                "Handler failed",
                null,
            );
            return self.sendMessage(io, allocator, .{ .error_response = response });
        };

        const response = jsonrpc.createResponse(id, result);
        try self.sendMessage(io, allocator, .{ .response = response });
    }

    /// Serializes `roots_list` into a `roots/list` result.
    fn buildRootsResult(self: *Self, allocator: std.mem.Allocator) !std.json.Value {
        var roots: std.json.Array = .init(allocator);
        for (self.roots_list.items) |root| {
            var entry: std.json.ObjectMap = .empty;
            try entry.put(allocator, "uri", .{ .string = root.uri });
            if (root.name) |name| try entry.put(allocator, "name", .{ .string = name });
            try roots.append(.{ .object = entry });
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "roots", .{ .array = roots });
        return .{ .object = result };
    }

    /// Refuses to advertise a capability the client cannot service.
    ///
    /// `sampling` and `elicitation` are pure callbacks: without a handler the
    /// server is told the client supports them and then gets `-32601` for
    /// every request. Failing the handshake is the honest answer. `roots` is
    /// exempt because it has a built-in handler.
    fn validateCapabilityHandlers(self: *const Self) !void {
        if (self.capabilities.sampling != null and
            !self.request_handlers.contains("sampling/createMessage"))
        {
            return error.MissingSamplingHandler;
        }
        if (self.capabilities.elicitation != null and
            !self.request_handlers.contains("elicitation/create"))
        {
            return error.MissingElicitationHandler;
        }
    }

    fn dispatchNotification(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        const entry = self.notification_handlers.get(method) orelse return;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // A notification has no reply, so a failing handler can only be
        // swallowed. Silence beats tearing down the connection.
        entry.handler(entry.ctx, io, arena.allocator(), params) catch {};
    }

    fn sendMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        const t = self.transport orelse return error.NotConnected;
        const json = try jsonrpc.serializeMessage(allocator, message);
        defer allocator.free(json);
        try t.send(io, allocator, json);
    }

    /// Stores the code and message from a JSON-RPC error response so the
    /// caller can inspect them after `error.ServerError`.
    fn recordServerError(self: *Self, allocator: std.mem.Allocator, err_value: std.json.Value) !void {
        self.clearServerError(allocator);
        const obj = switch (err_value) {
            .object => |o| o,
            else => return,
        };
        const code: i64 = switch (obj.get("code") orelse .null) {
            .integer => |i| i,
            else => 0,
        };
        const message = switch (obj.get("message") orelse .null) {
            .string => |m| try allocator.dupe(u8, m),
            else => try allocator.dupe(u8, ""),
        };
        self.last_error = .{ .code = code, .message = message };
    }

    fn clearServerError(self: *Self, allocator: std.mem.Allocator) void {
        if (self.last_error) |e| {
            allocator.free(e.message);
            self.last_error = null;
        }
    }

    /// Sends a JSON-RPC notification to the connected server.
    fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const t = self.transport orelse return error.NotConnected;
        const notification = jsonrpc.createNotification(method, params);
        const json = try jsonrpc.serializeMessage(allocator, .{ .notification = notification });
        defer allocator.free(json);
        try t.send(io, allocator, json);
    }

    /// Issues a `*/list` request carrying the caller's cursor, if any.
    fn requestPage(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        options: ListOptions,
    ) !Response {
        const cursor = options.cursor orelse return self.request(io, allocator, method, null);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "cursor", .{ .string = cursor });
        return self.request(io, allocator, method, .{ .object = params });
    }

    /// Walks every page of a `*/list` method and returns the concatenated
    /// items under `items_key`.
    fn requestAllPages(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        items_key: []const u8,
    ) !PagedItems {
        var responses: std.ArrayList(Response) = .empty;
        errdefer {
            for (responses.items) |r| r.deinit();
            responses.deinit(allocator);
        }
        var items: std.ArrayList(std.json.Value) = .empty;
        errdefer items.deinit(allocator);

        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (true) {
            const response = try self.requestPage(io, allocator, method, .{ .cursor = cursor });
            try responses.append(allocator, response);
            pages += 1;

            if (response.get(items_key)) |value| switch (value) {
                .array => |a| try items.appendSlice(allocator, a.items),
                else => return error.InvalidResponse,
            };

            const next = switch (response.get("nextCursor") orelse .null) {
                .string => |c| c,
                else => break,
            };
            // A server that keeps handing back the same cursor, or that never
            // stops, would otherwise spin here forever. Neither is something a
            // caller can be expected to defend against.
            if (cursor) |previous| {
                if (std.mem.eql(u8, previous, next)) return error.CursorNotAdvancing;
            }
            if (pages >= max_list_pages) return error.TooManyPages;
            cursor = next;
        }

        return .{
            .allocator = allocator,
            .responses = try responses.toOwnedSlice(allocator),
            .items = try items.toOwnedSlice(allocator),
        };
    }

    /// Requests every page of tools.
    pub fn listAllTools(self: *Self, io: std.Io, allocator: std.mem.Allocator) !PagedItems {
        return self.requestAllPages(io, allocator, "tools/list", "tools");
    }

    /// Requests every page of resources.
    pub fn listAllResources(self: *Self, io: std.Io, allocator: std.mem.Allocator) !PagedItems {
        return self.requestAllPages(io, allocator, "resources/list", "resources");
    }

    /// Requests every page of resource templates.
    pub fn listAllResourceTemplates(self: *Self, io: std.Io, allocator: std.mem.Allocator) !PagedItems {
        return self.requestAllPages(io, allocator, "resources/templates/list", "resourceTemplates");
    }

    /// Requests every page of prompts.
    pub fn listAllPrompts(self: *Self, io: std.Io, allocator: std.mem.Allocator) !PagedItems {
        return self.requestAllPages(io, allocator, "prompts/list", "prompts");
    }

    /// Requests the list of available tools from the server.
    pub fn listTools(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: ListOptions) !Response {
        return self.requestPage(io, allocator, "tools/list", options);
    }

    /// Invokes a tool on the server with optional arguments.
    pub fn callTool(self: *Self, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(aa, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(aa, "arguments", args);
        }
        return self.request(io, allocator, "tools/call", .{ .object = params });
    }

    /// Requests the list of available resources from the server.
    pub fn listResources(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: ListOptions) !Response {
        return self.requestPage(io, allocator, "resources/list", options);
    }

    /// Reads a resource from the server by URI.
    pub fn readResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !Response {
        return self.requestWithUri(io, allocator, "resources/read", uri);
    }

    /// Subscribes to change notifications for a resource.
    pub fn subscribeResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !Response {
        return self.requestWithUri(io, allocator, "resources/subscribe", uri);
    }

    /// Unsubscribes from change notifications for a resource.
    pub fn unsubscribeResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !Response {
        return self.requestWithUri(io, allocator, "resources/unsubscribe", uri);
    }

    fn requestWithUri(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, uri: []const u8) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "uri", .{ .string = uri });
        return self.request(io, allocator, method, .{ .object = params });
    }

    /// Requests the list of resource templates from the server.
    pub fn listResourceTemplates(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: ListOptions) !Response {
        return self.requestPage(io, allocator, "resources/templates/list", options);
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: ListOptions) !Response {
        return self.requestPage(io, allocator, "prompts/list", options);
    }

    /// Fetches a prompt by name with optional arguments.
    pub fn getPrompt(self: *Self, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(aa, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(aa, "arguments", args);
        }
        return self.request(io, allocator, "prompts/get", .{ .object = params });
    }

    /// Requests a completion suggestion for a prompt or resource argument.
    pub fn complete(self: *Self, io: std.Io, allocator: std.mem.Allocator, ref: std.json.Value, argument: std.json.Value) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(aa, "ref", ref);
        try params.put(aa, "argument", argument);
        return self.request(io, allocator, "completion/complete", .{ .object = params });
    }

    /// Sets the minimum logging level the server should emit.
    pub fn setLogLevel(self: *Self, io: std.Io, allocator: std.mem.Allocator, level: []const u8) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "level", .{ .string = level });
        return self.request(io, allocator, "logging/setLevel", .{ .object = params });
    }

    /// Sends a ping to check the connection is alive.
    pub fn ping(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "ping", null);
    }

    /// Fetches the status of a task.
    pub fn getTask(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !Response {
        return self.requestWithTaskId(io, allocator, "tasks/get", taskId);
    }

    /// Fetches the result of a completed task.
    pub fn getTaskResult(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !Response {
        return self.requestWithTaskId(io, allocator, "tasks/result", taskId);
    }

    /// Requests the list of tasks from the server.
    pub fn listTasks(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "tasks/list", null);
    }

    /// Cancels a running task.
    pub fn cancelTask(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !Response {
        return self.requestWithTaskId(io, allocator, "tasks/cancel", taskId);
    }

    fn requestWithTaskId(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, taskId: []const u8) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "taskId", .{ .string = taskId });
        return self.request(io, allocator, method, .{ .object = params });
    }

    /// Sends the notifications/initialized notification.
    pub fn notifyInitialized(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/initialized", null);
    }

    /// Sends the notifications/roots/list_changed notification.
    pub fn notifyRootsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/roots/list_changed", null);
    }

    /// Disconnects from the server and releases the transport.
    pub fn disconnect(self: *Self, io: std.Io) void {
        if (self.transport) |t| {
            t.close();
        }
        if (self.child) |*c| {
            c.kill(io);
            self.child = null;
        }
        self.state = .disconnected;
    }

    /// Capabilities the server reported during the handshake.
    pub fn serverCapabilities(self: *const Self) ?std.json.Value {
        const h = self.handshake orelse return null;
        return h.get("capabilities");
    }

    /// Name/version the server reported during the handshake.
    pub fn serverInfo(self: *const Self) ?std.json.Value {
        const h = self.handshake orelse return null;
        return h.get("serverInfo");
    }
};

test "Client initialization" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test-client",
        .version = "1.0.0",
    });
    defer client.deinit(std.Io.failing, std.testing.allocator);

    try std.testing.expectEqual(ClientState.disconnected, client.state);
}

test "Client capabilities" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.Io.failing, std.testing.allocator);

    client.enableSampling();
    client.enableRoots(true);
    client.enableElicitation();
    client.enableTasks();

    try std.testing.expect(client.capabilities.sampling != null);
    try std.testing.expect(client.capabilities.roots.?.listChanged);
    try std.testing.expect(client.capabilities.elicitation != null);
    try std.testing.expect(client.capabilities.tasks != null);
}

test "Client advanced sampling" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.Io.failing, std.testing.allocator);

    client.enableSamplingAdvanced(true, true);
    try std.testing.expect(client.capabilities.sampling.?.context != null);
    try std.testing.expect(client.capabilities.sampling.?.tools != null);
}

test "Client add root" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.Io.failing, std.testing.allocator);

    try client.addRoot(std.testing.allocator, "file:///tmp", "Temp");
    try std.testing.expectEqual(@as(usize, 1), client.roots_list.items.len);
}

test "constructing a client does not contact the network by default" {
    // The update check performs an HTTPS fetch on a thread that borrows this
    // allocator. It must be opt-in, so a default-configured client must not
    // start it.
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg: ClientConfig = .{ .name = "c", .version = "1.0.0" };
    try std.testing.expect(!cfg.check_for_updates);

    // Assert on the call, not on the returned thread: `checkForUpdates` has a
    // process-wide one-shot latch, so an earlier test could mask an implicit
    // call here.
    const before = report.invocation_count.load(.monotonic);
    var client: Client = .init(io, allocator, cfg);
    defer client.deinit(io, allocator);
    try std.testing.expectEqual(before, report.invocation_count.load(.monotonic));
    try std.testing.expect(client.update_thread == null);
}

test "connectStdio spawns a server and runs a real request/response session" {
    // The whole point of #24/#25: this drives an actual MCP server over stdio
    // and reads results back. Before, `connectStdio` spawned nothing and every
    // request method returned `void`.
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    try client.connectStdio(io, allocator, build_options.example_server_path, &.{});

    try std.testing.expectEqual(ClientState.connected, client.state);
    try std.testing.expect(client.child != null);
    try std.testing.expectEqualStrings(protocol.VERSION, client.negotiated_version.?);
    try std.testing.expectEqualStrings("simple-server", client.serverInfo().?.object.get("name").?.string);

    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();

    var saw_greet = false;
    for (tools.get("tools").?.array.items) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, "greet")) saw_greet = true;
    }
    try std.testing.expect(saw_greet);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "name", .{ .string = "Ada" });

    const called = try client.callTool(io, allocator, "greet", .{ .object = args });
    defer called.deinit();

    const text = called.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "Ada") != null);
}

test "a server error surfaces as an error with its code and message" {
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    try client.connectStdio(io, allocator, build_options.example_server_path, &.{});

    try std.testing.expectError(error.ServerError, client.callTool(io, allocator, "no-such-tool", null));
    try std.testing.expect(client.last_error != null);
    try std.testing.expect(client.last_error.?.message.len > 0);
}

/// Calls a single-string-argument tool on the probe server and returns the
/// text of the first content block. Caller owns the returned slice.
fn probeCall(
    client: *Client,
    io: std.Io,
    allocator: std.mem.Allocator,
    tool: []const u8,
    arg_name: []const u8,
    arg_value: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), arg_name, .{ .string = arg_value });

    const result = try client.callTool(io, allocator, tool, .{ .object = args });
    defer result.deinit();
    return allocator.dupe(u8, result.get("content").?.array.items[0].object.get("text").?.string);
}

test "connectStdioOptions passes env vars through to the child process" {
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    try client.connectStdioOptions(io, allocator, build_options.env_probe_server_path, .{
        .env = &.{.{ .name = "MCP_ZIG_PROBE", .value = "handed-over" }},
    });

    const value = try probeCall(&client, io, allocator, "getenv", "name", "MCP_ZIG_PROBE");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("handed-over", value);
}

test "connectStdioOptions can withhold the parent environment" {
    // A server you did not write should not automatically receive every
    // variable the host happens to hold.
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    try client.connectStdioOptions(io, allocator, build_options.env_probe_server_path, .{
        .inherit_environ = false,
        .env = &.{.{ .name = "MCP_ZIG_ONLY", .value = "1" }},
    });

    const kept = try probeCall(&client, io, allocator, "getenv", "name", "MCP_ZIG_ONLY");
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("1", kept);

    // PATH is set for essentially every test runner, and it is not in `env`.
    const dropped = try probeCall(&client, io, allocator, "getenv", "name", "PATH");
    defer allocator.free(dropped);
    try std.testing.expectEqualStrings("<unset>", dropped);
}

test "connectStdioOptions sets the child's working directory" {
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "marker.txt", .data = "in-the-right-place" });

    // The build option is relative to the build root, and the child resolves
    // argv[0] *after* changing directory, so it has to be absolute here.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const server_path = try std.fs.path.resolve(allocator, &.{
        cwd_buf[0..cwd_len],
        build_options.env_probe_server_path,
    });
    defer allocator.free(server_path);

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    try client.connectStdioOptions(io, allocator, server_path, .{
        .cwd = .{ .dir = tmp.dir },
    });

    const contents = try probeCall(&client, io, allocator, "read_relative", "path", "marker.txt");
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("in-the-right-place", contents);
}

test "an environment variable name containing '=' is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidEnvironmentVariableName, buildEnvironMap(allocator, .{
        .env = &.{.{ .name = "BAD=NAME", .value = "x" }},
    }));
}

test "listAllTools walks every page of a paginating server" {
    const build_options = @import("build_options");
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);

    // The fixture exports two tools; one per page forces a real second round
    // trip rather than a single page that happens to hold everything.
    try client.connectStdioOptions(io, allocator, build_options.env_probe_server_path, .{
        .env = &.{.{ .name = "MCP_ZIG_PAGE_SIZE", .value = "1" }},
    });

    const first = try client.listTools(io, allocator, .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.get("tools").?.array.items.len);
    try std.testing.expect(first.get("nextCursor") != null);

    const all = try client.listAllTools(io, allocator);
    defer all.deinit();

    try std.testing.expectEqual(@as(usize, 2), all.items.len);
    try std.testing.expectEqual(@as(usize, 2), all.responses.len);

    var saw_getenv = false;
    var saw_read = false;
    for (all.items) |tool| {
        const name = tool.object.get("name").?.string;
        if (std.mem.eql(u8, name, "getenv")) saw_getenv = true;
        if (std.mem.eql(u8, name, "read_relative")) saw_read = true;
    }
    try std.testing.expect(saw_getenv and saw_read);
}

/// A transport that replays canned responses, so the page-walk guards can be
/// driven against server behaviour a correct server would never produce.
const ScriptedTransport = struct {
    replies: []const []const u8,
    next: usize = 0,

    fn send(_: *ScriptedTransport, _: std.Io, _: std.mem.Allocator, _: []const u8) transport_mod.Transport.SendError!void {}

    fn receive(self: *ScriptedTransport, _: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.next >= self.replies.len) return null;
        defer self.next += 1;
        return allocator.dupe(u8, self.replies[self.next]) catch
            return transport_mod.Transport.ReceiveError.OutOfMemory;
    }

    fn close(_: *ScriptedTransport) void {}

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable: transport_mod.Transport.VTable = .{
        .send = @ptrCast(&send),
        .receive = @ptrCast(&receive),
        .close = @ptrCast(&close),
        .deinit = deinitFn,
    };

    fn transport(self: *ScriptedTransport) transport_mod.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "the page walk refuses a cursor that never advances" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scripted: ScriptedTransport = .{ .replies = &.{
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"a"}],"nextCursor":"stuck"}}
        ,
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"}],"nextCursor":"stuck"}}
        ,
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"a"}],"nextCursor":"stuck"}}
        ,
    } };

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = scripted.transport();

    try std.testing.expectError(error.CursorNotAdvancing, client.listAllTools(io, allocator));
}

/// A `ScriptedTransport` that also keeps every frame the client sent, so the
/// replies the client generates for server-initiated traffic can be asserted.
const RecordingTransport = struct {
    replies: []const []const u8,
    next: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *RecordingTransport) void {
        for (self.sent.items) |frame| self.allocator.free(frame);
        self.sent.deinit(self.allocator);
    }

    fn send(self: *RecordingTransport, _: std.Io, _: std.mem.Allocator, data: []const u8) transport_mod.Transport.SendError!void {
        const copy = self.allocator.dupe(u8, data) catch
            return transport_mod.Transport.SendError.OutOfMemory;
        self.sent.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return transport_mod.Transport.SendError.OutOfMemory;
        };
    }

    fn receive(self: *RecordingTransport, _: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.next >= self.replies.len) return null;
        defer self.next += 1;
        return allocator.dupe(u8, self.replies[self.next]) catch
            return transport_mod.Transport.ReceiveError.OutOfMemory;
    }

    fn close(_: *RecordingTransport) void {}

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable: transport_mod.Transport.VTable = .{
        .send = @ptrCast(&send),
        .receive = @ptrCast(&receive),
        .close = @ptrCast(&close),
        .deinit = deinitFn,
    };

    fn transport(self: *RecordingTransport) transport_mod.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The frame the client sent for a server request with `id`.
    fn replyTo(self: *const RecordingTransport, id: []const u8) ?[]const u8 {
        const needle = std.fmt.allocPrint(self.allocator, "\"id\":{s}", .{id}) catch return null;
        defer self.allocator.free(needle);
        for (self.sent.items) |frame| {
            if (std.mem.indexOf(u8, frame, needle) != null and
                std.mem.indexOf(u8, frame, "\"method\"") == null) return frame;
        }
        return null;
    }
};

test "a server-initiated roots/list is answered from the registered roots" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":77,"method":"roots/list"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        ,
    } };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();
    client.enableRoots(false);
    try client.addRoot(allocator, "file:///srv", "Srv");

    // The awaited response must still resolve past the interleaved request.
    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();

    const reply = recording.replyTo("77") orelse return error.NoReplySent;
    try std.testing.expect(std.mem.indexOf(u8, reply, "file:///srv") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"name\":\"Srv\"") != null);
}

test "a server request with no handler is answered -32601 instead of dropped" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":9,"method":"sampling/createMessage","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        ,
    } };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();

    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();

    const reply = recording.replyTo("9") orelse return error.NoReplySent;
    try std.testing.expect(std.mem.indexOf(u8, reply, "-32601") != null);
}

var test_notification_hits: usize = 0;

fn countNotification(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    _: ?std.json.Value,
) anyerror!void {
    test_notification_hits += 1;
}

test "a notification arriving mid-request fires its handler and does not eat the response" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"a"}]}}
        ,
    } };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();

    test_notification_hits = 0;
    try client.onNotification(allocator, "notifications/tools/list_changed", null, countNotification);

    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();

    try std.testing.expectEqual(@as(usize, 1), test_notification_hits);
    try std.testing.expectEqual(@as(usize, 1), tools.get("tools").?.array.items.len);
    // A notification carries no id, so it must never be answered.
    try std.testing.expectEqual(@as(usize, 1), recording.sent.items.len);
}

test "a reply for another request is parked, not discarded" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The reply to request 2 arrives before the reply to request 1.
    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":2,"result":{"prompts":[{"name":"later"}]}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"first"}]}}
        ,
    } };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();

    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();
    try std.testing.expectEqualStrings("first", tools.get("tools").?.array.items[0].object.get("name").?.string);

    // The transport is exhausted, so this can only succeed from the park.
    const prompts = try client.listPrompts(io, allocator, .{});
    defer prompts.deinit();
    try std.testing.expectEqualStrings("later", prompts.get("prompts").?.array.items[0].object.get("name").?.string);
}

fn stubSampling(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) anyerror!std.json.Value {
    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "role", .{ .string = "assistant" });
    return .{ .object = result };
}

test "the handshake refuses to advertise sampling with no handler" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{} };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();
    client.enableSampling();

    try std.testing.expectError(error.MissingSamplingHandler, client.initialize(io, allocator));

    // Registering the handler makes the same capability legitimate, so the
    // handshake gets past the check and fails later on the empty transport.
    try client.onRequest(allocator, "sampling/createMessage", null, stubSampling);
    try std.testing.expectError(error.NoResponse, client.initialize(io, allocator));
}

test "a registered handler takes precedence over the built-in roots/list" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recording: RecordingTransport = .{ .allocator = allocator, .replies = &.{
        \\{"jsonrpc":"2.0","id":5,"method":"roots/list"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        ,
    } };
    defer recording.deinit();

    var client: Client = .init(io, allocator, .{ .name = "test-client", .version = "1.0.0" });
    defer client.deinit(io, allocator);
    client.transport = recording.transport();
    client.enableRoots(false);
    try client.addRoot(allocator, "file:///builtin", "Builtin");
    try client.onRequest(allocator, "roots/list", null, stubSampling);

    const tools = try client.listTools(io, allocator, .{});
    defer tools.deinit();

    const reply = recording.replyTo("5") orelse return error.NoReplySent;
    try std.testing.expect(std.mem.indexOf(u8, reply, "file:///builtin") == null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "assistant") != null);
}

test "a failed handshake does not leave a transport for deinit to free twice" {
    // Ownership of the transport moves onto the client before the handshake
    // runs, so a connect that fails there used to free it once via the
    // connect's own errdefer and again via the caller's deinit.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, std.testing.allocator, .{ .name = "t", .version = "1" });
    defer client.deinit(io, std.testing.allocator);

    // Port 1 is reserved and never listening, so `initialize` cannot succeed.
    // The exact error depends on how the platform reports a refused connect,
    // which is not what this is about.
    if (client.connectHttp(io, std.testing.allocator, "http://127.0.0.1:1/")) |_| {
        return error.ExpectedConnectFailure;
    } else |_| {}
    try std.testing.expect(client.transport == null);
}

test "a stdio server that dies mid-handshake is torn down exactly once" {
    // Same ownership hazard as the http path: the child and its transport are
    // both published on `self` before the handshake, while the connect's own
    // `errdefer`s still hold them.
    if (builtin.os.tag == .windows) return;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: Client = .init(io, std.testing.allocator, .{ .name = "t", .version = "1" });
    defer client.deinit(io, std.testing.allocator);

    // Spawns cleanly and then closes its stdout, so `initialize` gets EOF.
    if (client.connectStdioOptions(io, std.testing.allocator, "/bin/sh", .{
        .args = &.{ "-c", "exit 0" },
    })) |_| {
        return error.ExpectedHandshakeFailure;
    } else |_| {}
    try std.testing.expect(client.transport == null);
    try std.testing.expect(client.child == null);
}

test "a client drives a real server over the http transport" {
    // The server and the client had only ever been tested apart: every http
    // server test called `handleMessage` directly, so nothing exercised a
    // request that actually crossed a socket.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server_mod = @import("../server/server.zig");
    const tools_mod = @import("../server/tools.zig");

    var server: server_mod.Server = .init(std.testing.allocator, .{ .name = "s", .version = "1" });
    defer server.deinit();

    const handlers = struct {
        fn ping(
            _: ?*anyopaque,
            _: std.Io,
            allocator: std.mem.Allocator,
            args: ?std.json.Value,
        ) tools_mod.ToolError!tools_mod.ToolResult {
            const message = tools_mod.getString(args, "message") orelse "pong";
            return tools_mod.textResult(allocator, message) catch return error.OutOfMemory;
        }
    };
    try server.addTool(.{
        .name = "ping",
        .description = "Echo the supplied message",
        .inputSchema = null,
        .handler = handlers.ping,
    });

    // A fixed port, because `shutdown` wakes the accept loop by dialing the
    // listener and port 0 gives it nothing to dial.
    const port: u16 = 47941;
    const runner = struct {
        fn run(s: *server_mod.Server, run_io: std.Io, allocator: std.mem.Allocator, p: u16) void {
            s.run(run_io, allocator, .{ .http = .{ .port = p, .shutdown_grace_ms = 200 } }) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, runner.run, .{ &server, io, std.testing.allocator, port });
    defer {
        server.shutdown(io);
        thread.join();
    }

    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        server.connections_mutex.lock(io) catch unreachable;
        const listening = server.http_listener != null;
        server.connections_mutex.unlock(io);
        if (listening) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try std.testing.expect(spins < 1000);

    var client: Client = .init(io, std.testing.allocator, .{ .name = "c", .version = "1" });
    defer client.deinit(io, std.testing.allocator);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    try client.connectHttp(io, std.testing.allocator, url);

    const listed = try client.listTools(io, std.testing.allocator, .{});
    defer listed.deinit();
    const tools = listed.result.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("ping", tools.items[0].object.get("name").?.string);

    var arguments: std.json.ObjectMap = .empty;
    defer arguments.deinit(std.testing.allocator);
    try arguments.put(std.testing.allocator, "message", .{ .string = "over-the-wire" });

    const called = try client.callTool(io, std.testing.allocator, "ping", .{ .object = arguments });
    defer called.deinit();
    const content = called.result.object.get("content").?.array;
    try std.testing.expectEqualStrings("over-the-wire", content.items[0].object.get("text").?.string);
}
