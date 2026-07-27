//! MCP Client Implementation (Spec 2025-11-25)
//!
//! Provides an MCP client that connects to MCP servers via STDIO or HTTP transport.
//! The client handles protocol negotiation, capability advertisement, and provides
//! methods for listing and invoking tools, reading resources, and fetching prompts.
//! Supports task-augmented requests, sampling, elicitation, and roots.

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

/// A JSON-RPC error returned by the server.
pub const ServerError = struct {
    code: i64,
    message: []const u8,
};

/// How many consecutive empty reads to tolerate while waiting for a response
/// before giving up with `error.NoResponse`.
const max_empty_reads = 128;

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
            .update_thread = if (config.check_for_updates) report.checkForUpdates(io, allocator) else null,
        };
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
        self.pending_requests.deinit();
        self.roots_list.deinit(allocator);
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
        self.transport = stdio.transport();

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

        try self.initialize(io, allocator);
    }

    /// Sends the initialize request to begin the MCP handshake.
    fn initialize(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
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

    /// Reads from the transport until the response with `id` arrives.
    ///
    /// Messages that are not that response are discarded. Server-initiated
    /// requests (sampling, elicitation, `roots/list`) are therefore not
    /// answered yet; they need a handler registry.
    fn awaitResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, id: i64) !Response {
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
            defer allocator.free(raw);
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

            // Not the reply we are waiting for: a notification, or a response
            // to some other request.
            const id_value = obj.get("id") orelse continue;
            const response_id = switch (id_value) {
                .integer => |i| i,
                else => continue,
            };
            if (response_id != id) continue;

            if (obj.get("error")) |err_value| {
                try self.recordServerError(allocator, err_value);
                return error.ServerError;
            }

            const result = obj.get("result") orelse return error.InvalidResponse;
            keep = true;
            return .{ .parsed = parsed, .result = result };
        }
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

    /// Requests the list of available tools from the server.
    pub fn listTools(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "tools/list", null);
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
    pub fn listResources(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "resources/list", null);
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
    pub fn listResourceTemplates(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "resources/templates/list", null);
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Response {
        return self.request(io, allocator, "prompts/list", null);
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

    const tools = try client.listTools(io, allocator);
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
