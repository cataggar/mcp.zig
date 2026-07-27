//! Simple MCP Client Example
//!
//! Demonstrates client initialization, capability declaration, and root configuration.
//! Run: zig build run-client

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    const exe = args.next() orelse "example-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        return;
    }

    var client: mcp.Client = .init(io, allocator, .{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
    });
    defer client.deinit(io, allocator);

    // Declare supported capabilities
    client.enableSamplingAdvanced(true, true);
    client.enableElicitation();
    client.enableTasksAdvanced(true, true);
    client.enableRoots(true);

    // Register file-system roots the server should respect
    const docs = mcp.roots.fileRoot("file:///home/user/documents", "Documents");
    const projects = mcp.roots.fileRoot("file:///home/user/projects", "Projects");
    try client.addRoot(allocator, docs.uri, docs.name);
    try client.addRoot(allocator, projects.uri, projects.name);

    // Spawn the server and complete the handshake.
    try client.connectStdio(io, allocator, server_cmd.?, &.{});

    std.debug.print("Connected to {s}\n", .{server_cmd.?});
    if (client.serverInfo()) |info| {
        std.debug.print("  Server:   {s} v{s}\n", .{
            info.object.get("name").?.string,
            info.object.get("version").?.string,
        });
    }
    std.debug.print("  Protocol: {s}\n", .{client.negotiated_version.?});

    // List the tools the server offers.
    const tools = try client.listTools(io, allocator);
    defer tools.deinit();

    const list = tools.get("tools") orelse return error.MissingTools;
    std.debug.print("  Tools:    {d}\n", .{list.array.items.len});
    for (list.array.items) |tool| {
        std.debug.print("    - {s}\n", .{tool.object.get("name").?.string});
    }

    // Call the first one that takes no required arguments, if any.
    if (list.array.items.len > 0) {
        const name = list.array.items[0].object.get("name").?.string;
        const result = client.callTool(io, allocator, name, null) catch |err| {
            if (err == error.ServerError) {
                if (client.last_error) |e| {
                    std.debug.print("\ncallTool({s}) failed: {d} {s}\n", .{ name, e.code, e.message });
                }
                return;
            }
            return err;
        };
        defer result.deinit();
        std.debug.print("\ncallTool({s}) returned a result\n", .{name});
    }
}
