//! JSON-RPC 2.0 Implementation
//!
//! Provides a complete JSON-RPC 2.0 implementation for MCP communication.
//! Handles message parsing, serialization, validation, and factory functions
//! for creating requests, responses, notifications, and errors.

const std = @import("std");

const types = @import("types.zig");

/// JSON-RPC protocol version.
pub const VERSION = "2.0";

/// A JSON-RPC 2.0 request message.
pub const Request = struct {
    jsonrpc: []const u8 = VERSION,
    id: types.RequestId,
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn format(
        self: Request,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Request{{ id: {}, method: \"{s}\" }}", .{ self.id, self.method });
    }
};

/// A JSON-RPC 2.0 notification (request without id).
pub const Notification = struct {
    jsonrpc: []const u8 = VERSION,
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn format(
        self: Notification,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Notification{{ method: \"{s}\" }}", .{self.method});
    }
};

/// A JSON-RPC 2.0 success response.
pub const Response = struct {
    jsonrpc: []const u8 = VERSION,
    id: types.RequestId,
    result: ?std.json.Value = null,

    pub fn format(
        self: Response,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Response{{ id: {} }}", .{self.id});
    }
};

/// A JSON-RPC 2.0 error response.
pub const ErrorResponse = struct {
    jsonrpc: []const u8 = VERSION,
    id: ?types.RequestId,
    @"error": Error,

    pub const Error = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };

    pub fn format(
        self: ErrorResponse,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.id) |id| {
            try writer.print("ErrorResponse{{ id: {}, code: {d}, message: \"{s}\" }}", .{ id, self.@"error".code, self.@"error".message });
        } else {
            try writer.print("ErrorResponse{{ id: null, code: {d}, message: \"{s}\" }}", .{ self.@"error".code, self.@"error".message });
        }
    }
};

/// Union of all JSON-RPC message types.
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    error_response: ErrorResponse,

    pub fn isRequest(self: Message) bool {
        return self == .request;
    }

    pub fn isNotification(self: Message) bool {
        return self == .notification;
    }

    pub fn isResponse(self: Message) bool {
        return self == .response or self == .error_response;
    }
};

/// Standard JSON-RPC 2.0 error codes and MCP extensions.
pub const ErrorCode = struct {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
    pub const SERVER_NOT_INITIALIZED: i32 = -32002;
    pub const REQUEST_CANCELLED: i32 = -32800;
    pub const CONTENT_TOO_LARGE: i32 = -32801;
    /// Implementation-defined (the -32000..-32099 range JSON-RPC reserves for
    /// servers): every worker is busy, so the call was refused rather than
    /// queued behind work the client cannot see.
    pub const SERVER_BUSY: i32 = -32000;
};

/// Errors that can occur during message parsing.
pub const ParseError = error{
    InvalidJson,
    MissingVersion,
    InvalidVersion,
    MissingMethod,
    InvalidMessage,
    OutOfMemory,
};

/// Result of parsing a message, keeping the arena alive.
pub const ParsedMessage = struct {
    message: Message,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: ParsedMessage) void {
        self.parsed.deinit();
    }
};

/// Parses a JSON-RPC message from a JSON string.
pub fn parseMessage(allocator: std.mem.Allocator, json_str: []const u8) ParseError!ParsedMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return ParseError.InvalidJson;
    };
    errdefer parsed.deinit();

    const message = parseFromValue(parsed.value) catch |err| {
        return err;
    };

    return ParsedMessage{
        .message = message,
        .parsed = parsed,
    };
}

/// Parses a JSON-RPC message from a parsed JSON value.
pub fn parseFromValue(value: std.json.Value) ParseError!Message {
    if (value != .object) {
        return ParseError.InvalidMessage;
    }

    const obj = value.object;

    if (obj.get("jsonrpc")) |version_val| {
        if (version_val != .string or !std.mem.eql(u8, version_val.string, VERSION)) {
            return ParseError.InvalidVersion;
        }
    } else {
        return ParseError.MissingVersion;
    }

    if (obj.get("error")) |_| {
        return Message{ .error_response = parseErrorResponse(obj) catch return ParseError.InvalidMessage };
    }

    if (obj.get("method")) |method_val| {
        if (method_val != .string) {
            return ParseError.InvalidMessage;
        }

        if (obj.get("id")) |id_val| {
            return Message{ .request = parseRequest(obj, id_val, method_val.string) catch return ParseError.InvalidMessage };
        } else {
            return Message{ .notification = parseNotification(obj, method_val.string) };
        }
    }

    if (obj.get("id")) |id_val| {
        if (obj.get("result") != null) {
            return Message{ .response = parseResponse(obj, id_val) catch return ParseError.InvalidMessage };
        }
    }

    return ParseError.InvalidMessage;
}

fn parseRequest(obj: std.json.ObjectMap, id_val: std.json.Value, method: []const u8) !Request {
    return Request{
        .id = try parseRequestId(id_val),
        .method = method,
        .params = obj.get("params"),
    };
}

fn parseNotification(obj: std.json.ObjectMap, method: []const u8) Notification {
    return Notification{
        .method = method,
        .params = obj.get("params"),
    };
}

fn parseResponse(obj: std.json.ObjectMap, id_val: std.json.Value) !Response {
    return Response{
        .id = try parseRequestId(id_val),
        .result = obj.get("result"),
    };
}

fn parseErrorResponse(obj: std.json.ObjectMap) !ErrorResponse {
    const error_obj = obj.get("error") orelse return error.InvalidMessage;
    if (error_obj != .object) return error.InvalidMessage;

    const err = error_obj.object;
    const code = if (err.get("code")) |c| switch (c) {
        // std.json parses integers as i64, so a peer can supply a value that
        // does not fit in i32. An unchecked @intCast would panic in safe
        // builds and silently truncate in ReleaseFast; treat it as a
        // malformed message instead, which the caller already turns into a
        // proper JSON-RPC parse error.
        .integer => std.math.cast(i32, c.integer) orelse return error.InvalidMessage,
        else => return error.InvalidMessage,
    } else return error.InvalidMessage;

    const message = if (err.get("message")) |m| switch (m) {
        .string => m.string,
        else => return error.InvalidMessage,
    } else return error.InvalidMessage;

    const id = if (obj.get("id")) |id_val| try parseRequestId(id_val) else null;

    return ErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .data = err.get("data"),
        },
    };
}

fn parseRequestId(value: std.json.Value) !types.RequestId {
    return switch (value) {
        .string => |s| types.RequestId{ .string = s },
        .integer => |i| types.RequestId{ .integer = i },
        else => error.InvalidMessage,
    };
}

/// Serializes a message to a JSON string.
pub fn serializeMessage(allocator: std.mem.Allocator, message: Message) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    switch (message) {
        .request => |req| try serializeRequest(allocator, &buffer, req),
        .notification => |notif| try serializeNotification(allocator, &buffer, notif),
        .response => |resp| try serializeResponse(allocator, &buffer, resp),
        .error_response => |err| try serializeErrorResponse(allocator, &buffer, err),
    }

    return buffer.toOwnedSlice(allocator);
}

fn serializeRequest(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), req: Request) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try serializeRequestId(allocator, buffer, req.id);
    try buffer.appendSlice(allocator, ",\"method\":");
    try appendJsonString(allocator, buffer, req.method);
    if (req.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try serializeValue(allocator, buffer, params);
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeNotification(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), notif: Notification) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":");
    try appendJsonString(allocator, buffer, notif.method);
    if (notif.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try serializeValue(allocator, buffer, params);
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeResponse(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), resp: Response) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try serializeRequestId(allocator, buffer, resp.id);
    try buffer.appendSlice(allocator, ",\"result\":");
    if (resp.result) |result| {
        try serializeValue(allocator, buffer, result);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeErrorResponse(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), err: ErrorResponse) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (err.id) |id| {
        try serializeRequestId(allocator, buffer, id);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, ",\"error\":{\"code\":");
    var code_buf: [16]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{err.@"error".code}) catch "0";
    try buffer.appendSlice(allocator, code_str);
    try buffer.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, buffer, err.@"error".message);
    if (err.@"error".data) |data| {
        try buffer.appendSlice(allocator, ",\"data\":");
        try serializeValue(allocator, buffer, data);
    }
    try buffer.appendSlice(allocator, "}}");
}

/// Appends `s` to `buffer` as a complete JSON string literal, including the
/// surrounding quotes.
///
/// Every string this module emits must go through here. Emitting a raw slice
/// between two quote characters lets a peer that controls the slice close the
/// string early and inject arbitrary JSON structure. Because request IDs are
/// chosen by the peer and echoed back in every response, and because both
/// framings in use are delimiter-based (newline for stdio, a blank line for
/// SSE), an unescaped newline does not merely corrupt one object: it ends the
/// current frame and starts one the peer fully controls.
fn appendJsonString(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), s: []const u8) !void {
    try buffer.append(allocator, '"');
    try appendJsonStringChars(allocator, buffer, s);
    try buffer.append(allocator, '"');
}

/// Appends the escaped body of a JSON string literal, without the quotes,
/// per RFC 8259 section 7.
fn appendJsonStringChars(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            0x08 => try buffer.appendSlice(allocator, "\\b"),
            0x09 => try buffer.appendSlice(allocator, "\\t"),
            0x0A => try buffer.appendSlice(allocator, "\\n"),
            0x0C => try buffer.appendSlice(allocator, "\\f"),
            0x0D => try buffer.appendSlice(allocator, "\\r"),
            // The remaining C0 controls have no short escape but are still
            // forbidden raw inside a string.
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var escape_buf: [6]u8 = undefined;
                const escaped = std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try buffer.appendSlice(allocator, escaped);
            },
            else => try buffer.append(allocator, c),
        }
    }
}

fn serializeRequestId(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), id: types.RequestId) !void {
    switch (id) {
        .string => |s| {
            try appendJsonString(allocator, buffer, s);
        },
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
    }
}

pub fn serializeValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buffer.appendSlice(allocator, "null"),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
        .float => |f| {
            var float_buf: [64]u8 = undefined;
            const float_str = std.fmt.bufPrint(&float_buf, "{d}", .{f}) catch "0";
            try buffer.appendSlice(allocator, float_str);
        },
        .string => |s| {
            try appendJsonString(allocator, buffer, s);
        },
        .array => |arr| {
            try buffer.appendSlice(allocator, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buffer.appendSlice(allocator, ",");
                try serializeValue(allocator, buffer, item);
            }
            try buffer.appendSlice(allocator, "]");
        },
        .object => |obj| {
            try buffer.appendSlice(allocator, "{");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try buffer.appendSlice(allocator, ",");
                first = false;
                try appendJsonString(allocator, buffer, entry.key_ptr.*);
                try buffer.appendSlice(allocator, ":");
                try serializeValue(allocator, buffer, entry.value_ptr.*);
            }
            try buffer.appendSlice(allocator, "}");
        },
        .number_string => |s| try buffer.appendSlice(allocator, s),
    }
}

/// Creates a request message.
pub fn createRequest(id: types.RequestId, method: []const u8, params: ?std.json.Value) Request {
    return Request{
        .id = id,
        .method = method,
        .params = params,
    };
}

/// Creates a notification message.
pub fn createNotification(method: []const u8, params: ?std.json.Value) Notification {
    return Notification{
        .method = method,
        .params = params,
    };
}

/// Creates a success response.
pub fn createResponse(id: types.RequestId, result: ?std.json.Value) Response {
    return Response{
        .id = id,
        .result = result,
    };
}

/// Creates an error response.
pub fn createErrorResponse(id: ?types.RequestId, code: i32, message: []const u8, data: ?std.json.Value) ErrorResponse {
    return ErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .data = data,
        },
    };
}

/// Creates a parse error response (-32700).
pub fn createParseError(data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(null, ErrorCode.PARSE_ERROR, "Parse error", data);
}

/// Creates an invalid request error response (-32600).
pub fn createInvalidRequest(id: ?types.RequestId, data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INVALID_REQUEST, "Invalid request", data);
}

/// Creates a method not found error response (-32601).
pub fn createMethodNotFound(id: types.RequestId, method: []const u8) ErrorResponse {
    _ = method;
    return createErrorResponse(id, ErrorCode.METHOD_NOT_FOUND, "Method not found", null);
}

/// Creates an invalid params error response (-32602).
pub fn createInvalidParams(id: types.RequestId, message: []const u8) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INVALID_PARAMS, message, null);
}

/// Creates an internal error response (-32603).
pub fn createInternalError(id: types.RequestId, data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INTERNAL_ERROR, "Internal error", data);
}

test "parse request" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";

    const result = try parseMessage(allocator, json);
    defer result.deinit();
    try std.testing.expect(result.message == .request);
    try std.testing.expectEqualStrings("test", result.message.request.method);
}

test "parse notification" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";

    const result = try parseMessage(allocator, json);
    defer result.deinit();
    try std.testing.expect(result.message == .notification);
    try std.testing.expectEqualStrings("notifications/initialized", result.message.notification.method);
}

test "serialize request" {
    const allocator = std.testing.allocator;
    const req = createRequest(.{ .integer = 42 }, "test/method", null);

    const json = try serializeMessage(allocator, .{ .request = req });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"test/method\"") != null);
}

test "error codes" {
    try std.testing.expectEqual(@as(i32, -32700), ErrorCode.PARSE_ERROR);
    try std.testing.expectEqual(@as(i32, -32600), ErrorCode.INVALID_REQUEST);
}

/// Round-trips `json` through the parser and returns the value, asserting that
/// what the serializer produced is well-formed JSON in the first place.
fn expectReparses(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
}

test "serializer escapes string request IDs" {
    // A peer that controls `id` must not be able to close the string early and
    // inject members into the response object.
    const hostile = "a\",\"injected\":\"yes";
    const resp = createResponse(.{ .string = hostile }, .{ .object = .empty });
    const json = try serializeMessage(std.testing.allocator, .{ .response = resp });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();

    // The id must survive intact, and no extra member may appear.
    try std.testing.expectEqualStrings(hostile, parsed.value.object.get("id").?.string);
    try std.testing.expect(parsed.value.object.get("injected") == null);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.count());
}

test "serializer escapes newlines in request IDs so frames cannot be smuggled" {
    // stdio framing is newline-delimited and SSE framing is blank-line
    // delimited, so a raw newline in `id` would terminate the frame and let the
    // peer start one of its own.
    const hostile = "x\n\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}";
    const resp = createResponse(.{ .string = hostile }, .{ .object = .empty });
    const json = try serializeMessage(std.testing.allocator, .{ .response = resp });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);

    var parsed = try expectReparses(json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(hostile, parsed.value.object.get("id").?.string);
}

test "serializer escapes error messages" {
    const hostile = "boom\",\"injected\":\"yes";
    const err = createErrorResponse(.{ .integer = 1 }, ErrorCode.INTERNAL_ERROR, hostile, null);
    const json = try serializeMessage(std.testing.allocator, .{ .error_response = err });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(hostile, error_obj.get("message").?.string);
    try std.testing.expect(parsed.value.object.get("injected") == null);
    try std.testing.expect(error_obj.get("injected") == null);
}

test "serializer escapes object keys" {
    var result: std.json.ObjectMap = .empty;
    defer result.deinit(std.testing.allocator);
    const hostile_key = "k\",\"injected\":\"yes";
    try result.put(std.testing.allocator, hostile_key, .{ .string = "v" });

    const resp = createResponse(.{ .integer = 1 }, .{ .object = result });
    const json = try serializeMessage(std.testing.allocator, .{ .response = resp });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();

    const result_obj = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 1), result_obj.count());
    try std.testing.expectEqualStrings("v", result_obj.get(hostile_key).?.string);
}

test "serializer escapes method names" {
    const hostile = "m\",\"injected\":\"yes";
    const notif = createNotification(hostile, null);
    const json = try serializeMessage(std.testing.allocator, .{ .notification = notif });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(hostile, parsed.value.object.get("method").?.string);
    try std.testing.expect(parsed.value.object.get("injected") == null);
}

test "serializer escapes all C0 control characters" {
    // RFC 8259 section 7 forbids raw control characters inside a string. The
    // previous implementation only handled \n, \r and \t.
    var raw: [0x20]u8 = undefined;
    for (&raw, 0..) |*c, i| c.* = @intCast(i);

    const resp = createResponse(.{ .string = &raw }, .{ .object = .empty });
    const json = try serializeMessage(std.testing.allocator, .{ .response = resp });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&raw, parsed.value.object.get("id").?.string);
}

test "serializer escapes backslashes" {
    // A trailing backslash would otherwise escape the closing quote.
    const hostile = "c:\\path\\";
    const resp = createResponse(.{ .string = hostile }, .{ .object = .empty });
    const json = try serializeMessage(std.testing.allocator, .{ .response = resp });
    defer std.testing.allocator.free(json);

    var parsed = try expectReparses(json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(hostile, parsed.value.object.get("id").?.string);
}

test "out-of-range error codes are rejected rather than crashing" {
    // std.json parses integers as i64, so a peer can send a code outside the
    // i32 range. This used to reach an unchecked @intCast and abort the
    // process from any connection, before initialize.
    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":9999999999,\"message\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-9999999999,\"message\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":9223372036854775807,\"message\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-9223372036854775808,\"message\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":2147483648,\"message\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-2147483649,\"message\":\"x\"}}",
    };

    for (cases) |json| {
        try std.testing.expectError(
            ParseError.InvalidMessage,
            parseMessage(std.testing.allocator, json),
        );
    }
}

test "in-range error codes still parse, including i32 boundaries" {
    const cases = [_]struct { json: []const u8, code: i32 }{
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"x\"}}", .code = -32600 },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":2147483647,\"message\":\"x\"}}", .code = 2147483647 },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-2147483648,\"message\":\"x\"}}", .code = -2147483648 },
    };

    for (cases) |case| {
        var parsed = try parseMessage(std.testing.allocator, case.json);
        defer parsed.deinit();
        try std.testing.expectEqual(case.code, parsed.message.error_response.@"error".code);
    }
}
