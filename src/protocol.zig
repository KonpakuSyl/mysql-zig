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
        var payload: [7]u8 = .{ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
        try self.writeRaw(self.sequence, &payload);
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
            try self.writeOk();
            return;
        }
        var col_count = std.array_list.Managed(u8).init(self.allocator);
        defer col_count.deinit();
        try appendLenEncInt(&col_count, result.columns.len);
        try self.writeRaw(self.sequence, col_count.items);
        self.sequence +%= 1;

        for (result.columns) |col| {
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
            try appendLe(u16, &desc, 0);
            try desc.append(0);
            try desc.append(0);
            try self.writeRaw(self.sequence, desc.items);
            self.sequence +%= 1;
        }

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
            try self.writeOk();
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
                    try appendBinaryValue(&payload, result.columns[i].type_code, bytes);
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
        try appendLe(u16, &desc, 0);
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
    if (payload.len < 36) return error.MalformedHandshakeResponse;
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
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    var s3: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &s1, .{});
    std.crypto.hash.sha2.Sha256.hash(&s1, &s2, .{});
    std.crypto.hash.sha2.Sha256.hash(&s2, &s3, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&s3);
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

fn appendBinaryValue(out: *std.array_list.Managed(u8), type_code: u8, bytes: []const u8) !void {
    switch (type_code) {
        0x01 => try out.append(@intCast(try std.fmt.parseInt(i8, bytes, 10))),
        0x02, 0x0d => {
            const value = try std.fmt.parseInt(i16, bytes, 10);
            try appendLe(i16, out, value);
        },
        0x03, 0x09 => {
            const value = try std.fmt.parseInt(i32, bytes, 10);
            try appendLe(i32, out, value);
        },
        0x08 => {
            const value = try std.fmt.parseInt(i64, bytes, 10);
            try appendLe(i64, out, value);
        },
        0x04 => {
            const value = try std.fmt.parseFloat(f32, bytes);
            try appendLe(u32, out, @bitCast(value));
        },
        0x05 => {
            const value = try std.fmt.parseFloat(f64, bytes);
            try appendLe(u64, out, @bitCast(value));
        },
        else => try appendLenEncString(out, bytes),
    }
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

test "caching_sha2_password verifier accepts generated token" {
    const password = "secret";
    const nonce: [20]u8 = "abcdefghijklmnopqrst".*;
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    var s3: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &s1, .{});
    std.crypto.hash.sha2.Sha256.hash(&s1, &s2, .{});
    std.crypto.hash.sha2.Sha256.hash(&s2, &s3, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&s3);
    h.update(&nonce);
    var scramble: [32]u8 = undefined;
    h.final(&scramble);
    var token: [32]u8 = undefined;
    for (&token, 0..) |*b, i| b.* = s1[i] ^ scramble[i];
    try std.testing.expect(verifyCachingSha2(password, &nonce, &token));
}
