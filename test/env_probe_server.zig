//! Test fixture: an MCP server that reports its own process environment and
//! working directory.
//!
//! It exists so the stdio spawn options can be checked against what the child
//! actually received, rather than against what the parent believes it sent.
//! Not an example; it is only wired into the test build.

const std = @import("std");
const mcp = @import("mcp");

/// The environment handed to this process. Tool handlers do not receive
/// `std.process.Init`, so it is stashed here for them.
var process_environ: ?*const std.process.Environ.Map = null;

pub fn main(init: std.process.Init) void {
    process_environ = init.environ_map;
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const sa = schema_arena.allocator();

    const getenv_schema = try buildStringSchema(sa, "name", "Environment variable to read");
    const read_schema = try buildStringSchema(sa, "path", "Path to read, resolved against the cwd");

    // Driven by the environment so the pagination tests can reuse this
    // fixture without teaching it argument parsing.
    const page_size = blk: {
        const map = process_environ orelse break :blk 0;
        const raw = map.get("MCP_ZIG_PAGE_SIZE") orelse break :blk 0;
        break :blk std.fmt.parseInt(usize, raw, 10) catch 0;
    };

    var server: mcp.Server = .init(allocator, .{
        .name = "env-probe-server",
        .version = "1.0.0",
        .description = "Reports the spawned process's environment and working directory",
        .page_size = page_size,
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "getenv",
        .description = "Return the value of an environment variable, or the literal <unset>",
        .inputSchema = getenv_schema,
        .handler = getenvHandler,
    });

    try server.addTool(.{
        .name = "read_relative",
        .description = "Read a file relative to the working directory, or the literal <none>",
        .inputSchema = read_schema,
        .handler = readRelativeHandler,
    });

    try server.run(io, allocator, .stdio);
}

fn buildStringSchema(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = try b.addString(allocator, name, description, true);
    return b.toInputSchema(allocator);
}

fn getenvHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;
    const map = process_environ orelse return mcp.tools.ToolError.Unknown;
    const value = map.get(name) orelse "<unset>";
    return mcp.tools.textResult(allocator, value) catch mcp.tools.ToolError.OutOfMemory;
}

fn readRelativeHandler(
    _: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = mcp.tools.getString(args, "path") orelse return mcp.tools.ToolError.InvalidArguments;
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch
        return mcp.tools.textResult(allocator, "<none>") catch mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(contents);
    return mcp.tools.textResult(allocator, contents) catch mcp.tools.ToolError.OutOfMemory;
}
