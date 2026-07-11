const std = @import("std");
const protocol = @import("protocol.zig");
const sql = @import("sql.zig");
const Storage = @import("storage.zig").Storage;

pub const Config = struct {
    bind_host: []const u8 = "127.0.0.1",
    port: u16 = 3306,
    memory_size: usize = 256 * 1024 * 1024,
    dump_path: []const u8 = "mysqlzig.dump",
    username: []const u8 = "root",
    password: []const u8 = "",
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    io_threaded: std.Io.Threaded,
    listener: ?std.Io.net.Server = null,
    accept_thread: ?std.Thread = null,
    storage: Storage = undefined,
    storage_ready: bool = false,
    storage_mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .io_threaded = .init(allocator, .{}),
        };
    }

    pub fn start(self: *Server) !void {
        if (self.running.load(.acquire)) return error.AlreadyStarted;
        const io = self.io_threaded.io();
        self.storage = try Storage.init(self.allocator, io, self.config.memory_size, self.config.dump_path);
        self.storage_ready = true;
        errdefer {
            self.storage.deinit();
            self.storage_ready = false;
        }

        var addr = try std.Io.net.IpAddress.parse(self.config.bind_host, self.config.port);
        self.listener = try addr.listen(io, .{ .reuse_address = true });
        self.running.store(true, .release);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        if (!self.running.swap(false, .acq_rel)) return;
        const io = self.io_threaded.io();
        if (self.listener) |*listener| {
            listener.deinit(io);
        }
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        self.storage_mutex.lockUncancelable(io);
        defer self.storage_mutex.unlock(io);
        self.storage.flush() catch |err| std.debug.print("mysqlzig dump flush failed: {s}\n", .{@errorName(err)});
    }

    pub fn isRunning(self: *Server) bool {
        return self.running.load(.acquire);
    }

    pub fn wait(self: *Server) void {
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.storage_ready) {
            self.storage.deinit();
            self.storage_ready = false;
        }
        self.io_threaded.deinit();
    }

    fn acceptLoop(self: *Server) void {
        const io = self.io_threaded.io();
        while (self.running.load(.acquire)) {
            var stream = (self.listener orelse return).accept(io) catch break;
            const thread = std.Thread.spawn(.{}, handleClient, .{ self, stream }) catch {
                stream.close(io);
                continue;
            };
            thread.detach();
        }
    }

    fn requestShutdownFromClient(self: *Server) void {
        const io = self.io_threaded.io();
        if (!self.running.load(.acquire)) return;
        self.storage_mutex.lockUncancelable(io);
        defer self.storage_mutex.unlock(io);
        self.storage.flush() catch |err| std.debug.print("mysqlzig dump flush failed: {s}\n", .{@errorName(err)});
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.listener) |*listener| listener.deinit(io);
    }

    fn handleClient(self: *Server, stream: std.Io.net.Stream) void {
        const io = self.io_threaded.io();
        defer stream.close(io);
        var conn = protocol.Connection.init(self.allocator, io, stream, self.config.username, self.config.password);
        defer conn.deinit();
        var prepared = std.AutoHashMap(u32, PreparedStatement).init(self.allocator);
        defer {
            var it = prepared.valueIterator();
            while (it.next()) |stmt| stmt.deinit(self.allocator);
            prepared.deinit();
        }
        var next_statement_id: u32 = 1;
        var tx_storage: ?Storage = null;
        var tx_lock_held = false;
        defer {
            if (tx_storage) |*tx| tx.deinit();
            if (tx_lock_held) self.storage_mutex.unlock(io);
        }

        conn.handshake() catch return;
        while (self.running.load(.acquire)) {
            const packet = conn.readPacket() catch return;
            defer self.allocator.free(packet.payload);
            if (packet.payload.len == 0) return;
            switch (packet.payload[0]) {
                protocol.command_quit => return,
                protocol.command_ping => conn.writeOk() catch return,
                protocol.command_shutdown => {
                    conn.writeOk() catch return;
                    self.requestShutdownFromClient();
                    return;
                },
                protocol.command_init_db => conn.writeOk() catch return,
                protocol.command_field_list => conn.writeFieldListEof() catch return,
                protocol.command_query => {
                    const query = packet.payload[1..];
                    const trimmed = std.mem.trim(u8, query, " \t\r\n;");
                    if (std.ascii.eqlIgnoreCase(trimmed, "shutdown")) {
                        conn.writeOk() catch return;
                        self.requestShutdownFromClient();
                        return;
                    }
                    if (isBegin(trimmed)) {
                        if (tx_storage != null) {
                            conn.writeErr(1064, "TransactionAlreadyStarted") catch {};
                            continue;
                        }
                        self.storage_mutex.lockUncancelable(io);
                        tx_lock_held = true;
                        tx_storage = self.storage.clone() catch |err| {
                            tx_lock_held = false;
                            self.storage_mutex.unlock(io);
                            conn.writeErr(1064, @errorName(err)) catch {};
                            continue;
                        };
                        conn.writeOk() catch return;
                        continue;
                    }
                    if (isCommit(trimmed)) {
                        if (tx_storage) |*tx| {
                            self.storage.deinit();
                            self.storage = tx.*;
                            tx_storage = null;
                            tx_lock_held = false;
                            self.storage_mutex.unlock(io);
                        }
                        conn.writeOk() catch return;
                        continue;
                    }
                    if (isRollback(trimmed)) {
                        if (tx_storage) |*tx| {
                            tx.deinit();
                            tx_storage = null;
                            tx_lock_held = false;
                            self.storage_mutex.unlock(io);
                        }
                        conn.writeOk() catch return;
                        continue;
                    }

                    const target_storage = if (tx_storage) |*tx| tx else blk: {
                        self.storage_mutex.lockUncancelable(io);
                        break :blk &self.storage;
                    };
                    const result = sql.execute(self.allocator, target_storage, query) catch |err| {
                        if (tx_storage == null) self.storage_mutex.unlock(io);
                        conn.writeErr(mysqlErrorCode(err), @errorName(err)) catch {};
                        continue;
                    };
                    if (tx_storage == null) self.storage_mutex.unlock(io);
                    defer result.deinit(self.allocator);
                    conn.writeResult(result) catch return;
                },
                protocol.command_stmt_prepare => {
                    const query = packet.payload[1..];
                    const statement_id = next_statement_id;
                    next_statement_id +%= 1;
                    var stmt = PreparedStatement.init(self.allocator, query) catch |err| {
                        conn.writeErr(1064, @errorName(err)) catch {};
                        continue;
                    };
                    prepared.put(statement_id, stmt) catch |err| {
                        stmt.deinit(self.allocator);
                        conn.writeErr(1064, @errorName(err)) catch {};
                        continue;
                    };
                    conn.writePrepareOk(statement_id, stmt.param_count) catch return;
                },
                protocol.command_stmt_execute => {
                    const exec = parseStmtExecute(self.allocator, packet.payload, &prepared) catch |err| {
                        conn.writeErr(1064, @errorName(err)) catch {};
                        continue;
                    };
                    defer self.allocator.free(exec);

                    const target_storage = if (tx_storage) |*tx| tx else blk: {
                        self.storage_mutex.lockUncancelable(io);
                        break :blk &self.storage;
                    };
                    const result = sql.execute(self.allocator, target_storage, exec) catch |err| {
                        if (tx_storage == null) self.storage_mutex.unlock(io);
                        conn.writeErr(mysqlErrorCode(err), @errorName(err)) catch {};
                        continue;
                    };
                    if (tx_storage == null) self.storage_mutex.unlock(io);
                    defer result.deinit(self.allocator);
                    conn.writeBinaryResult(result) catch return;
                },
                protocol.command_stmt_close => {
                    if (packet.payload.len >= 5) {
                        const statement_id = readLe(u32, packet.payload[1..5]);
                        if (prepared.fetchRemove(statement_id)) |entry| {
                            var stmt = entry.value;
                            stmt.deinit(self.allocator);
                        }
                    }
                },
                protocol.command_stmt_reset => {
                    resetPreparedStatement(&prepared, packet.payload) catch |err| {
                        conn.writeErr(1064, @errorName(err)) catch {};
                        continue;
                    };
                    conn.writeOk() catch return;
                },
                protocol.command_stmt_send_long_data => appendStmtLongData(self.allocator, &prepared, packet.payload) catch return,
                else => conn.writeErr(1047, "unsupported command") catch return,
            }
        }
    }
};

const PreparedStatement = struct {
    query: []u8,
    param_count: usize,
    param_types: ?[]u8 = null,
    long_data: []?std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator, query: []const u8) !PreparedStatement {
        const query_copy = try allocator.dupe(u8, query);
        errdefer allocator.free(query_copy);
        const param_count = countPlaceholders(query);
        const long_data = try allocator.alloc(?std.array_list.Managed(u8), param_count);
        @memset(long_data, null);
        return .{ .query = query_copy, .param_count = param_count, .long_data = long_data };
    }

    fn clearLongData(self: *PreparedStatement) void {
        for (self.long_data) |*slot| {
            if (slot.*) |*data| data.deinit();
            slot.* = null;
        }
    }

    fn deinit(self: *PreparedStatement, allocator: std.mem.Allocator) void {
        self.clearLongData();
        allocator.free(self.long_data);
        if (self.param_types) |types| allocator.free(types);
        allocator.free(self.query);
        self.* = undefined;
    }
};

fn appendStmtLongData(allocator: std.mem.Allocator, prepared: *std.AutoHashMap(u32, PreparedStatement), payload: []const u8) !void {
    if (payload.len < 7) return error.MalformedStmtLongData;
    const statement_id = readLe(u32, payload[1..5]);
    const param_id = readLe(u16, payload[5..7]);
    const stmt = prepared.getPtr(statement_id) orelse return error.UnknownStatement;
    if (param_id >= stmt.param_count) return error.ParameterIndexOutOfRange;
    if (stmt.long_data[param_id] == null) stmt.long_data[param_id] = std.array_list.Managed(u8).init(allocator);
    try stmt.long_data[param_id].?.appendSlice(payload[7..]);
}

fn resetPreparedStatement(prepared: *std.AutoHashMap(u32, PreparedStatement), payload: []const u8) !void {
    if (payload.len < 5) return error.MalformedStmtReset;
    const statement_id = readLe(u32, payload[1..5]);
    const stmt = prepared.getPtr(statement_id) orelse return error.UnknownStatement;
    stmt.clearLongData();
}

fn countPlaceholders(query: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    var quote: ?u8 = null;
    while (i < query.len) : (i += 1) {
        const c = query[i];
        if (quote) |q| {
            if (c == '\\' and i + 1 < query.len) {
                i += 1;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
        } else if (c == '?') {
            count += 1;
        }
    }
    return count;
}

fn parseStmtExecute(allocator: std.mem.Allocator, payload: []const u8, prepared: *std.AutoHashMap(u32, PreparedStatement)) ![]u8 {
    if (payload.len < 10) return error.MalformedStmtExecute;
    const statement_id = readLe(u32, payload[1..5]);
    const stmt = prepared.getPtr(statement_id) orelse return error.UnknownStatement;
    defer stmt.clearLongData();
    var pos: usize = 10;
    var params = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (params.items) |param| allocator.free(param);
        params.deinit();
    }

    if (stmt.param_count > 0) {
        const null_bitmap_len = (stmt.param_count + 7) / 8;
        if (pos + null_bitmap_len + 1 > payload.len) return error.MalformedStmtExecute;
        const null_bitmap = payload[pos .. pos + null_bitmap_len];
        pos += null_bitmap_len;
        const new_params_bound = payload[pos];
        pos += 1;
        const types = if (new_params_bound != 0) blk: {
            const types_len = stmt.param_count * 2;
            if (pos + types_len > payload.len) return error.MalformedStmtExecute;
            const new_types = try allocator.dupe(u8, payload[pos .. pos + types_len]);
            if (stmt.param_types) |old_types| allocator.free(old_types);
            stmt.param_types = new_types;
            pos += types_len;
            break :blk stmt.param_types.?;
        } else stmt.param_types orelse return error.MissingStmtParamTypes;

        var i: usize = 0;
        while (i < stmt.param_count) : (i += 1) {
            const is_null = ((null_bitmap[i / 8] >> @intCast(i & 7)) & 1) == 1;
            if (is_null) {
                try params.append(try allocator.dupe(u8, "NULL"));
                continue;
            }
            const typ = types[i * 2];
            const unsigned = (types[i * 2 + 1] & 0x80) != 0;
            const decoded = if (stmt.long_data[i]) |data|
                try quoteSqlString(allocator, data.items)
            else
                try decodeStmtParam(allocator, payload, &pos, typ, unsigned);
            try params.append(decoded);
        }
    }
    return interpolatePlaceholders(allocator, stmt.query, params.items);
}

fn decodeStmtParam(allocator: std.mem.Allocator, payload: []const u8, pos: *usize, typ: u8, unsigned: bool) ![]u8 {
    _ = unsigned;
    switch (typ) {
        0x00, 0xf6, 0xfd, 0xfe, 0xfc, 0xfb, 0xfa, 0xf5 => {
            const parsed = try readLenEncInt(payload, pos.*);
            pos.* = parsed.next;
            if (pos.* + parsed.value > payload.len) return error.MalformedStmtExecute;
            const bytes = payload[pos.* .. pos.* + parsed.value];
            pos.* += parsed.value;
            return quoteSqlString(allocator, bytes);
        },
        0x01 => {
            if (pos.* + 1 > payload.len) return error.MalformedStmtExecute;
            const value: i64 = payload[pos.*];
            pos.* += 1;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        0x02, 0x0d => {
            if (pos.* + 2 > payload.len) return error.MalformedStmtExecute;
            const value = readLe(i16, payload[pos.* .. pos.* + 2]);
            pos.* += 2;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        0x03, 0x09 => {
            if (pos.* + 4 > payload.len) return error.MalformedStmtExecute;
            const value = readLe(i32, payload[pos.* .. pos.* + 4]);
            pos.* += 4;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        0x08 => {
            if (pos.* + 8 > payload.len) return error.MalformedStmtExecute;
            const value = readLe(i64, payload[pos.* .. pos.* + 8]);
            pos.* += 8;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        0x04 => {
            if (pos.* + 4 > payload.len) return error.MalformedStmtExecute;
            const bits = readLe(u32, payload[pos.* .. pos.* + 4]);
            pos.* += 4;
            return std.fmt.allocPrint(allocator, "{d}", .{@as(f32, @bitCast(bits))});
        },
        0x05 => {
            if (pos.* + 8 > payload.len) return error.MalformedStmtExecute;
            const bits = readLe(u64, payload[pos.* .. pos.* + 8]);
            pos.* += 8;
            return std.fmt.allocPrint(allocator, "{d}", .{@as(f64, @bitCast(bits))});
        },
        0x06 => return allocator.dupe(u8, "NULL"),
        else => return error.UnsupportedStmtParamType,
    }
}

fn interpolatePlaceholders(allocator: std.mem.Allocator, query: []const u8, params: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var param_index: usize = 0;
    var i: usize = 0;
    var quote: ?u8 = null;
    while (i < query.len) : (i += 1) {
        const c = query[i];
        if (quote) |q| {
            try out.append(c);
            if (c == '\\' and i + 1 < query.len) {
                i += 1;
                try out.append(query[i]);
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
            try out.append(c);
        } else if (c == '?') {
            if (param_index >= params.len) return error.ParameterCountMismatch;
            try out.appendSlice(params[param_index]);
            param_index += 1;
        } else {
            try out.append(c);
        }
    }
    if (param_index != params.len) return error.ParameterCountMismatch;
    return out.toOwnedSlice();
}

fn quoteSqlString(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\'');
    for (bytes) |b| {
        if (b == '\'' or b == '\\') try out.append('\\');
        try out.append(b);
    }
    try out.append('\'');
    return out.toOwnedSlice();
}

const LenEnc = struct { value: usize, next: usize };

fn readLenEncInt(bytes: []const u8, start: usize) !LenEnc {
    if (start >= bytes.len) return error.MalformedLengthEncodedInteger;
    const first = bytes[start];
    if (first < 0xfb) return .{ .value = first, .next = start + 1 };
    if (first == 0xfc) {
        if (start + 3 > bytes.len) return error.MalformedLengthEncodedInteger;
        return .{ .value = readLe(u16, bytes[start + 1 .. start + 3]), .next = start + 3 };
    }
    if (first == 0xfd) {
        if (start + 4 > bytes.len) return error.MalformedLengthEncodedInteger;
        const value = @as(usize, bytes[start + 1]) | (@as(usize, bytes[start + 2]) << 8) | (@as(usize, bytes[start + 3]) << 16);
        return .{ .value = value, .next = start + 4 };
    }
    if (first == 0xfe) {
        if (start + 9 > bytes.len) return error.MalformedLengthEncodedInteger;
        return .{ .value = @intCast(readLe(u64, bytes[start + 1 .. start + 9])), .next = start + 9 };
    }
    return error.MalformedLengthEncodedInteger;
}

fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn isBegin(query: []const u8) bool {
    return std.ascii.eqlIgnoreCase(query, "begin") or std.ascii.eqlIgnoreCase(query, "start transaction");
}

fn isCommit(query: []const u8) bool {
    return std.ascii.eqlIgnoreCase(query, "commit");
}

fn isRollback(query: []const u8) bool {
    return std.ascii.eqlIgnoreCase(query, "rollback");
}

fn mysqlErrorCode(err: anyerror) u16 {
    return switch (err) {
        error.UniqueConstraintViolation => 1062,
        else => 1064,
    };
}

test "prepared statement long data is accumulated and cleared" {
    const allocator = std.testing.allocator;
    var prepared = std.AutoHashMap(u32, PreparedStatement).init(allocator);
    defer {
        var it = prepared.valueIterator();
        while (it.next()) |stmt| stmt.deinit(allocator);
        prepared.deinit();
    }

    try prepared.put(1, try PreparedStatement.init(allocator, "insert into game_config (content,id) values (?,?)"));
    const first_chunk = [_]u8{ 0x18, 1, 0, 0, 0, 0, 0, 'l', 'a', 'r', 'g', 'e', ' ' };
    const second_chunk = [_]u8{ 0x18, 1, 0, 0, 0, 0, 0, 'j', 's', 'o', 'n' };
    try appendStmtLongData(allocator, &prepared, &first_chunk);
    try appendStmtLongData(allocator, &prepared, &second_chunk);

    const execute_with_types = [_]u8{
        0x17, 1, 0, 0, 0, 0, 1, 0, 0, 0,
        0,    1, 0xfd, 0, 0x03, 0, 7, 0, 0, 0,
    };
    const sql_with_long_data = try parseStmtExecute(allocator, &execute_with_types, &prepared);
    defer allocator.free(sql_with_long_data);
    try std.testing.expectEqualStrings("insert into game_config (content,id) values ('large json',7)", sql_with_long_data);
    try std.testing.expect(prepared.getPtr(1).?.long_data[0] == null);

    const execute_reusing_types = [_]u8{
        0x17, 1, 0, 0, 0, 0, 1, 0, 0, 0,
        0,    0, 1,    'x', 8,    0, 0, 0,
    };
    const sql_reusing_types = try parseStmtExecute(allocator, &execute_reusing_types, &prepared);
    defer allocator.free(sql_reusing_types);
    try std.testing.expectEqualStrings("insert into game_config (content,id) values ('x',8)", sql_reusing_types);

    try appendStmtLongData(allocator, &prepared, &first_chunk);
    const reset = [_]u8{ 0x1a, 1, 0, 0, 0 };
    try resetPreparedStatement(&prepared, &reset);
    try std.testing.expect(prepared.getPtr(1).?.long_data[0] == null);
}
