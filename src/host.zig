//! Runs several MCP servers behind one namespace.
//!
//! `Client` connects to exactly one server. An application that wants to offer
//! a model the union of several servers' tools has to keep the clients, decide
//! what happens when one of them is down, and invent a naming scheme so two
//! servers exporting `search` do not collide. `Host` does that.
//!
//! ```zig
//! var host: mcp.Host = .init(io, allocator, .{ .name = "my-app", .version = "1.0.0" });
//! defer host.deinit();
//!
//! try host.addDocument(doc);
//! try host.startAll();
//!
//! for (host.tools()) |tool| std.log.info("{s}", .{tool.exposed_name});
//! const result = try host.callTool(allocator, "mcp_files_read", args);
//! defer result.deinit();
//! ```
//!
//! The governing rule is **isolated failure**: one server that will not start,
//! or dies mid-session, must not take the others with it. `startAll` therefore
//! never fails because of a server; it records the failure on that server and
//! keeps going.

const std = @import("std");

const client_mod = @import("client/client.zig");
const config_mod = @import("config.zig");

const Client = client_mod.Client;
const Response = client_mod.Response;
const ServerSpec = config_mod.ServerSpec;

pub const HostConfig = struct {
    /// Identity reported to every server during the handshake.
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    /// Prefix on every exposed tool name.
    tool_prefix: []const u8 = "mcp",
    /// What to do with each spawned server's stderr.
    server_stderr: std.process.SpawnOptions.StdIo = .ignore,
    /// Working directory for every spawned server.
    ///
    /// Servers are routinely configured with paths relative to the workspace
    /// the host is operating on, so leaving them in whatever directory the
    /// host happens to have been launched from resolves those paths against
    /// the wrong root.
    cwd: std.process.Child.Cwd = .inherit,
    /// The environment spawned servers start from.
    ///
    /// Pass `init.environ_map` from `std.process.Init`; std 0.16 does not
    /// expose the environment as a global, so a host that wants a server's
    /// configured `env` layered onto the inherited environment has to supply
    /// it here.
    base_environ: ?*const std.process.Environ.Map = null,
    /// When false a server receives only `base_environ` plus its own
    /// configured `env`.
    ///
    /// Worth setting for servers you did not write: a third-party server has
    /// no need for every secret the host process happens to hold.
    inherit_environ: bool = true,
};

pub const Status = enum {
    /// Registered, not started.
    configured,
    /// Registered but turned off in configuration; `start` skips it.
    disabled,
    /// Connected and its tools are listed.
    ready,
    /// The last start attempt failed; `last_error` says why.
    failed,
    /// Was ready, then disconnected on request.
    stopped,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// One tool, under the name the host exposes it as.
pub const ExposedTool = struct {
    /// `<prefix>_<server>_<tool>`, unique across the host.
    exposed_name: []const u8,
    /// The name the owning server knows it by.
    tool_name: []const u8,
    server_name: []const u8,
    /// The tool's `description`, borrowed from the server's `tools/list`.
    description: ?[]const u8,
    /// The tool's `inputSchema`, borrowed from the server's `tools/list`.
    input_schema: ?std.json.Value,
    server_index: usize,
};

/// One configured server and whatever is currently known about it.
pub const HostedServer = struct {
    spec: ServerSpec,
    status: Status,
    /// Why the last start attempt failed. Owned.
    last_error: ?[]const u8 = null,
    client: ?*Client = null,
    /// Keeps the `tools/list` responses alive for as long as `ExposedTool`
    /// borrows names and schemas out of them.
    listing: ?client_mod.PagedItems = null,
    tool_count: usize = 0,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: HostConfig,
    servers: std.ArrayList(HostedServer) = .empty,
    exposed: std.ArrayList(ExposedTool) = .empty,

    const Self = @This();

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: HostConfig) Self {
        return .{ .allocator = allocator, .io = io, .config = config };
    }

    pub fn deinit(self: *Self) void {
        for (self.servers.items) |*server| self.teardown(server);
        for (self.servers.items) |*server| {
            self.allocator.free(server.spec.name);
            if (server.spec.command) |c| self.allocator.free(c);
            if (server.spec.url) |u| self.allocator.free(u);
        }
        self.servers.deinit(self.allocator);
        self.freeExposed();
        self.exposed.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a server.
    ///
    /// `spec` is borrowed except for the fields the host must outlive it on;
    /// the owning `config.Document` must stay alive for as long as the host,
    /// because `args`, `env` and `headers` are read on every start.
    pub fn addServer(self: *Self, spec: ServerSpec) !void {
        if (self.findIndex(spec.name) != null) return error.DuplicateServer;

        var owned = spec;
        owned.name = try self.allocator.dupe(u8, spec.name);
        errdefer self.allocator.free(owned.name);
        owned.command = if (spec.command) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (owned.command) |c| self.allocator.free(c);
        owned.url = if (spec.url) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (owned.url) |u| self.allocator.free(u);

        try self.servers.append(self.allocator, .{
            .spec = owned,
            .status = if (spec.enabled) .configured else .disabled,
        });
    }

    /// Registers every server in a parsed configuration document.
    pub fn addDocument(self: *Self, doc: config_mod.Document) !void {
        for (doc.servers) |spec| {
            self.addServer(spec) catch |err| switch (err) {
                // A duplicate is a configuration question, not a host failure:
                // first definition wins and the rest of the document loads.
                error.DuplicateServer => continue,
                else => |e| return e,
            };
        }
    }

    /// Connects one server and lists its tools.
    ///
    /// A failure is recorded on the server and returned; the host stays usable
    /// and every other server is untouched.
    pub fn startServer(self: *Self, name: []const u8) !void {
        const index = self.findIndex(name) orelse return error.UnknownServer;
        return self.startIndex(index);
    }

    /// Connects every enabled server.
    ///
    /// Never fails because of a server: a server that will not start is left
    /// `.failed` with `last_error` set, and the others still come up. Returns
    /// how many are `.ready`.
    pub fn startAll(self: *Self) !usize {
        var ready: usize = 0;
        for (self.servers.items, 0..) |*server, i| {
            if (server.status == .disabled) continue;
            if (server.status == .ready) {
                ready += 1;
                continue;
            }
            self.startIndex(i) catch continue;
            ready += 1;
        }
        return ready;
    }

    fn startIndex(self: *Self, index: usize) !void {
        const server = &self.servers.items[index];
        if (server.status == .disabled) return error.ServerDisabled;
        if (server.status == .ready) return;

        self.teardown(server);

        self.connect(server) catch |err| {
            self.fail(server, err);
            return err;
        };

        self.list(index) catch |err| {
            self.fail(server, err);
            return err;
        };

        server.status = .ready;
    }

    fn connect(self: *Self, server: *HostedServer) !void {
        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);

        client.* = .init(self.io, self.allocator, .{
            .name = self.config.name,
            .version = self.config.version,
            .title = self.config.title,
            .server_stderr = self.config.server_stderr,
        });
        errdefer client.deinit(self.io, self.allocator);

        switch (server.spec.transport) {
            .stdio => try client.connectStdioOptions(
                self.io,
                self.allocator,
                server.spec.command orelse return error.MissingCommand,
                self.stdioOptionsFor(server.spec),
            ),
            .http, .sse => try client.connectHttpOptions(
                self.io,
                self.allocator,
                server.spec.url orelse return error.MissingUrl,
                server.spec.httpOptions(),
            ),
        }

        server.client = client;
    }

    /// The spec's own options, plus the spawn context every server shares.
    fn stdioOptionsFor(self: *const Self, spec: ServerSpec) client_mod.StdioOptions {
        var options = spec.stdioOptions();
        options.cwd = self.config.cwd;
        options.base_environ = self.config.base_environ;
        options.inherit_environ = self.config.inherit_environ;
        return options;
    }

    /// Reads the server's tools and republishes them under exposed names.
    ///
    /// Publishing is all-or-nothing. `ExposedTool` borrows names and schemas
    /// out of the listing, so the previously published tools must stay live —
    /// and stay published — until the replacement set is fully built. Anything
    /// that can fail happens before a single old entry is withdrawn.
    fn list(self: *Self, index: usize) !void {
        const server = &self.servers.items[index];
        const client = server.client orelse return error.NotConnected;

        const listing = try client.listAllTools(self.io, self.allocator);
        errdefer listing.deinit();

        var staged: std.ArrayList(ExposedTool) = .empty;
        errdefer {
            for (staged.items) |tool| self.allocator.free(tool.exposed_name);
            staged.deinit(self.allocator);
        }

        for (listing.items) |item| {
            const object = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const tool_name = switch (object.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (!self.isAllowed(server.spec, tool_name)) continue;

            const exposed_name = try self.uniqueExposedName(server.spec.name, tool_name, staged.items);
            errdefer self.allocator.free(exposed_name);

            try staged.append(self.allocator, .{
                .exposed_name = exposed_name,
                .tool_name = tool_name,
                .server_name = server.spec.name,
                .description = switch (object.get("description") orelse std.json.Value{ .null = {} }) {
                    .string => |s| s,
                    else => null,
                },
                .input_schema = object.get("inputSchema"),
                .server_index = index,
            });
        }

        // Nothing below this line can fail, so the swap is atomic.
        try self.exposed.ensureUnusedCapacity(self.allocator, staged.items.len);
        self.dropExposedFor(index);
        self.exposed.appendSliceAssumeCapacity(staged.items);
        staged.deinit(self.allocator);

        if (server.listing) |previous| previous.deinit();
        server.listing = listing;
        server.tool_count = self.countExposedFor(index);
    }

    /// Re-reads a ready server's tools, for `notifications/tools/list_changed`.
    ///
    /// A refresh that fails leaves the server's previously published tools in
    /// place rather than silently emptying it.
    pub fn refreshTools(self: *Self, name: []const u8) !void {
        const index = self.findIndex(name) orelse return error.UnknownServer;
        if (self.servers.items[index].status != .ready) return error.ServerNotReady;
        return self.list(index);
    }

    /// Disconnects a server and withdraws its tools. Its configuration stays.
    pub fn stopServer(self: *Self, name: []const u8) !void {
        const index = self.findIndex(name) orelse return error.UnknownServer;
        const server = &self.servers.items[index];
        self.dropExposedFor(index);
        self.teardown(server);
        server.status = if (server.spec.enabled) .stopped else .disabled;
    }

    /// Stops and starts a server, e.g. after it has died.
    pub fn restartServer(self: *Self, name: []const u8) !void {
        const index = self.findIndex(name) orelse return error.UnknownServer;
        const server = &self.servers.items[index];
        if (!server.spec.enabled) return error.ServerDisabled;
        self.dropExposedFor(index);
        self.teardown(server);
        server.status = .configured;
        return self.startIndex(index);
    }

    /// Every tool currently offered, across all ready servers.
    pub fn tools(self: *const Self) []const ExposedTool {
        return self.exposed.items;
    }

    /// The tool published as `exposed_name`, if any.
    pub fn findTool(self: *const Self, exposed_name: []const u8) ?ExposedTool {
        for (self.exposed.items) |tool| {
            if (std.mem.eql(u8, tool.exposed_name, exposed_name)) return tool;
        }
        return null;
    }

    /// Calls a tool by its exposed name.
    ///
    /// Resolution goes through the exposed table rather than by decoding the
    /// name, so the mapping back to (server, tool) is exact no matter what
    /// characters the server used.
    pub fn callTool(
        self: *Self,
        allocator: std.mem.Allocator,
        exposed_name: []const u8,
        arguments: ?std.json.Value,
    ) !Response {
        const tool = self.findTool(exposed_name) orelse return error.UnknownTool;
        const server = &self.servers.items[tool.server_index];
        if (server.status != .ready) return error.ServerNotReady;
        const client = server.client orelse return error.NotConnected;
        return client.callTool(self.io, allocator, tool.tool_name, arguments);
    }

    pub fn status(self: *const Self, name: []const u8) ?Status {
        const index = self.findIndex(name) orelse return null;
        return self.servers.items[index].status;
    }

    /// Why the named server last failed to start, if it did.
    pub fn lastError(self: *const Self, name: []const u8) ?[]const u8 {
        const index = self.findIndex(name) orelse return null;
        return self.servers.items[index].last_error;
    }

    pub fn findIndex(self: *const Self, name: []const u8) ?usize {
        for (self.servers.items, 0..) |server, i| {
            if (std.mem.eql(u8, server.spec.name, name)) return i;
        }
        return null;
    }

    fn isAllowed(self: *const Self, spec: ServerSpec, tool_name: []const u8) bool {
        _ = self;
        // An empty allow-list means "everything"; it cannot mean "nothing",
        // because a server with no `tools` key would then be silently muted.
        if (spec.allowed_tools.len == 0) return true;
        for (spec.allowed_tools) |allowed| {
            if (std.mem.eql(u8, allowed, tool_name)) return true;
        }
        return false;
    }

    fn fail(self: *Self, server: *HostedServer, err: anyerror) void {
        self.teardown(server);
        server.status = .failed;
        server.last_error = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
    }

    fn teardown(self: *Self, server: *HostedServer) void {
        if (server.listing) |listing| {
            listing.deinit();
            server.listing = null;
        }
        if (server.client) |client| {
            client.deinit(self.io, self.allocator);
            self.allocator.destroy(client);
            server.client = null;
        }
        if (server.last_error) |message| {
            self.allocator.free(message);
            server.last_error = null;
        }
        server.tool_count = 0;
    }

    fn dropExposedFor(self: *Self, index: usize) void {
        var i: usize = 0;
        while (i < self.exposed.items.len) {
            if (self.exposed.items[i].server_index == index) {
                self.allocator.free(self.exposed.orderedRemove(i).exposed_name);
            } else {
                i += 1;
            }
        }
    }

    fn freeExposed(self: *Self) void {
        for (self.exposed.items) |tool| self.allocator.free(tool.exposed_name);
        self.exposed.clearRetainingCapacity();
    }

    /// Builds `<prefix>_<server>_<tool>`, appending a counter if that name is
    /// somehow already taken.
    fn uniqueExposedName(
        self: *Self,
        server_name: []const u8,
        tool_name: []const u8,
        staged: []const ExposedTool,
    ) ![]const u8 {
        const base = try exposedToolName(self.allocator, self.config.tool_prefix, server_name, tool_name);
        if (!nameTaken(staged, base)) return base;
        defer self.allocator.free(base);

        var suffix: usize = 2;
        while (suffix < 1000) : (suffix += 1) {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ base, suffix });
            if (!nameTaken(staged, candidate)) return candidate;
            self.allocator.free(candidate);
        }
        return error.NameCollision;
    }

    fn countExposedFor(self: *const Self, index: usize) usize {
        var count: usize = 0;
        for (self.exposed.items) |tool| {
            if (tool.server_index == index) count += 1;
        }
        return count;
    }
};

fn nameTaken(tools_slice: []const ExposedTool, name: []const u8) bool {
    for (tools_slice) |tool| {
        if (std.mem.eql(u8, tool.exposed_name, name)) return true;
    }
    return false;
}

/// Encodes a (server, tool) pair into a single identifier.
///
/// Everything outside `[A-Za-z0-9]` becomes `_xNN`, including `_` itself, so
/// the single unescaped `_` separators are the only ones in the result and the
/// encoding is injective: two distinct pairs cannot produce the same name.
/// Model-facing tool names are also commonly restricted to this character set.
pub fn exposedToolName(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    server_name: []const u8,
    tool_name: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, prefix);
    try out.append(allocator, '_');
    try appendSanitized(allocator, &out, server_name);
    try out.append(allocator, '_');
    try appendSanitized(allocator, &out, tool_name);
    return out.toOwnedSlice(allocator);
}

fn appendSanitized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "_x{x:0>2}", .{c});
        }
    }
}

const testing = std.testing;

fn testDoc(bytes: []const u8) !config_mod.Document {
    return config_mod.parse(testing.allocator, bytes, "test.json");
}

test "the exposed name encoding is injective across the separator" {
    const allocator = testing.allocator;

    // Both pairs would collide under a naive join on "_".
    const a = try exposedToolName(allocator, "mcp", "a_b", "c");
    defer allocator.free(a);
    const b = try exposedToolName(allocator, "mcp", "a", "b_c");
    defer allocator.free(b);

    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings("mcp_a_x5fb_c", a);
    try testing.expectEqualStrings("mcp_a_b_x5fc", b);

    // The result stays inside the character set model-facing names allow.
    const messy = try exposedToolName(allocator, "mcp", "my server!", "read/file");
    defer allocator.free(messy);
    for (messy) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '_');
}

test "a server that cannot start does not stop the others" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDoc(
        \\{"mcpServers":{
        \\"broken":{"command":"definitely-not-a-real-binary-xyzzy"},
        \\"also-broken":{"command":"another-missing-binary-xyzzy"}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);

    // startAll must survive every server failing.
    const ready = try host.startAll();
    try testing.expectEqual(@as(usize, 0), ready);
    try testing.expectEqual(Status.failed, host.status("broken").?);
    try testing.expectEqual(Status.failed, host.status("also-broken").?);
    try testing.expect(host.lastError("broken") != null);
    try testing.expectEqual(@as(usize, 0), host.tools().len);
}

test "a disabled server is registered but never started" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDoc(
        \\{"mcpServers":{"off":{"command":"missing-binary-xyzzy","enabled":false}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);

    try testing.expectEqual(Status.disabled, host.status("off").?);
    try testing.expectEqual(@as(usize, 0), try host.startAll());
    // Never attempted, so it is still `.disabled` rather than `.failed`.
    try testing.expectEqual(Status.disabled, host.status("off").?);
    try testing.expectError(error.ServerDisabled, host.startServer("off"));
}

test "duplicate names are refused and unknown names are reported" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDoc(
        \\{"mcpServers":{"a":{"command":"x"}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();

    try host.addServer(doc.servers[0]);
    try testing.expectError(error.DuplicateServer, host.addServer(doc.servers[0]));
    try testing.expectEqual(@as(usize, 1), host.servers.items.len);

    try testing.expectError(error.UnknownServer, host.startServer("nope"));
    try testing.expectError(error.UnknownTool, host.callTool(allocator, "mcp_a_read", null));
    try testing.expect(host.status("nope") == null);
}

test "the host outlives a spec whose owning document is gone" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();

    {
        var doc = try testDoc(
            \\{"mcpServers":{"transient":{"command":"some-binary"}}}
        );
        defer doc.deinit();
        try host.addDocument(doc);
    }

    // Name and command are duped, so they survive the document.
    try testing.expectEqual(Status.configured, host.status("transient").?);
    try testing.expectEqualStrings("some-binary", host.servers.items[0].spec.command.?);
}

/// Builds a document whose entries all point at the built example server, so
/// the end-to-end tests exercise real spawning, listing and calling.
fn testDocForExampleServer(comptime bytes_fmt: []const u8) !config_mod.Document {
    const build_options = @import("build_options");

    // Windows paths are full of backslashes, which are not legal in a JSON
    // string literal.
    const path = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        build_options.example_server_path,
        "\\",
        "\\\\",
    );
    defer testing.allocator.free(path);

    const bytes = try std.fmt.allocPrint(testing.allocator, bytes_fmt, .{ path, path });
    defer testing.allocator.free(bytes);
    return config_mod.parse(testing.allocator, bytes, "test.json");
}

test "two servers exporting the same tool do not collide" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"alpha":{{"command":"{s}"}},"beta":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);

    try testing.expectEqual(@as(usize, 2), try host.startAll());
    try testing.expectEqual(Status.ready, host.status("alpha").?);
    try testing.expectEqual(Status.ready, host.status("beta").?);

    // Both servers export `greet` and `echo`; all four must be reachable.
    try testing.expectEqual(@as(usize, 4), host.tools().len);
    try testing.expect(host.findTool("mcp_alpha_greet") != null);
    try testing.expect(host.findTool("mcp_beta_greet") != null);

    const alpha = host.findTool("mcp_alpha_greet").?;
    try testing.expectEqualStrings("greet", alpha.tool_name);
    try testing.expectEqualStrings("alpha", alpha.server_name);
    try testing.expect(alpha.description != null);
    try testing.expect(alpha.input_schema != null);
}

test "a call is routed to the server that owns the tool" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"alpha":{{"command":"{s}"}},"beta":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startAll();

    var args_arena: std.heap.ArenaAllocator = .init(allocator);
    defer args_arena.deinit();
    var args: std.json.ObjectMap = .empty;
    try args.put(args_arena.allocator(), "message", .{ .string = "routed" });

    const result = try host.callTool(allocator, "mcp_beta_echo", .{ .object = args });
    defer result.deinit();

    const text = result.result.object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "routed") != null);
}

test "the tools allow-list hides everything it does not name" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"limited":{{"command":"{s}","tools":["echo"]}},
        \\"open":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startAll();

    try testing.expect(host.findTool("mcp_limited_echo") != null);
    try testing.expect(host.findTool("mcp_limited_greet") == null);
    // An absent allow-list must mean "everything", not "nothing".
    try testing.expect(host.findTool("mcp_open_greet") != null);
    try testing.expectEqual(@as(usize, 3), host.tools().len);

    // A hidden tool is not callable by the back door either.
    try testing.expectError(error.UnknownTool, host.callTool(allocator, "mcp_limited_greet", null));
}

test "a broken server does not take a working one down with it" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"broken":{{"command":"missing-binary-xyzzy"}},
        \\"working":{{"command":"{s}"}},"ignored":{{"command":"{s}","enabled":false}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);

    try testing.expectEqual(@as(usize, 1), try host.startAll());
    try testing.expectEqual(Status.failed, host.status("broken").?);
    try testing.expectEqual(Status.ready, host.status("working").?);
    try testing.expectEqual(Status.disabled, host.status("ignored").?);

    try testing.expectEqual(@as(usize, 2), host.tools().len);
    const result = try host.callTool(allocator, "mcp_working_greet", null);
    defer result.deinit();
}

test "stopping withdraws a server's tools and restarting brings them back" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"alpha":{{"command":"{s}"}},"beta":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startAll();
    try testing.expectEqual(@as(usize, 4), host.tools().len);

    try host.stopServer("alpha");
    try testing.expectEqual(Status.stopped, host.status("alpha").?);
    try testing.expectEqual(@as(usize, 2), host.tools().len);
    try testing.expect(host.findTool("mcp_alpha_greet") == null);
    // Stopping one server must not disturb the other's tools.
    try testing.expect(host.findTool("mcp_beta_greet") != null);
    try testing.expectError(error.UnknownTool, host.callTool(allocator, "mcp_alpha_greet", null));

    try host.restartServer("alpha");
    try testing.expectEqual(Status.ready, host.status("alpha").?);
    try testing.expectEqual(@as(usize, 4), host.tools().len);

    const result = try host.callTool(allocator, "mcp_alpha_greet", null);
    defer result.deinit();
}

test "refreshing a server's tools replaces its listing without disturbing others" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"alpha":{{"command":"{s}"}},"beta":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startAll();

    try host.refreshTools("alpha");
    try testing.expectEqual(@as(usize, 4), host.tools().len);
    try testing.expect(host.findTool("mcp_alpha_greet") != null);
    try testing.expect(host.findTool("mcp_beta_echo") != null);

    // Names must still resolve against a live listing, not a freed one.
    const result = try host.callTool(allocator, "mcp_alpha_greet", null);
    defer result.deinit();

    try testing.expectError(error.UnknownServer, host.refreshTools("nope"));
}

test "a refresh that fails leaves the previous tools intact and callable" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var doc = try testDocForExampleServer(
        \\{{"mcpServers":{{"alpha":{{"command":"{s}"}},"beta":{{"command":"{s}"}}}}}}
    );
    defer doc.deinit();

    var host: Host = .init(io, allocator, .{ .name = "test-host", .version = "1.0.0" });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startAll();

    const before = host.findTool("mcp_beta_echo").?;

    // Cut the pipe under beta so its next `tools/list` cannot complete. The
    // published tools borrow names and schemas out of the listing being
    // replaced, so a refresh that frees it before the replacement arrives
    // leaves every one of them dangling.
    host.servers.items[host.findIndex("beta").?].client.?.disconnect(io);
    try testing.expect(std.meta.isError(host.refreshTools("beta")));

    const after = host.findTool("mcp_beta_echo") orelse return error.ToolsLost;
    try testing.expectEqualStrings("echo", after.tool_name);
    try testing.expectEqualStrings(before.tool_name, after.tool_name);
    try testing.expect(after.input_schema != null);
    try testing.expectEqual(@as(usize, 4), host.tools().len);

    // Alpha is untouched by beta's failed refresh.
    const result = try host.callTool(allocator, "mcp_alpha_greet", null);
    defer result.deinit();
}

test "the spawn context reaches every server the host starts" {
    const allocator = testing.allocator;
    const build_options = @import("build_options");
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "marker.txt", .data = "found by cwd" });

    // The child resolves argv[0] after chdir, so the server path has to be
    // absolute once a cwd is set.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &buf);
    const server_path = try std.fs.path.resolve(
        allocator,
        &.{ buf[0..cwd_len], build_options.env_probe_server_path },
    );
    defer allocator.free(server_path);

    const escaped = try std.mem.replaceOwned(u8, allocator, server_path, "\\", "\\\\");
    defer allocator.free(escaped);
    const bytes = try std.fmt.allocPrint(allocator,
        \\{{"mcpServers":{{"probe":{{"command":"{s}","env":{{"HOST_SPAWN_MARKER":"from-host"}}}}}}}}
    , .{escaped});
    defer allocator.free(bytes);

    var doc = try config_mod.parse(allocator, bytes, "test.json");
    defer doc.deinit();

    var base: std.process.Environ.Map = .init(allocator);
    defer base.deinit();
    try base.put("HOST_BASE_MARKER", "from-base");

    var host: Host = .init(io, allocator, .{
        .name = "test-host",
        .version = "1.0.0",
        .cwd = .{ .dir = tmp.dir },
        .base_environ = &base,
        .inherit_environ = false,
    });
    defer host.deinit();
    try host.addDocument(doc);
    _ = try host.startServer("probe");

    // cwd: the server resolves a relative path against the host's directory.
    {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var args: std.json.ObjectMap = .empty;
        try args.put(arena.allocator(), "path", .{ .string = "marker.txt" });
        const result = try host.callTool(allocator, "mcp_probe_read_x5frelative", .{ .object = args });
        defer result.deinit();
        const text = result.result.object.get("content").?.array.items[0].object.get("text").?.string;
        try testing.expect(std.mem.indexOf(u8, text, "found by cwd") != null);
    }

    // base_environ, and the spec's own env layered on top of it.
    for ([_][2][]const u8{
        .{ "HOST_BASE_MARKER", "from-base" },
        .{ "HOST_SPAWN_MARKER", "from-host" },
    }) |pair| {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var args: std.json.ObjectMap = .empty;
        try args.put(arena.allocator(), "name", .{ .string = pair[0] });
        const result = try host.callTool(allocator, "mcp_probe_getenv", .{ .object = args });
        defer result.deinit();
        const text = result.result.object.get("content").?.array.items[0].object.get("text").?.string;
        try testing.expect(std.mem.indexOf(u8, text, pair[1]) != null);
    }
}
