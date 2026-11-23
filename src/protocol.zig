const std = @import("std");
const sql = @import("sql.zig");

pub const command_quit: u8 = 0x01;
pub const command_init_db: u8 = 0x02;
pub const command_query: u8 = 0x03;
pub const command_field_list: u8 = 0x04;
pub const command_shutdown: u8 = 0x08;
pub const command_ping: u8 = 0x0e;
pub const command_stmt_prepare: u8 = 0x16;
pub const command_stmt_execute: u8 = 0x17;
pub const command_stmt_send_long_data: u8 = 0x18;
pub const command_stmt_close: u8 = 0x19;
pub const command_stmt_reset: u8 = 0x1a;

const cap_long_password: u32 = 0x0000_0001;
const cap_long_flag: u32 = 0x0000_0004;
const cap_connect_with_db: u32 = 0x0000_0008;
const cap_protocol_41: u32 = 0x0000_0200;
const cap_transactions: u32 = 0x0000_2000;
const cap_secure_connection: u32 = 0x0000_8000;
const cap_plugin_auth: u32 = 0x0008_0000;
const cap_lenenc_client_data: u32 = 0x0020_0000;
const default_capabilities: u32 = cap_long_password | cap_long_flag | cap_connect_with_db |
    cap_protocol_41 | cap_transactions | cap_secure_connection | cap_plugin_auth |
    cap_lenenc_client_data;

const status_autocommit: u16 = 0x0002;
const charset_utf8mb4_general_ci: u8 = 45;
const server_version = "8.0.46-mysqlzig";
const auth_plugin_caching_sha2 = "caching_sha2_password";
const auth_plugin_mysql_native = "mysql_native_password";

pub const Packet = struct {
    sequence: u8,
    payload: []u8,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    sequence: u8 = 0,
    username: []const u8,
    password: []const u8,
    nonce: [20]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        username: []const u8,
        password: []const u8,
    ) Connection {
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .username = username,
            .password = password,
        };
    }

    pub fn deinit(self: *Connection) void {
        _ = self;
    }

    pub fn handshake(self: *Connection) !void {
        fillNonce(self.io, &self.nonce);
        self.sequence = 0;
        try self.writeRaw(self.sequence, try buildHandshake(self.allocator, &self.nonce));
        self.sequence +%= 1;

        const response = try self.readPacket();
        defer self.allocator.free(response.payload);
        const auth = try parseHandshakeResponse(response.payload);
        if (!std.mem.eql(u8, auth.username, self.username)) return self.writeErr(1045, "access denied");

        if (std.mem.eql(u8, auth.plugin, auth_plugin_caching_sha2)) {
            if (!verifyCachingSha2(self.password, &self.nonce, auth.auth_response)) {
                return self.writeErr(1045, "access denied");
            }
            if (self.password.len == 0) {
                try self.writeOk();
                return;
            }
            try self.writeRaw(self.sequence, &.{ 0x01, 0x03 });
            self.sequence +%= 1;
            try self.writeOk();
            return;
        }
        if (std.mem.eql(u8, auth.plugin, auth_plugin_mysql_native)) {
            if (!verifyMysqlNative(self.password, &self.nonce, auth.auth_response)) {
                return self.writeErr(1045, "access denied");
            }
            try self.writeOk();
            return;
        }
        try self.writeErr(1045, "unsupported auth plugin");
    }

    pub fn readPacket(self: *Connection) !Packet {
        var header: [4]u8 = undefined;
        try self.readExact(&header);
        const len = @as(usize, header[0]) | (@as(usize, header[1]) << 8) | (@as(usize, header[2]) << 16);
        const payload = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(payload);
        try self.readExact(payload);
        self.sequence = header[3] +% 1;
        return .{ .sequence = header[3], .payload = payload };
    }

    pub fn writeOk(self: *Connection) !void {
        try self.writeOkResult(0);
    }

    fn writeOkResult(self: *Connection, affected_rows: u64) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();
        try payload.append(0x00);
        try appendLenEncU64(&payload, affected_rows);
        try appendLenEncU64(&payload, 0);
        try appendLe(u16, &payload, 0x0002);
        try appendLe(u16, &payload, 0);
        try self.writeRaw(self.sequence, payload.items);
        self.sequence +%= 1;
    }

    pub fn writeErr(self: *Connection, code: u16, msg: []const u8) !void {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try out.append(0xff);
        try appendLe(u16, &out, code);
        try out.appendSlice("#HY000");
        try out.appendSlice(msg);
        try self.writeRaw(self.sequence, out.items);
        self.sequence +%= 1;
    }

    pub fn writeResult(self: *Connection, result: sql.Result) !void {
        self.sequence = 1;
        if (result.kind == .ok) {
            try self.writeOkResult(result.affected_rows);
            return;
        }
        var col_count = std.array_list.Managed(u8).init(self.allocator);
        defer col_count.deinit();
        try appendLenEncInt(&col_count, result.columns.len);
        try self.writeRaw(self.sequence, col_count.items);
        self.sequence +%= 1;

        for (result.columns) |col| try self.writeColumnDefinition(col);
        try self.writeEof();

        for (result.rows) |row| {
            var payload = std.array_list.Managed(u8).init(self.allocator);
            defer payload.deinit();
            for (row.values) |value| {
                if (value) |bytes| {
                    try appendLenEncString(&payload, bytes);
                } else {
                    try payload.append(0xfb);
                }
            }
            try self.writeRaw(self.sequence, payload.items);
            self.sequence +%= 1;
        }
        try self.writeEof();
    }

    pub fn writeBinaryResult(self: *Connection, result: sql.Result) !void {
        self.sequence = 1;
        if (result.kind == .ok) {
            try self.writeOkResult(result.affected_rows);
            return;
        }
        var col_count = std.array_list.Managed(u8).init(self.allocator);
        defer col_count.deinit();
        try appendLenEncInt(&col_count, result.columns.len);
        try self.writeRaw(self.sequence, col_count.items);
        self.sequence +%= 1;

        for (result.columns) |col| try self.writeColumnDefinition(col);
        try self.writeEof();

        for (result.rows) |row| {
            var payload = std.array_list.Managed(u8).init(self.allocator);
            defer payload.deinit();
            try payload.append(0x00);
            const null_bitmap_len = (result.columns.len + 7 + 2) / 8;
            const null_bitmap_start = payload.items.len;
            try payload.appendNTimes(0, null_bitmap_len);
            for (row.values, 0..) |value, i| {
                if (value) |bytes| {
                    try appendBinaryValue(&payload, result.columns[i].type_code, bytes, result.columns[i].unsigned);
                } else {
                    payload.items[null_bitmap_start + ((i + 2) / 8)] |= @as(u8, 1) << @intCast((i + 2) & 7);
                }
            }
            try self.writeRaw(self.sequence, payload.items);
            self.sequence +%= 1;
        }
        try self.writeEof();
    }

    pub fn writePrepareOk(self: *Connection, statement_id: u32, param_count: usize) !void {
        self.sequence = 1;
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();
        try payload.append(0x00);
        try appendLe(u32, &payload, statement_id);
        try appendLe(u16, &payload, 0);
        try appendLe(u16, &payload, @intCast(param_count));
        try payload.append(0);
        try appendLe(u16, &payload, 0);
        try self.writeRaw(self.sequence, payload.items);
        self.sequence +%= 1;

        if (param_count > 0) {
            var i: usize = 0;
            while (i < param_count) : (i += 1) {
                var name_buf: [16]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "param{d}", .{i + 1});
                try self.writeColumnDefinition(.{ .name = name, .type_code = 0xfd });
            }
            try self.writeEof();
        }
    }

    pub fn writeFieldListEof(self: *Connection) !void {
        self.sequence = 1;
        try self.writeEof();
    }

    fn writeColumnDefinition(self: *Connection, col: sql.Column) !void {
        var desc = std.array_list.Managed(u8).init(self.allocator);
        defer desc.deinit();
        try appendLenEncString(&desc, "def");
        try appendLenEncString(&desc, "");
        try appendLenEncString(&desc, "");
        try appendLenEncString(&desc, "");
        try appendLenEncString(&desc, col.name);
        try appendLenEncString(&desc, col.name);
        try desc.append(0x0c);
        try appendLe(u16, &desc, charset_utf8mb4_general_ci);
        try appendLe(u32, &desc, 1024);
        try desc.append(col.type_code);
        // field flags: UNSIGNED_FLAG (0x0020) lets clients decode the value as
        // an unsigned integer instead of a signed one.
        try appendLe(u16, &desc, if (col.unsigned) 0x0020 else 0);
        try desc.append(0);
        try desc.append(0);
        try self.writeRaw(self.sequence, desc.items);
        self.sequence +%= 1;
    }

    fn writeEof(self: *Connection) !void {
        var payload: [5]u8 = .{ 0xfe, 0x00, 0x00, 0x02, 0x00 };
        try self.writeRaw(self.sequence, &payload);
        self.sequence +%= 1;
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            var part = [_][]u8{buf[off..]};
            const n = try self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &part);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }

    fn writeRaw(self: *Connection, seq: u8, payload: []const u8) !void {
        if (payload.len > 0x00ff_ffff) return error.PacketTooLarge;
        var header: [4]u8 = .{
            @intCast(payload.len & 0xff),
            @intCast((payload.len >> 8) & 0xff),
            @intCast((payload.len >> 16) & 0xff),
            seq,
        };
        try self.writeAll(&header);
        try self.writeAll(payload);
    }

    fn writeAll(self: *Connection, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = try self.io.vtable.netWrite(self.io.userdata, self.stream.socket.handle, bytes[sent..], &.{""}, 0);
            if (n == 0) return error.EndOfStream;
            sent += n;
        }
    }
};

const HandshakeResponse = struct {
    capabilities: u32,
    username: []const u8,
    auth_response: []const u8,
    plugin: []const u8,
};

fn buildHandshake(allocator: std.mem.Allocator, nonce: *const [20]u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append(0x0a);
    try out.appendSlice(server_version);
    try out.append(0);
    try appendLe(u32, &out, 1);
    try out.appendSlice(nonce[0..8]);
    try out.append(0);
    try appendLe(u16, &out, @intCast(default_capabilities & 0xffff));
    try out.append(charset_utf8mb4_general_ci);
    try appendLe(u16, &out, status_autocommit);
    try appendLe(u16, &out, @intCast((default_capabilities >> 16) & 0xffff));
    try out.append(21);
    try out.appendNTimes(0, 10);
    try out.appendSlice(nonce[8..20]);
    try out.append(0);
    try out.appendSlice(auth_plugin_caching_sha2);
    try out.append(0);
    return out.toOwnedSlice();
}

fn parseHandshakeResponse(payload: []const u8) !HandshakeResponse {
    // Fixed 4.1 response prefix: capability flags, max packet size, charset,
    // and 23 reserved bytes. A username follows, so anything shorter is invalid.
    if (payload.len < 32) return error.MalformedHandshakeResponse;
    const capabilities = readLe(u32, payload[0..4]);
    var cursor: usize = 32;
    const username_end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedHandshakeResponse;
    const username = payload[cursor..username_end];
    cursor = username_end + 1;

    var auth_response: []const u8 = "";
    if ((capabilities & cap_lenenc_client_data) != 0) {
        const parsed = try readLenEncInt(payload, cursor);
        cursor = parsed.next;
        if (cursor + parsed.value > payload.len) return error.MalformedHandshakeResponse;
        auth_response = payload[cursor .. cursor + parsed.value];
        cursor += parsed.value;
    } else if ((capabilities & cap_secure_connection) != 0) {
        if (cursor >= payload.len) return error.MalformedHandshakeResponse;
        const len = payload[cursor];
        cursor += 1;
        if (cursor + len > payload.len) return error.MalformedHandshakeResponse;
        auth_response = payload[cursor .. cursor + len];
        cursor += len;
    } else {
        const end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedHandshakeResponse;
        auth_response = payload[cursor..end];
        cursor = end + 1;
    }
    if ((capabilities & cap_connect_with_db) != 0 and cursor < payload.len) {
        const db_end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse return error.MalformedHandshakeResponse;
        cursor = db_end + 1;
    }
    var plugin: []const u8 = auth_plugin_caching_sha2;
    if ((capabilities & cap_plugin_auth) != 0 and cursor < payload.len) {
        const end = std.mem.indexOfScalarPos(u8, payload, cursor, 0) orelse payload.len;
        plugin = payload[cursor..end];
    }
    return .{ .capabilities = capabilities, .username = username, .auth_response = auth_response, .plugin = plugin };
}

fn fillNonce(io: std.Io, nonce: *[20]u8) void {
    io.random(nonce);
    for (nonce) |*b| {
        if (b.* == 0) b.* = 1;
    }
}

fn verifyCachingSha2(password: []const u8, nonce: *const [20]u8, token: []const u8) bool {
    if (password.len == 0) return true;
    if (token.len != 32) return false;
    // MySQL's fast-auth scramble is
    //   SHA256(password) XOR SHA256(SHA256(password) + nonce).
    // Note the inner mix uses the *second* hash; hashing once more yields a
    // token that no real client ever sends.
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &s1, .{});
    std.crypto.hash.sha2.Sha256.hash(&s1, &s2, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&s2);
    h.update(nonce);
    var scramble: [32]u8 = undefined;
    h.final(&scramble);
    var expected: [32]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = s1[i] ^ scramble[i];
    return std.crypto.timing_safe.eql([32]u8, expected, token[0..32].*);
}

fn verifyMysqlNative(password: []const u8, nonce: *const [20]u8, token: []const u8) bool {
    if (password.len == 0) return true;
    if (token.len != 20) return false;
    var s1: [20]u8 = undefined;
    var s2: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(password, &s1, .{});
    std.crypto.hash.Sha1.hash(&s1, &s2, .{});
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(nonce);
    h.update(&s2);
    var scramble: [20]u8 = undefined;
    h.final(&scramble);
    var expected: [20]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = s1[i] ^ scramble[i];
    return std.crypto.timing_safe.eql([20]u8, expected, token[0..20].*);
}

fn appendLe(comptime T: type, out: *std.array_list.Managed(u8), value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(&buf);
}

fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn appendLenEncInt(out: *std.array_list.Managed(u8), value: usize) !void {
    return appendLenEncU64(out, value);
}

fn appendLenEncU64(out: *std.array_list.Managed(u8), value: u64) !void {
    if (value < 251) {
        try out.append(@intCast(value));
    } else if (value <= 0xffff) {
        try out.append(0xfc);
        try appendLe(u16, out, @intCast(value));
    } else if (value <= 0x00ff_ffff) {
        try out.append(0xfd);
        try out.append(@intCast(value & 0xff));
        try out.append(@intCast((value >> 8) & 0xff));
        try out.append(@intCast((value >> 16) & 0xff));
    } else {
        try out.append(0xfe);
        try appendLe(u64, out, @intCast(value));
    }
}

fn appendLenEncString(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try appendLenEncInt(out, bytes.len);
    try out.appendSlice(bytes);
}

fn appendBinaryValue(out: *std.array_list.Managed(u8), type_code: u8, bytes: []const u8, unsigned: bool) !void {
    switch (type_code) {
        0x01 => {
            // TINY: MySQL writes a single byte; an unsigned column stores up to 255.
            if (unsigned) {
                try out.append(try std.fmt.parseInt(u8, bytes, 10));
            } else {
                try out.append(@bitCast(try std.fmt.parseInt(i8, bytes, 10)));
            }
        },
        0x02, 0x0d => {
            if (unsigned) {
                try appendLe(u16, out, try std.fmt.parseInt(u16, bytes, 10));
            } else {
                try appendLe(i16, out, try std.fmt.parseInt(i16, bytes, 10));
            }
        },
        0x03, 0x09 => {
            if (unsigned) {
                try appendLe(u32, out, try std.fmt.parseInt(u32, bytes, 10));
            } else {
                try appendLe(i32, out, try std.fmt.parseInt(i32, bytes, 10));
            }
        },
        0x08 => {
            if (unsigned) {
                try appendLe(u64, out, try std.fmt.parseInt(u64, bytes, 10));
            } else {
                try appendLe(i64, out, try std.fmt.parseInt(i64, bytes, 10));
            }
        },
        0x04 => {
            const value = try std.fmt.parseFloat(f32, bytes);
            try appendLe(u32, out, @bitCast(value));
        },
        0x05 => {
            const value = try std.fmt.parseFloat(f64, bytes);
            try appendLe(u64, out, @bitCast(value));
        },
        0x0a => try appendBinaryDate(out, bytes),
        0x07, 0x0c => try appendBinaryDateTime(out, bytes),
        0x0b => try appendBinaryTime(out, bytes),
        else => try appendLenEncString(out, bytes),
    }
}

// The binary protocol sends temporal values as length-prefixed binary structs,
// not text. Clients (go-sql-driver, mysql-connector, ...) decode them with
// fixed layouts, so text-encoding dates desynchronizes their row parsers.
fn appendBinaryDate(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    const parts = parseTemporalParts(bytes) orelse {
        try out.append(0);
        return;
    };
    try out.append(4);
    try appendLe(u16, out, parts.year);
    try out.append(parts.month);
    try out.append(parts.day);
}

fn appendBinaryDateTime(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    const parts = parseTemporalParts(bytes) orelse {
        try out.append(0);
        return;
    };
    try out.append(7);
    try appendLe(u16, out, parts.year);
    try out.append(parts.month);
    try out.append(parts.day);
    try out.append(parts.hour);
    try out.append(parts.minute);
    try out.append(parts.second);
}

fn appendBinaryTime(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    if (bytes.len != 8) {
        try out.append(0);
        return;
    }
    const hour = std.fmt.parseInt(u8, bytes[0..2], 10) catch {
        try out.append(0);
        return;
    };
    const minute = std.fmt.parseInt(u8, bytes[3..5], 10) catch {
        try out.append(0);
        return;
    };
    const second = std.fmt.parseInt(u8, bytes[6..8], 10) catch {
        try out.append(0);
        return;
    };
    try out.append(8);
    try out.append(0); // is_negative
    try appendLe(u32, out, 0); // days
    try out.append(hour);
    try out.append(minute);
    try out.append(second);
}

const TemporalParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

fn parseTemporalParts(bytes: []const u8) ?TemporalParts {
    if (bytes.len != 10 and bytes.len != 19) return null;
    const year = std.fmt.parseInt(u16, bytes[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, bytes[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, bytes[8..10], 10) catch return null;
    var parts = TemporalParts{ .year = year, .month = month, .day = day };
    if (bytes.len == 19) {
        parts.hour = std.fmt.parseInt(u8, bytes[11..13], 10) catch return null;
        parts.minute = std.fmt.parseInt(u8, bytes[14..16], 10) catch return null;
        parts.second = std.fmt.parseInt(u8, bytes[17..19], 10) catch return null;
    }
    return parts;
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

test "caching_sha2_password verifier accepts a real client token" {
    // Captured from mysql 9.3.0 (Oracle client) during a fast-auth handshake:
    // nonce and the 32-byte token it sent for password "secret".
    const nonce: [20]u8 = .{
        0x61, 0xb3, 0x05, 0xf2, 0xe4, 0x2e, 0xb2, 0x31, 0xf7, 0x43,
        0x2c, 0xee, 0xf5, 0x32, 0xeb, 0x1c, 0x5b, 0x70, 0x8d, 0xee,
    };
    const token: [32]u8 = .{
        0x52, 0x2f, 0x60, 0x79, 0x2d, 0x3a, 0x1b, 0xe3, 0x63, 0x0b, 0x66, 0xa1, 0x6d, 0xc0, 0x22, 0xaa,
        0x5a, 0x79, 0x15, 0x5a, 0x7e, 0xa8, 0x48, 0x58, 0xa4, 0xe7, 0x43, 0xac, 0x69, 0x4f, 0xf8, 0x0c,
    };
    try std.testing.expect(verifyCachingSha2("secret", &nonce, &token));
    try std.testing.expect(!verifyCachingSha2("other", &nonce, &token));

    // The same formula must work for any nonce; generate one and round-trip it.
    const round_nonce: [20]u8 = "abcdefghijklmnopqrst".*;
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("secret", &s1, .{});
    std.crypto.hash.sha2.Sha256.hash(&s1, &s2, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&s2);
    h.update(&round_nonce);
    var scramble: [32]u8 = undefined;
    h.final(&scramble);
    var round_token: [32]u8 = undefined;
    for (&round_token, 0..) |*b, i| b.* = s1[i] ^ scramble[i];
    try std.testing.expect(verifyCachingSha2("secret", &round_nonce, &round_token));
}

test "minimal handshake response without plugin auth parses" {
    // 32-byte fixed prefix + "r" + NUL username + NUL empty auth response.
    var payload = [_]u8{0} ** 35;
    payload[8] = charset_utf8mb4_general_ci;
    payload[32] = 'r';
    payload[33] = 0;
    payload[34] = 0;
    const parsed = try parseHandshakeResponse(&payload);
    try std.testing.expectEqualStrings("r", parsed.username);
    try std.testing.expectEqualStrings("", parsed.auth_response);
    try std.testing.expectEqualStrings(auth_plugin_caching_sha2, parsed.plugin);
}

test "binary protocol encodes temporal values as binary structs" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try appendBinaryValue(&out, 0x0a, "2026-11-23", false);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0xea, 0x07, 11, 23 }, out.items);

    out.clearRetainingCapacity();
    try appendBinaryValue(&out, 0x0c, "2026-11-23 09:52:07", false);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0xea, 0x07, 11, 23, 9, 52, 7 }, out.items);

    out.clearRetainingCapacity();
    try appendBinaryValue(&out, 0x0b, "12:34:56", false);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0, 0, 12, 34, 56 }, out.items);

    // Unsigned integers must not be truncated to their signed width.
    out.clearRetainingCapacity();
    try appendBinaryValue(&out, 0x01, "200", true);
    try std.testing.expectEqualSlices(u8, &.{200}, out.items);
    out.clearRetainingCapacity();
    try appendBinaryValue(&out, 0x03, "4294967295", true);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, out.items);
    out.clearRetainingCapacity();
    try appendBinaryValue(&out, 0x08, "18446744073709551615", true);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, out.items);
}
