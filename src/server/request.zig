//! Per-request state a handler can observe while it runs.
//!
//! This lives in its own module so both the server and the tool definitions
//! can name it without importing each other.

const std = @import("std");

/// The request a handler is currently serving.
///
/// A handler that may run for a while should poll `isCancelled` and abandon
/// work whose result can no longer be delivered. The flag is set from another
/// thread — the one that received `notifications/cancelled` — so it is atomic.
///
/// New per-request facilities (progress tokens, deadlines, per-request logging)
/// belong here rather than as extra handler parameters, so adding one is not a
/// breaking change.
pub const RequestContext = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    /// Asks the running handler to stop. Safe to call from any thread, and
    /// safe to call more than once.
    pub fn cancel(self: *RequestContext) void {
        self.cancelled.store(true, .release);
    }

    /// Whether the client withdrew this request, or the session went away.
    pub fn isCancelled(self: *const RequestContext) bool {
        return self.cancelled.load(.acquire);
    }
};

test "a fresh context is not cancelled" {
    var ctx: RequestContext = .{};
    try std.testing.expect(!ctx.isCancelled());
}

test "cancellation is idempotent" {
    var ctx: RequestContext = .{};
    ctx.cancel();
    ctx.cancel();
    try std.testing.expect(ctx.isCancelled());
}
