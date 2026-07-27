//! Parser for the `mcpServers` configuration object.
//!
//! Every MCP host reads the same de-facto schema — an `mcpServers` object
//! mapping a server name to how that server is reached — and every host has
//! written its own parser for it. This module parses that object and nothing
//! else. It does not decide where the file lives, does not read it, and does
//! not connect: `parse` takes bytes, `Document` hands back specs that plug
//! straight into `Client.connectStdioOptions` and `Client.connectHttpOptions`.
//!
//! ```zig
//! var doc = try mcp.config.parse(allocator, bytes, "mcp-config.json");
//! defer doc.deinit();
//! for (doc.diagnostics) |d| std.log.warn("{s}", .{d});
//! for (doc.servers) |spec| { ... }
//! ```
//!
//! A malformed entry never sinks the file. Each server is parsed on its own;
//! a bad one is dropped with a diagnostic and the rest still load, because a
//! typo in one server should not disconnect every other server a user has.

const std = @import("std");

const client_mod = @import("client/client.zig");
const transport_mod = @import("transport/transport.zig");

pub const EnvVar = client_mod.EnvVar;

/// How a server is reached.
pub const Transport = enum {
    stdio,
    http,
    sse,

    pub fn label(self: Transport) []const u8 {
        return switch (self) {
            .stdio => "stdio",
            .http => "http",
            .sse => "sse",
        };
    }
};

/// One entry of `mcpServers`.
///
/// Field lifetimes are tied to the owning `Document`; nothing here needs to be
/// freed individually.
pub const ServerSpec = struct {
    /// The key this entry appeared under.
    name: []const u8,
    /// The `source_label` passed to `parse`, carried so a later diagnostic can
    /// say which file a server came from after several have been merged.
    source: []const u8,
    transport: Transport,
    /// Set for `.stdio`.
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    /// Set for `.http` and `.sse`.
    url: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Tools the host may expose from this server. Empty means all of them;
    /// this is an allow-list, so an empty list cannot be confused with "none".
    allowed_tools: []const []const u8 = &.{},
    /// `false` when the entry carries `"enabled": false` or `"disabled": true`.
    /// The spec is still returned so a host can list it as configured-but-off.
    enabled: bool = true,

    /// Options for `Client.connectStdioOptions`.
    ///
    /// Asserts the transport is `.stdio`.
    pub fn stdioOptions(self: ServerSpec) client_mod.StdioOptions {
        std.debug.assert(self.transport == .stdio);
        return .{ .args = self.args, .env = self.env };
    }

    /// Options for `Client.connectHttpOptions`.
    ///
    /// Asserts the transport is not `.stdio`.
    pub fn httpOptions(self: ServerSpec) client_mod.Client.HttpOptions {
        std.debug.assert(self.transport != .stdio);
        return .{ .extra_headers = self.headers };
    }
};

/// A parsed configuration and every complaint raised while parsing it.
pub const Document = struct {
    /// Servers in the order they appeared, minus any that failed to parse.
    servers: []ServerSpec,
    /// Human-readable problems. Never contains a header or environment
    /// *value*, because those routinely hold credentials and diagnostics
    /// routinely end up in logs.
    diagnostics: []const []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: Document) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    /// The spec registered under `name`, if any.
    pub fn find(self: Document, name: []const u8) ?ServerSpec {
        for (self.servers) |spec| {
            if (std.mem.eql(u8, spec.name, name)) return spec;
        }
        return null;
    }
};

/// Accumulates results into one arena while parsing.
const Builder = struct {
    arena: std.mem.Allocator,
    servers: std.ArrayList(ServerSpec) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,
    source: []const u8,

    fn note(self: *Builder, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.diagnostics.append(self.arena, message);
    }
};

/// Raised for a single entry; the file keeps parsing.
const EntryError = error{InvalidEntry} || std.mem.Allocator.Error;

/// Parses an `mcpServers` document.
///
/// `source_label` is echoed in diagnostics and stored on each spec; it is a
/// label, not a path the parser will ever open. Returns an error only when the
/// document as a whole is unusable (not JSON, not an object, no `mcpServers`);
/// anything narrower becomes a diagnostic.
pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    source_label: []const u8,
) !Document {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var builder: Builder = .{ .arena = aa, .source = try aa.dupe(u8, source_label) };

    var parsed = std.json.parseFromSlice(std.json.Value, aa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    // Hosts write both the nested form and the bare object. Accepting the bare
    // form costs nothing and spares users a confusing "no servers" result.
    const servers_value = root.get("mcpServers") orelse root.get("servers") orelse blk: {
        if (root.count() == 0) break :blk std.json.Value{ .object = root };
        if (root.get("inputs") != null) break :blk std.json.Value{ .object = root };
        break :blk std.json.Value{ .object = root };
    };
    const servers_object = switch (servers_value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    var it = servers_object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "inputs")) continue;
        const spec = parseEntry(&builder, name, entry.value_ptr.*) catch |err| switch (err) {
            error.InvalidEntry => continue,
            else => |e| return e,
        };
        try builder.servers.append(aa, spec);
    }

    return .{
        .servers = try builder.servers.toOwnedSlice(aa),
        .diagnostics = try builder.diagnostics.toOwnedSlice(aa),
        .arena = arena,
    };
}

fn parseEntry(b: *Builder, name: []const u8, value: std.json.Value) EntryError!ServerSpec {
    if (name.len == 0) {
        try b.note("{s}: a server name may not be empty", .{b.source});
        return error.InvalidEntry;
    }

    const object = switch (value) {
        .object => |o| o,
        else => {
            try b.note("{s}: mcpServers.{s} must be an object", .{ b.source, name });
            return error.InvalidEntry;
        },
    };

    const type_raw = try stringField(b, name, object, "type");
    const command_raw = try stringField(b, name, object, "command");
    const url_raw = try stringField(b, name, object, "url");

    const transport = try inferTransport(b, name, type_raw, command_raw, url_raw);

    if (transport == .stdio and isBlank(command_raw)) {
        try b.note("{s}: mcpServers.{s}.command must be a non-empty string for a stdio server", .{ b.source, name });
        return error.InvalidEntry;
    }
    if (transport != .stdio and isBlank(url_raw)) {
        try b.note("{s}: mcpServers.{s}.url must be a non-empty string for an {s} server", .{ b.source, name, transport.label() });
        return error.InvalidEntry;
    }

    const args = try stringArrayField(b, name, object, "args");
    const allowed_tools = try stringArrayField(b, name, object, "tools");
    const env = try envField(b, name, object);
    const headers = try headerField(b, name, object);

    if (transport == .stdio and headers.len > 0) {
        try b.note("{s}: mcpServers.{s}.headers is ignored for a stdio server", .{ b.source, name });
    }

    return .{
        .name = try b.arena.dupe(u8, name),
        .source = b.source,
        .transport = transport,
        .command = if (command_raw) |c| try b.arena.dupe(u8, trim(c)) else null,
        .args = args,
        .env = env,
        .url = if (url_raw) |u| try b.arena.dupe(u8, trim(u)) else null,
        .headers = headers,
        .allowed_tools = allowed_tools,
        .enabled = try enabledField(b, name, object),
    };
}

fn inferTransport(
    b: *Builder,
    name: []const u8,
    type_raw: ?[]const u8,
    command_raw: ?[]const u8,
    url_raw: ?[]const u8,
) EntryError!Transport {
    if (type_raw) |raw| {
        const v = trim(raw);
        // "local" and "streamable-http" are the names other hosts write for
        // the same two transports; rejecting them would be pedantry.
        if (eqlAny(v, &.{ "stdio", "local" })) return .stdio;
        if (eqlAny(v, &.{ "http", "streamable-http", "streamablehttp", "remote" })) return .http;
        if (eqlAny(v, &.{ "sse" })) return .sse;
        try b.note("{s}: mcpServers.{s}.type has unsupported value \"{s}\"", .{ b.source, name, v });
        return error.InvalidEntry;
    }
    if (!isBlank(command_raw)) return .stdio;
    if (!isBlank(url_raw)) return .http;
    try b.note("{s}: mcpServers.{s} must define either command or url", .{ b.source, name });
    return error.InvalidEntry;
}

fn stringField(
    b: *Builder,
    name: []const u8,
    object: std.json.ObjectMap,
    field: []const u8,
) EntryError!?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => {
            try b.note("{s}: mcpServers.{s}.{s} must be a string", .{ b.source, name, field });
            return error.InvalidEntry;
        },
    };
}

fn enabledField(b: *Builder, name: []const u8, object: std.json.ObjectMap) EntryError!bool {
    if (object.get("enabled")) |v| switch (v) {
        .bool => |on| return on,
        else => {
            try b.note("{s}: mcpServers.{s}.enabled must be a boolean", .{ b.source, name });
            return error.InvalidEntry;
        },
    };
    if (object.get("disabled")) |v| switch (v) {
        .bool => |off| return !off,
        else => {
            try b.note("{s}: mcpServers.{s}.disabled must be a boolean", .{ b.source, name });
            return error.InvalidEntry;
        },
    };
    return true;
}

fn stringArrayField(
    b: *Builder,
    name: []const u8,
    object: std.json.ObjectMap,
    field: []const u8,
) EntryError![]const []const u8 {
    const value = object.get(field) orelse return &.{};
    const items = switch (value) {
        .array => |a| a.items,
        .null => return &.{},
        else => {
            try b.note("{s}: mcpServers.{s}.{s} must be an array of strings", .{ b.source, name, field });
            return error.InvalidEntry;
        },
    };

    const out = try b.arena.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| try b.arena.dupe(u8, s),
            else => {
                try b.note("{s}: mcpServers.{s}.{s}[{d}] must be a string", .{ b.source, name, field, i });
                return error.InvalidEntry;
            },
        };
    }
    return out;
}

fn envField(b: *Builder, name: []const u8, object: std.json.ObjectMap) EntryError![]const EnvVar {
    const value = object.get("env") orelse return &.{};
    const map = switch (value) {
        .object => |o| o,
        .null => return &.{},
        else => {
            try b.note("{s}: mcpServers.{s}.env must be an object of string values", .{ b.source, name });
            return error.InvalidEntry;
        },
    };

    var out = try b.arena.alloc(EnvVar, map.count());
    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => {
                // The value is not echoed: env values are a normal place for
                // API keys.
                try b.note("{s}: mcpServers.{s}.env.{s} must be a string", .{ b.source, name, key });
                return error.InvalidEntry;
            },
        };
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null or
            std.mem.indexOfScalar(u8, key, 0) != null)
        {
            try b.note("{s}: mcpServers.{s}.env has an unusable variable name", .{ b.source, name });
            return error.InvalidEntry;
        }
        try notePlaceholder(b, name, "env", key, raw);
        out[i] = .{
            .name = try b.arena.dupe(u8, key),
            .value = try b.arena.dupe(u8, raw),
        };
        i += 1;
    }
    return out[0..i];
}

fn headerField(b: *Builder, name: []const u8, object: std.json.ObjectMap) EntryError![]const std.http.Header {
    const value = object.get("headers") orelse return &.{};
    const map = switch (value) {
        .object => |o| o,
        .null => return &.{},
        else => {
            try b.note("{s}: mcpServers.{s}.headers must be an object of string values", .{ b.source, name });
            return error.InvalidEntry;
        },
    };

    var out = try b.arena.alloc(std.http.Header, map.count());
    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => {
                try b.note("{s}: mcpServers.{s}.headers.{s} must be a string", .{ b.source, name, key });
                return error.InvalidEntry;
            },
        };

        // Validated here rather than at connect time so a header that can
        // never be sent is reported next to the file that defines it. The
        // value never reaches the diagnostic; `Authorization` lives here.
        transport_mod.HttpTransport.validateHeader(.{ .name = key, .value = raw }) catch |err| {
            const reason = switch (err) {
                error.InvalidHeaderName => "is not a valid header name",
                error.InvalidHeaderValue => "has a value containing CR, LF or NUL",
                error.ReservedHeader => "is set by the transport and cannot be overridden",
                else => "is not usable",
            };
            try b.note("{s}: mcpServers.{s}.headers.{s} {s}", .{ b.source, name, key, reason });
            return error.InvalidEntry;
        };

        try notePlaceholder(b, name, "headers", key, raw);
        out[i] = .{
            .name = try b.arena.dupe(u8, key),
            .value = try b.arena.dupe(u8, raw),
        };
        i += 1;
    }
    return out[0..i];
}

/// Flags a `${VAR}` that this parser will not expand.
///
/// Substitution is deliberately out of scope — it is a host policy decision,
/// not a parsing one. Passing `${GITHUB_TOKEN}` through as a literal bearer
/// token would fail in a way that looks like a server bug, so say so.
fn notePlaceholder(
    b: *Builder,
    name: []const u8,
    field: []const u8,
    key: []const u8,
    raw: []const u8,
) EntryError!void {
    if (std.mem.indexOf(u8, raw, "${") == null) return;
    try b.note(
        "{s}: mcpServers.{s}.{s}.{s} contains a ${{...}} placeholder, which is passed through unexpanded",
        .{ b.source, name, field, key },
    );
}

/// Combines documents, later ones winning by server name.
///
/// This is how layered configuration (user, then project, then local) resolves
/// without the parser knowing that layering exists. The result borrows from the
/// inputs, so every `docs` entry must outlive it.
pub fn merge(allocator: std.mem.Allocator, docs: []const Document) ![]ServerSpec {
    var out: std.ArrayList(ServerSpec) = .empty;
    errdefer out.deinit(allocator);

    for (docs) |doc| {
        for (doc.servers) |spec| {
            var replaced = false;
            for (out.items) |*existing| {
                if (std.mem.eql(u8, existing.name, spec.name)) {
                    existing.* = spec;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.append(allocator, spec);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isBlank(s: ?[]const u8) bool {
    const v = s orelse return true;
    return trim(v).len == 0;
}

fn eqlAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.ascii.eqlIgnoreCase(value, option)) return true;
    }
    return false;
}

test "a stdio server is parsed with args and env" {
    const bytes =
        \\{"mcpServers":{"files":{"command":"mcp-files","args":["--root","/srv"],
        \\"env":{"TOKEN":"abc"},"tools":["read"]}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), doc.servers.len);

    const spec = doc.find("files").?;
    try std.testing.expectEqual(Transport.stdio, spec.transport);
    try std.testing.expectEqualStrings("mcp-files", spec.command.?);
    try std.testing.expectEqual(@as(usize, 2), spec.args.len);
    try std.testing.expectEqualStrings("/srv", spec.args[1]);
    try std.testing.expectEqualStrings("TOKEN", spec.env[0].name);
    try std.testing.expectEqualStrings("read", spec.allowed_tools[0]);
    try std.testing.expect(spec.enabled);

    // The spec must drop straight into the connect call.
    const options = spec.stdioOptions();
    try std.testing.expectEqual(@as(usize, 2), options.args.len);
    try std.testing.expectEqual(@as(usize, 1), options.env.len);
}

test "transport is inferred from command or url when type is absent" {
    const bytes =
        \\{"mcpServers":{"a":{"command":"x"},"b":{"url":"https://example.test/mcp"},
        \\"c":{"type":"sse","url":"https://example.test/sse"},
        \\"d":{"type":"streamable-http","url":"https://example.test/s"},
        \\"e":{"type":"local","command":"y"}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
    try std.testing.expectEqual(Transport.stdio, doc.find("a").?.transport);
    try std.testing.expectEqual(Transport.http, doc.find("b").?.transport);
    try std.testing.expectEqual(Transport.sse, doc.find("c").?.transport);
    try std.testing.expectEqual(Transport.http, doc.find("d").?.transport);
    try std.testing.expectEqual(Transport.stdio, doc.find("e").?.transport);
}

test "one broken entry does not take the others down with it" {
    const bytes =
        \\{"mcpServers":{
        \\"good":{"command":"x"},
        \\"no-target":{},
        \\"bad-type":{"type":"carrier-pigeon","url":"https://example.test"},
        \\"bad-args":{"command":"y","args":[1,2]},
        \\"not-an-object":"nope",
        \\"also-good":{"url":"https://example.test/mcp"}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.servers.len);
    try std.testing.expect(doc.find("good") != null);
    try std.testing.expect(doc.find("also-good") != null);
    try std.testing.expect(doc.find("no-target") == null);
    try std.testing.expectEqual(@as(usize, 4), doc.diagnostics.len);

    for (doc.diagnostics) |d| {
        try std.testing.expect(std.mem.startsWith(u8, d, "test.json: "));
    }
}

test "an unusable header is rejected without echoing its value" {
    const bytes =
        \\{"mcpServers":{
        \\"crlf":{"url":"https://example.test","headers":{"X-Trace":"a\r\nX-Injected: 1"}},
        \\"reserved":{"url":"https://example.test","headers":{"Content-Type":"text/plain"}},
        \\"fine":{"url":"https://example.test","headers":{"Authorization":"Bearer s3cret"}}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.servers.len);
    try std.testing.expectEqualStrings("Authorization", doc.find("fine").?.headers[0].name);
    try std.testing.expectEqual(@as(usize, 2), doc.diagnostics.len);

    // A diagnostic that leaks the credential it is complaining about is worse
    // than no diagnostic.
    for (doc.diagnostics) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d, "s3cret") == null);
        try std.testing.expect(std.mem.indexOf(u8, d, "X-Injected") == null);
    }
}

test "a ${VAR} placeholder is reported rather than silently passed through" {
    const bytes =
        \\{"mcpServers":{"gh":{"url":"https://example.test",
        \\"headers":{"Authorization":"Bearer ${GITHUB_TOKEN}"}}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    // The entry still loads; the host may substitute it itself.
    try std.testing.expectEqual(@as(usize, 1), doc.servers.len);
    try std.testing.expectEqualStrings("Bearer ${GITHUB_TOKEN}", doc.find("gh").?.headers[0].value);
    try std.testing.expectEqual(@as(usize, 1), doc.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, doc.diagnostics[0], "unexpanded") != null);
}

test "disabled entries are kept but flagged" {
    const bytes =
        \\{"mcpServers":{"a":{"command":"x","enabled":false},"b":{"command":"y","disabled":true},
        \\"c":{"command":"z"}}}
    ;
    var doc = try parse(std.testing.allocator, bytes, "test.json");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.servers.len);
    try std.testing.expect(!doc.find("a").?.enabled);
    try std.testing.expect(!doc.find("b").?.enabled);
    try std.testing.expect(doc.find("c").?.enabled);
}

test "merge lets a later document override by name" {
    var base = try parse(std.testing.allocator,
        \\{"mcpServers":{"a":{"command":"base-a"},"b":{"command":"base-b"}}}
    , "user.json");
    defer base.deinit();

    var overlay = try parse(std.testing.allocator,
        \\{"mcpServers":{"a":{"command":"overlay-a"},"c":{"command":"overlay-c"}}}
    , "project.json");
    defer overlay.deinit();

    const merged = try merge(std.testing.allocator, &.{ base, overlay });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("a", merged[0].name);
    try std.testing.expectEqualStrings("overlay-a", merged[0].command.?);
    // The winner carries its own source, so a later diagnostic names the
    // right file.
    try std.testing.expectEqualStrings("project.json", merged[0].source);
    try std.testing.expectEqualStrings("base-b", merged[1].command.?);
    try std.testing.expectEqualStrings("overlay-c", merged[2].command.?);
}

test "a document that is not usable at all is an error, not a diagnostic" {
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "not json", "t.json"));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[1,2]", "t.json"));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "{\"mcpServers\":7}", "t.json"));
}
