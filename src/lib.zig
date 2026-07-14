const std = @import("std");

pub const Server = @import("server.zig").Server;
pub const Config = @import("server.zig").Config;
pub const Storage = @import("storage.zig").Storage;

pub const MysqlZigConfig = extern struct {
    bind_host: [*:0]const u8,
    port: u16,
    dump_path: [*:0]const u8,
    username: [*:0]const u8,
    password: [*:0]const u8,
};

pub const MysqlZigHandle = opaque {};

threadlocal var last_error_buf: [256]u8 = [_]u8{0} ** 256;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    @memset(&last_error_buf, 0);
    const msg = std.fmt.bufPrintZ(&last_error_buf, fmt, args) catch "mysqlzig error";
    _ = msg;
}

pub export fn mysqlzig_default_config() MysqlZigConfig {
    return .{
        .bind_host = "127.0.0.1",
        .port = 3306,
        .dump_path = "mysqlzig.dump",
        .username = "root",
        .password = "",
    };
}

pub export fn mysqlzig_start(raw_cfg: *const MysqlZigConfig) ?*MysqlZigHandle {
    const allocator = std.heap.smp_allocator;
    const cfg = Config{
        .bind_host = std.mem.span(raw_cfg.bind_host),
        .port = raw_cfg.port,
        .dump_path = std.mem.span(raw_cfg.dump_path),
        .username = std.mem.span(raw_cfg.username),
        .password = std.mem.span(raw_cfg.password),
    };
    const server = allocator.create(Server) catch {
        setLastError("out of memory", .{});
        return null;
    };
    server.* = Server.init(allocator, cfg);
    server.start() catch |err| {
        setLastError("start failed: {t}", .{err});
        server.deinit();
        allocator.destroy(server);
        return null;
    };
    return @ptrCast(server);
}

pub export fn mysqlzig_stop(handle: ?*MysqlZigHandle) void {
    const ptr = handle orelse return;
    const server: *Server = @ptrCast(@alignCast(ptr));
    const allocator = server.allocator;
    server.stop();
    server.deinit();
    allocator.destroy(server);
}

pub export fn mysqlzig_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

test {
    _ = @import("protocol.zig");
    _ = @import("sql.zig");
    _ = @import("storage.zig");
}
