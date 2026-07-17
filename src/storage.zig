const std = @import("std");
const builtin = @import("builtin");

const magic = "MZIGDUMP";

pub const RowId = u64;

pub const Value = union(enum) {
    null,
    int: i64,
    bool: bool,
    real: f64,
    text: []const u8,
    decimal: []const u8,
    blob: []const u8,
    date: []const u8,
    datetime: []const u8,
    time: []const u8,
    year: i32,
    json: []const u8,
};

pub const Column = struct {
    name: []const u8,
    kind: Kind,
    unsigned: bool = false,
    nullable: bool = true,
    default_value: ?Value = null,
    auto_increment: bool = false,
    primary: bool = false,
    unique: bool = false,

    pub const Kind = union(enum) {
        tiny_int,
        small_int,
        medium_int,
        int,
        big_int,
        text,
        tiny_text,
        medium_text,
        long_text,
        null,
        bool,
        real,
        decimal,
        bit: usize,
        char: usize,
        binary: usize,
        varchar: usize,
        varbinary: usize,
        blob,
        tiny_blob,
        medium_blob,
        long_blob,
        date,
        datetime,
        time,
        year,
        json,
        enum_values: []const []const u8,
        set_values: []const []const u8,
    };
};

pub const CheckConstraint = struct {
    name: []const u8,
    expr_sql: []const u8,
};

pub const Row = struct {
    id: RowId,
    deleted: bool = false,
    values: []Value,
};

pub const Index = struct {
    name: []const u8,
    columns: []usize,
    unique: bool = false,
    primary: bool = false,
    buckets: std.AutoHashMap(u64, std.array_list.Managed(RowId)),

    fn init(allocator: std.mem.Allocator, name: []const u8, columns: []const usize, unique: bool, primary: bool) !Index {
        const stored_columns = try allocator.dupe(usize, columns);
        return .{
            .name = name,
            .columns = stored_columns,
            .unique = unique,
            .primary = primary,
            .buckets = std.AutoHashMap(u64, std.array_list.Managed(RowId)).init(allocator),
        };
    }

    fn deinit(self: *Index) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |bucket| bucket.deinit();
        self.buckets.allocator.free(self.columns);
        self.buckets.deinit();
    }
};

pub const Table = struct {
    name: []const u8,
    columns: []Column,
    checks: std.array_list.Managed(CheckConstraint),
    next_row_id: RowId = 1,
    rows: std.array_list.Managed(Row),
    indexes: std.array_list.Managed(Index),
    // Per-table arena owning every string/byte slice referenced by this table
    // (name, column names, values, check/index names). Cloning a single table
    // and swapping it in reclaims the old arena, so in-place mutation cannot
    // leak. `undefined` for short-lived virtual tables that never persist bytes.
    arena: std.heap.ArenaAllocator,
    // Maps row id -> index into `rows.items` for O(1) point lookups. Indices are
    // stable because rows are soft-deleted (never physically removed) and only
    // appended, so the map only needs maintenance on append/truncate/clone.
    row_index: std.AutoHashMap(RowId, usize),
};

pub const Assignment = struct {
    column_index: usize,
    value: Value,
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dump_path: []const u8,
    tables: std.array_list.Managed(Table),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dump_path: []const u8) !Storage {
        var storage = Storage{
            .allocator = allocator,
            .io = io,
            .dump_path = dump_path,
            .tables = std.array_list.Managed(Table).init(allocator),
        };
        errdefer storage.deinit();
        try storage.restore();
        return storage;
    }

    pub fn deinit(self: *Storage) void {
        for (self.tables.items) |*table| self.deinitTable(table);
        self.tables.deinit();
        self.* = undefined;
    }

    pub fn clone(self: *Storage) !Storage {
        var out = Storage{
            .allocator = self.allocator,
            .io = self.io,
            .dump_path = self.dump_path,
            .tables = std.array_list.Managed(Table).init(self.allocator),
        };
        errdefer out.deinit();
        for (self.tables.items) |table| {
            var cloned = try self.cloneTableValue(table);
            errdefer self.deinitTable(&cloned);
            try out.tables.append(cloned);
        }
        return out;
    }

    /// Produces a fully independent deep copy of `source` (its own arena, row
    /// arrays, indexes and row-index map). Used both by whole-database clone
    /// (DDL) and by the per-statement single-table snapshot (DML). Each piece is
    /// tracked by its own errdefer so a mid-way failure frees everything exactly
    /// once; on success ownership is transferred into the returned Table.
    pub fn cloneTableValue(self: *Storage, source: Table) !Table {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const name = try persistBytes(a, source.name);

        const columns = try self.allocator.alloc(Column, source.columns.len);
        errdefer self.allocator.free(columns);
        for (source.columns, 0..) |col, i| columns[i] = try self.persistColumn(a, col);

        var checks = std.array_list.Managed(CheckConstraint).init(self.allocator);
        errdefer checks.deinit();
        for (source.checks.items) |check| {
            try checks.append(.{
                .name = try persistBytes(a, check.name),
                .expr_sql = try persistBytes(a, check.expr_sql),
            });
        }

        var indexes = std.array_list.Managed(Index).init(self.allocator);
        errdefer {
            for (indexes.items) |*index| index.deinit();
            indexes.deinit();
        }
        for (source.indexes.items) |index| {
            try indexes.append(try Index.init(self.allocator, try persistBytes(a, index.name), index.columns, index.unique, index.primary));
        }

        var rows = std.array_list.Managed(Row).init(self.allocator);
        errdefer {
            for (rows.items) |row| self.allocator.free(row.values);
            rows.deinit();
        }
        var row_index = std.AutoHashMap(RowId, usize).init(self.allocator);
        errdefer row_index.deinit();
        for (source.rows.items) |row| {
            const values = try self.allocator.alloc(Value, row.values.len);
            errdefer self.allocator.free(values);
            for (row.values, 0..) |value, i| values[i] = try persistValue(a, value);
            try rows.append(.{ .id = row.id, .deleted = row.deleted, .values = values });
            try row_index.put(row.id, rows.items.len - 1);
        }

        var table = Table{
            .name = name,
            .columns = columns,
            .checks = checks,
            .next_row_id = source.next_row_id,
            .rows = rows,
            .indexes = indexes,
            .arena = arena,
            .row_index = row_index,
        };
        try rebuildIndexes(&table);
        return table;
    }

    pub fn findTableIndex(self: *Storage, name: []const u8) ?usize {
        for (self.tables.items, 0..) |*table, i| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) return i;
        }
        return null;
    }

    /// Public wrapper so the executor can free a snapshot/working table.
    pub fn destroyTable(self: *Storage, table: *Table) void {
        self.deinitTable(table);
    }

    pub fn flush(self: *Storage) !void {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try out.appendSlice(magic);
        try appendLe(u32, &out, @intCast(self.tables.items.len));
        for (self.tables.items) |table| {
            try appendString(&out, table.name);
            try appendLe(u64, &out, table.next_row_id);
            try appendLe(u32, &out, @intCast(table.columns.len));
            for (table.columns) |col| {
                try appendString(&out, col.name);
                try appendKind(&out, col.kind);
                try out.append(@intFromBool(col.unsigned));
                try out.append(@intFromBool(col.nullable));
                try out.append(@intFromBool(col.auto_increment));
                try out.append(@intFromBool(col.primary));
                try out.append(@intFromBool(col.unique));
                if (col.default_value) |value| {
                    try out.append(1);
                    try appendValue(&out, value);
                } else {
                    try out.append(0);
                }
            }
            try appendLe(u32, &out, @intCast(table.checks.items.len));
            for (table.checks.items) |check| {
                try appendString(&out, check.name);
                try appendString(&out, check.expr_sql);
            }
            try appendLe(u32, &out, @intCast(table.indexes.items.len));
            for (table.indexes.items) |index| {
                try appendString(&out, index.name);
                try appendLe(u32, &out, @intCast(index.columns.len));
                for (index.columns) |column_index| try appendLe(u32, &out, @intCast(column_index));
                try out.append(@intFromBool(index.unique));
                try out.append(@intFromBool(index.primary));
            }
            try appendLe(u32, &out, @intCast(table.rows.items.len));
            for (table.rows.items) |row| {
                try appendLe(u64, &out, row.id);
                try out.append(@intFromBool(row.deleted));
                for (row.values) |value| try appendValue(&out, value);
            }
        }

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out.items, &hash, .{});
        var final = std.array_list.Managed(u8).init(self.allocator);
        defer final.deinit();
        try final.appendSlice(&hash);
        try final.appendSlice(out.items);

        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.dump_path});
        defer self.allocator.free(tmp);
        var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, final.items);
        try std.Io.Dir.rename(.cwd(), tmp, .cwd(), self.dump_path, self.io);
    }

    pub fn createTable(self: *Storage, name: []const u8, columns: []const Column) !void {
        if (self.findTable(name) != null) return error.TableExists;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const table_name = try persistBytes(a, name);
        const stored_columns = try self.allocator.alloc(Column, columns.len);
        errdefer self.allocator.free(stored_columns);
        for (columns, 0..) |col, i| {
            stored_columns[i] = try self.persistColumn(a, col);
        }
        try self.tables.append(.{
            .name = table_name,
            .columns = stored_columns,
            .checks = std.array_list.Managed(CheckConstraint).init(self.allocator),
            .rows = std.array_list.Managed(Row).init(self.allocator),
            .indexes = std.array_list.Managed(Index).init(self.allocator),
            .arena = arena,
            .row_index = std.AutoHashMap(RowId, usize).init(self.allocator),
        });
    }

    pub fn dropTable(self: *Storage, name: []const u8) !void {
        for (self.tables.items, 0..) |*table, i| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) {
                self.deinitTable(table);
                _ = self.tables.orderedRemove(i);
                return;
            }
        }
        return error.UnknownTable;
    }

    pub fn truncateTable(self: *Storage, table: *Table) void {
        for (table.rows.items) |row| self.allocator.free(row.values);
        table.rows.clearRetainingCapacity();
        table.row_index.clearRetainingCapacity();
        table.next_row_id = 1;
        for (table.indexes.items) |*index| clearIndexBuckets(index);
    }

    pub fn createIndex(self: *Storage, table: *Table, name: []const u8, column_index: usize) !void {
        return self.createIndexEx(table, name, &.{column_index}, false, false);
    }

    pub fn createIndexEx(self: *Storage, table: *Table, name: []const u8, columns: []const usize, unique: bool, primary: bool) !void {
        if (findIndexInTable(table, name) != null) return error.IndexExists;
        if (columns.len == 0) return error.EmptyIndex;
        const index_name = try persistBytes(table.arena.allocator(), name);
        var index = try Index.init(self.allocator, index_name, columns, unique or primary, primary);
        errdefer index.deinit();
        for (table.rows.items) |row| {
            if (!row.deleted) try indexAdd(&index, table, row.values, row.id);
        }
        try table.indexes.append(index);
    }

    pub fn dropIndex(self: *Storage, table: *Table, name: []const u8) !void {
        _ = self;
        for (table.indexes.items, 0..) |*index, i| {
            if (std.ascii.eqlIgnoreCase(index.name, name)) {
                index.deinit();
                _ = table.indexes.orderedRemove(i);
                return;
            }
        }
        return error.UnknownIndex;
    }

    pub fn addCheck(self: *Storage, table: *Table, name: []const u8, expr_sql: []const u8) !void {
        _ = self;
        if (findCheckInTable(table, name) != null) return error.CheckExists;
        const a = table.arena.allocator();
        try table.checks.append(.{
            .name = try persistBytes(a, name),
            .expr_sql = try persistBytes(a, expr_sql),
        });
    }

    pub fn dropCheck(self: *Storage, table: *Table, name: []const u8) !void {
        _ = self;
        for (table.checks.items, 0..) |check, i| {
            if (std.ascii.eqlIgnoreCase(check.name, name)) {
                _ = table.checks.orderedRemove(i);
                return;
            }
        }
        return error.UnknownCheck;
    }

    pub fn insertRow(self: *Storage, table: *Table, input: []const Value) !RowId {
        if (input.len != table.columns.len) return error.ColumnCountMismatch;
        const a = table.arena.allocator();
        const values = try self.allocator.alloc(Value, input.len);
        errdefer self.allocator.free(values);
        for (input, 0..) |value, i| values[i] = try persistValue(a, value);
        try checkUniqueIndexes(table, values, null);
        const id = table.next_row_id;
        try table.row_index.put(id, table.rows.items.len);
        errdefer _ = table.row_index.remove(id);
        table.next_row_id += 1;
        try table.rows.append(.{ .id = id, .values = values });
        const row = &table.rows.items[table.rows.items.len - 1];
        for (table.indexes.items) |*index| try indexAdd(index, table, row.values, row.id);
        return id;
    }

    pub fn updateRow(self: *Storage, table: *Table, row: *Row, assignments: []const Assignment) !void {
        if (row.deleted) return;
        const a = table.arena.allocator();
        const new_values = try self.allocator.alloc(Value, row.values.len);
        errdefer self.allocator.free(new_values);
        @memcpy(new_values, row.values);
        for (assignments) |assignment| {
            new_values[assignment.column_index] = try persistValue(a, assignment.value);
        }
        try checkUniqueIndexes(table, new_values, row.id);
        for (table.indexes.items) |*index| {
            if (assignmentTouchesIndex(assignments, index)) indexRemove(index, row.values, row.id);
        }
        const old_values = row.values;
        row.values = new_values;
        for (table.indexes.items) |*index| {
            if (assignmentTouchesIndex(assignments, index)) try indexAdd(index, table, row.values, row.id);
        }
        self.allocator.free(old_values);
    }

    pub fn deleteRow(self: *Storage, table: *Table, row: *Row) void {
        _ = self;
        if (row.deleted) return;
        for (table.indexes.items) |*index| indexRemove(index, row.values, row.id);
        row.deleted = true;
    }

    pub fn indexedLookup(self: *Storage, allocator: std.mem.Allocator, table: *Table, column_index: usize, value: Value) !?[]RowId {
        _ = self;
        for (table.indexes.items) |*index| {
            if (index.columns.len == 1 and index.columns[0] == column_index) {
                var matches = std.array_list.Managed(RowId).init(allocator);
                defer matches.deinit();
                if (index.buckets.get(indexHashProjectedValues(&.{value}))) |bucket| {
                    for (bucket.items) |row_id| {
                        const row = findRowById(table, row_id) orelse continue;
                        if (!row.deleted and valueEqual(row.values[column_index], value)) try matches.append(row_id);
                    }
                }
                return @as(?[]RowId, try matches.toOwnedSlice());
            }
        }
        return null;
    }

    pub fn findConflictRow(table: *const Table, values: []const Value) ?RowId {
        for (table.indexes.items) |index| {
            if (!index.unique and !index.primary) continue;
            if (index.primary) {
                for (index.columns) |column_index| if (values[column_index] == .null) return null;
            } else if (indexContainsNull(index, values)) {
                continue;
            }
            const hash = indexHashValues(index, values);
            if (index.buckets.get(hash)) |bucket| {
                for (bucket.items) |row_id| {
                    const row = findRowByIdConst(table, row_id) orelse continue;
                    if (!row.deleted and indexValuesEqual(index, row.values, values)) return row_id;
                }
            }
        }
        return null;
    }

    pub fn findRowById(table: *Table, id: RowId) ?*Row {
        if (table.row_index.get(id)) |idx| {
            if (idx < table.rows.items.len and table.rows.items[idx].id == id) return &table.rows.items[idx];
        }
        // Fallback keeps correctness even if the map is empty/stale (e.g. virtual
        // tables that only append via appendVirtualRow without map maintenance).
        for (table.rows.items) |*row| {
            if (row.id == id) return row;
        }
        return null;
    }

    pub fn findTable(self: *Storage, name: []const u8) ?*Table {
        for (self.tables.items) |*table| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
        }
        return null;
    }

    pub fn columnIndex(table: *const Table, name: []const u8) ?usize {
        for (table.columns, 0..) |col, i| {
            if (std.ascii.eqlIgnoreCase(col.name, name)) return i;
        }
        return null;
    }

    pub fn addColumn(self: *Storage, table: *Table, column: Column, fill_value: Value) !void {
        const a = table.arena.allocator();
        const new_columns = try self.allocator.alloc(Column, table.columns.len + 1);
        @memcpy(new_columns[0..table.columns.len], table.columns);
        new_columns[table.columns.len] = try self.persistColumn(a, column);
        self.allocator.free(table.columns);
        table.columns = new_columns;
        for (table.rows.items) |*row| {
            const old_values = row.values;
            const new_values = try self.allocator.alloc(Value, old_values.len + 1);
            @memcpy(new_values[0..old_values.len], old_values);
            new_values[old_values.len] = try persistValue(a, fill_value);
            self.allocator.free(old_values);
            row.values = new_values;
        }
        try rebuildIndexes(table);
    }

    pub fn renameColumn(self: *Storage, table: *Table, column_index: usize, new_name: []const u8) !void {
        _ = self;
        if (Storage.columnIndex(table, new_name) != null) return error.ColumnExists;
        table.columns[column_index].name = try persistBytes(table.arena.allocator(), new_name);
    }

    pub fn replaceColumn(self: *Storage, table: *Table, column_index: usize, column: Column, values: []const Value) !void {
        if (values.len != table.rows.items.len) return error.ColumnCountMismatch;
        const a = table.arena.allocator();
        self.deinitKind(table.columns[column_index].kind);
        table.columns[column_index] = try self.persistColumn(a, column);
        for (table.rows.items, 0..) |*row, i| {
            row.values[column_index] = try persistValue(a, values[i]);
        }
        try rebuildIndexes(table);
    }

    pub fn dropColumn(self: *Storage, table: *Table, column_index: usize) !void {
        for (table.indexes.items) |index| if (indexContainsColumn(index, column_index)) return error.IndexDependsOnColumn;
        self.deinitKind(table.columns[column_index].kind);
        const new_columns = try self.allocator.alloc(Column, table.columns.len - 1);
        var ci: usize = 0;
        for (table.columns, 0..) |col, i| {
            if (i == column_index) continue;
            new_columns[ci] = col;
            ci += 1;
        }
        self.allocator.free(table.columns);
        table.columns = new_columns;
        for (table.indexes.items) |*index| {
            for (index.columns) |*idx| {
                if (idx.* > column_index) idx.* -= 1;
            }
        }
        for (table.rows.items) |*row| {
            const old_values = row.values;
            const new_values = try self.allocator.alloc(Value, old_values.len - 1);
            var vi: usize = 0;
            for (old_values, 0..) |value, i| {
                if (i == column_index) continue;
                new_values[vi] = value;
                vi += 1;
            }
            self.allocator.free(old_values);
            row.values = new_values;
        }
        try rebuildIndexes(table);
    }

    pub fn renameTable(self: *Storage, table: *Table, new_name: []const u8) !void {
        if (self.findTable(new_name) != null) return error.TableExists;
        table.name = try persistBytes(table.arena.allocator(), new_name);
    }

    pub fn findIndex(table: *Table, name: []const u8) ?*Index {
        return findIndexInTable(table, name);
    }

    fn persistColumn(self: *Storage, arena: std.mem.Allocator, col: Column) !Column {
        return .{
            .name = try persistBytes(arena, col.name),
            .kind = try self.persistKind(arena, col.kind),
            .unsigned = col.unsigned,
            .nullable = col.nullable,
            .default_value = if (col.default_value) |value| try persistValue(arena, value) else null,
            .auto_increment = col.auto_increment,
            .primary = col.primary,
            .unique = col.unique,
        };
    }

    fn persistKind(self: *Storage, arena: std.mem.Allocator, kind: Column.Kind) !Column.Kind {
        return switch (kind) {
            .enum_values => |values| .{ .enum_values = try self.persistStringList(arena, values) },
            .set_values => |values| .{ .set_values = try self.persistStringList(arena, values) },
            else => kind,
        };
    }

    fn persistStringList(self: *Storage, arena: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
        const out = try self.allocator.alloc([]const u8, values.len);
        for (values, 0..) |value, i| out[i] = try persistBytes(arena, value);
        return out;
    }

    fn restore(self: *Storage) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.dump_path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (bytes.len < 32 + magic.len + 4) return error.BadDump;
        const expected: [32]u8 = bytes[0..32].*;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[32..], &actual, .{});
        if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return error.BadDumpChecksum;
        var cur: usize = 32;
        if (!std.mem.eql(u8, bytes[cur .. cur + magic.len], magic)) return error.BadDump;
        cur += magic.len;
        const table_count = readLe(u32, bytes[cur .. cur + 4]);
        cur += 4;

        var ti: usize = 0;
        while (ti < table_count) : (ti += 1) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const name = try persistBytes(a, try readString(bytes, &cur));
            const next_row_id = readLe(u64, bytes[cur .. cur + 8]);
            cur += 8;
            const col_count = readLe(u32, bytes[cur .. cur + 4]);
            cur += 4;
            const columns = try self.allocator.alloc(Column, col_count);
            errdefer self.allocator.free(columns);
            for (columns) |*col| {
                col.name = try persistBytes(a, try readString(bytes, &cur));
                col.kind = try self.readKind(a, bytes, &cur);
                if (cur + 6 > bytes.len) return error.BadDump;
                col.unsigned = bytes[cur] != 0;
                cur += 1;
                col.nullable = bytes[cur] != 0;
                cur += 1;
                col.auto_increment = bytes[cur] != 0;
                cur += 1;
                col.primary = bytes[cur] != 0;
                cur += 1;
                col.unique = bytes[cur] != 0;
                cur += 1;
                if (bytes[cur] != 0) {
                    cur += 1;
                    col.default_value = try self.readPersistedValue(a, bytes, &cur);
                } else {
                    cur += 1;
                    col.default_value = null;
                }
            }
            var checks = std.array_list.Managed(CheckConstraint).init(self.allocator);
            errdefer checks.deinit();
            const check_count = readLe(u32, bytes[cur .. cur + 4]);
            cur += 4;
            var ci: usize = 0;
            while (ci < check_count) : (ci += 1) {
                try checks.append(.{
                    .name = try persistBytes(a, try readString(bytes, &cur)),
                    .expr_sql = try persistBytes(a, try readString(bytes, &cur)),
                });
            }

            var indexes = std.array_list.Managed(Index).init(self.allocator);
            errdefer {
                for (indexes.items) |*index| index.deinit();
                indexes.deinit();
            }
            const index_count = readLe(u32, bytes[cur .. cur + 4]);
            cur += 4;
            var ii: usize = 0;
            while (ii < index_count) : (ii += 1) {
                const index_name = try persistBytes(a, try readString(bytes, &cur));
                const index_column_count = readLe(u32, bytes[cur .. cur + 4]);
                cur += 4;
                const index_columns = try self.allocator.alloc(usize, index_column_count);
                defer self.allocator.free(index_columns);
                for (index_columns) |*column_index| {
                    if (cur + 4 > bytes.len) return error.BadDump;
                    column_index.* = readLe(u32, bytes[cur .. cur + 4]);
                    cur += 4;
                    if (column_index.* >= columns.len) return error.BadDump;
                }
                if (cur + 2 > bytes.len) return error.BadDump;
                const unique = bytes[cur] != 0;
                cur += 1;
                const primary = bytes[cur] != 0;
                cur += 1;
                try indexes.append(try Index.init(self.allocator, index_name, index_columns, unique, primary));
            }

            var rows = std.array_list.Managed(Row).init(self.allocator);
            errdefer {
                for (rows.items) |row| self.allocator.free(row.values);
                rows.deinit();
            }
            var row_index = std.AutoHashMap(RowId, usize).init(self.allocator);
            errdefer row_index.deinit();
            const row_count = readLe(u32, bytes[cur .. cur + 4]);
            cur += 4;
            var ri: usize = 0;
            while (ri < row_count) : (ri += 1) {
                const id = readLe(u64, bytes[cur .. cur + 8]);
                cur += 8;
                if (cur >= bytes.len) return error.BadDump;
                const deleted = bytes[cur] != 0;
                cur += 1;
                const values = try self.allocator.alloc(Value, col_count);
                errdefer self.allocator.free(values);
                for (values) |*value| value.* = try self.readPersistedValue(a, bytes, &cur);
                try rows.append(.{ .id = id, .deleted = deleted, .values = values });
                try row_index.put(id, rows.items.len - 1);
            }

            var table = Table{
                .name = name,
                .columns = columns,
                .checks = checks,
                .next_row_id = next_row_id,
                .rows = rows,
                .indexes = indexes,
                .arena = arena,
                .row_index = row_index,
            };
            try rebuildIndexes(&table);
            try self.tables.append(table);
        }
    }

    fn readPersistedValue(self: *Storage, arena: std.mem.Allocator, bytes: []const u8, cur: *usize) !Value {
        _ = self;
        if (cur.* >= bytes.len) return error.BadDump;
        const tag = bytes[cur.*];
        cur.* += 1;
        return switch (tag) {
            0 => .null,
            1 => blk: {
                if (cur.* + 8 > bytes.len) return error.BadDump;
                const v = readLe(i64, bytes[cur.* .. cur.* + 8]);
                cur.* += 8;
                break :blk .{ .int = v };
            },
            2 => .{ .text = try persistBytes(arena, try readString(bytes, cur)) },
            3 => blk: {
                if (cur.* >= bytes.len) return error.BadDump;
                const v = bytes[cur.*] != 0;
                cur.* += 1;
                break :blk .{ .bool = v };
            },
            4 => blk: {
                if (cur.* + 8 > bytes.len) return error.BadDump;
                const raw = readLe(u64, bytes[cur.* .. cur.* + 8]);
                cur.* += 8;
                break :blk .{ .real = @bitCast(raw) };
            },
            5 => .{ .decimal = try persistBytes(arena, try readString(bytes, cur)) },
            6 => .{ .blob = try persistBytes(arena, try readString(bytes, cur)) },
            7 => .{ .date = try persistBytes(arena, try readString(bytes, cur)) },
            8 => .{ .datetime = try persistBytes(arena, try readString(bytes, cur)) },
            9 => .{ .time = try persistBytes(arena, try readString(bytes, cur)) },
            10 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const v = readLe(i32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .year = v };
            },
            11 => .{ .json = try persistBytes(arena, try readString(bytes, cur)) },
            else => error.BadDump,
        };
    }

    fn deinitTable(self: *Storage, table: *Table) void {
        for (table.columns) |col| self.deinitKind(col.kind);
        self.allocator.free(table.columns);
        table.checks.deinit();
        for (table.rows.items) |row| self.allocator.free(row.values);
        table.rows.deinit();
        for (table.indexes.items) |*index| index.deinit();
        table.indexes.deinit();
        table.row_index.deinit();
        table.arena.deinit();
    }

    fn deinitKind(self: *Storage, kind: Column.Kind) void {
        switch (kind) {
            .enum_values => |values| self.allocator.free(values),
            .set_values => |values| self.allocator.free(values),
            else => {},
        }
    }

    fn readKind(self: *Storage, arena: std.mem.Allocator, bytes: []const u8, cur: *usize) !Column.Kind {
        if (cur.* >= bytes.len) return error.BadDump;
        const tag = bytes[cur.*];
        cur.* += 1;
        return switch (tag) {
            1 => .tiny_int,
            2 => .small_int,
            3 => .medium_int,
            4 => .int,
            5 => .big_int,
            6 => .text,
            7 => .tiny_text,
            8 => .medium_text,
            9 => .long_text,
            10 => .null,
            11 => .bool,
            12 => .real,
            13 => .decimal,
            14 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .bit = len };
            },
            15 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .char = len };
            },
            16 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .binary = len };
            },
            17 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .varchar = len };
            },
            18 => blk: {
                if (cur.* + 4 > bytes.len) return error.BadDump;
                const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
                cur.* += 4;
                break :blk .{ .varbinary = len };
            },
            19 => .blob,
            20 => .tiny_blob,
            21 => .medium_blob,
            22 => .long_blob,
            23 => .date,
            24 => .datetime,
            25 => .time,
            26 => .year,
            27 => .json,
            28 => .{ .enum_values = try self.readStringList(arena, bytes, cur) },
            29 => .{ .set_values = try self.readStringList(arena, bytes, cur) },
            else => error.BadDump,
        };
    }

    fn readStringList(self: *Storage, arena: std.mem.Allocator, bytes: []const u8, cur: *usize) ![]const []const u8 {
        if (cur.* + 4 > bytes.len) return error.BadDump;
        const count = readLe(u32, bytes[cur.* .. cur.* + 4]);
        cur.* += 4;
        const out = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(out);
        for (out) |*item| item.* = try persistBytes(arena, try readString(bytes, cur));
        return out;
    }
};

fn persistBytes(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return arena.dupe(u8, bytes);
}

fn persistValue(arena: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .null => .null,
        .int => |v| .{ .int = v },
        .bool => |v| .{ .bool = v },
        .real => |v| .{ .real = v },
        .text => |v| .{ .text = try persistBytes(arena, v) },
        .decimal => |v| .{ .decimal = try persistBytes(arena, v) },
        .blob => |v| .{ .blob = try persistBytes(arena, v) },
        .date => |v| .{ .date = try persistBytes(arena, v) },
        .datetime => |v| .{ .datetime = try persistBytes(arena, v) },
        .time => |v| .{ .time = try persistBytes(arena, v) },
        .year => |v| .{ .year = v },
        .json => |v| .{ .json = try persistBytes(arena, v) },
    };
}

fn findIndexInTable(table: *Table, name: []const u8) ?*Index {
    for (table.indexes.items) |*index| {
        if (std.ascii.eqlIgnoreCase(index.name, name)) return index;
    }
    return null;
}

fn findCheckInTable(table: *Table, name: []const u8) ?*CheckConstraint {
    for (table.checks.items) |*check| {
        if (std.ascii.eqlIgnoreCase(check.name, name)) return check;
    }
    return null;
}

fn rebuildIndexes(table: *Table) !void {
    for (table.indexes.items) |*index| {
        clearIndexBuckets(index);
        for (table.rows.items) |row| {
            if (!row.deleted) try indexAdd(index, table, row.values, row.id);
        }
    }
}

fn clearIndexBuckets(index: *Index) void {
    var it = index.buckets.valueIterator();
    while (it.next()) |bucket| bucket.deinit();
    index.buckets.clearRetainingCapacity();
}

fn assignmentTouches(assignments: []const Assignment, column_index: usize) bool {
    for (assignments) |assignment| {
        if (assignment.column_index == column_index) return true;
    }
    return false;
}

fn assignmentTouchesIndex(assignments: []const Assignment, index: *const Index) bool {
    for (index.columns) |column_index| {
        if (assignmentTouches(assignments, column_index)) return true;
    }
    return false;
}

fn indexContainsColumn(index: Index, column_index: usize) bool {
    for (index.columns) |idx| if (idx == column_index) return true;
    return false;
}

fn indexContainsNull(index: Index, values: []const Value) bool {
    for (index.columns) |column_index| {
        if (values[column_index] == .null) return true;
    }
    return false;
}

fn indexValuesEqual(index: Index, left: []const Value, right: []const Value) bool {
    for (index.columns) |column_index| {
        if (!valueEqual(left[column_index], right[column_index])) return false;
    }
    return true;
}

fn valueEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null => right == .null,
        .int => |value| right == .int and right.int == value,
        .bool => |value| right == .bool and right.bool == value,
        .real => |value| right == .real and @as(u64, @bitCast(right.real)) == @as(u64, @bitCast(value)),
        .text => |value| right == .text and std.mem.eql(u8, right.text, value),
        .decimal => |value| right == .decimal and std.mem.eql(u8, right.decimal, value),
        .blob => |value| right == .blob and std.mem.eql(u8, right.blob, value),
        .date => |value| right == .date and std.mem.eql(u8, right.date, value),
        .datetime => |value| right == .datetime and std.mem.eql(u8, right.datetime, value),
        .time => |value| right == .time and std.mem.eql(u8, right.time, value),
        .year => |value| right == .year and right.year == value,
        .json => |value| right == .json and std.mem.eql(u8, right.json, value),
    };
}

fn findRowByIdConst(table: *const Table, id: RowId) ?*const Row {
    if (table.row_index.get(id)) |idx| {
        if (idx < table.rows.items.len and table.rows.items[idx].id == id) return &table.rows.items[idx];
    }
    for (table.rows.items) |*row| {
        if (row.id == id) return row;
    }
    return null;
}

fn checkUniqueIndexes(table: *const Table, values: []const Value, updating_row_id: ?RowId) !void {
    for (table.indexes.items) |index| {
        if (!index.unique and !index.primary) continue;
        if (index.primary) {
            for (index.columns) |column_index| {
                if (values[column_index] == .null) return error.NotNullViolation;
            }
        } else if (indexContainsNull(index, values)) {
            continue;
        }
        if (index.buckets.get(indexHashValues(index, values))) |bucket| {
            for (bucket.items) |row_id| {
                if (updating_row_id != null and row_id == updating_row_id.?) continue;
                const row = findRowByIdConst(table, row_id) orelse continue;
                if (!row.deleted and indexValuesEqual(index, row.values, values)) return error.UniqueConstraintViolation;
            }
        }
    }
}

fn indexAdd(index: *Index, table: *const Table, values: []const Value, row_id: RowId) !void {
    if (index.primary and indexContainsNull(index.*, values)) return error.NotNullViolation;
    const hash = indexHashValues(index.*, values);
    const result = try index.buckets.getOrPut(hash);
    if (!result.found_existing) result.value_ptr.* = std.array_list.Managed(RowId).init(index.buckets.allocator);
    if (index.unique and (index.primary or !indexContainsNull(index.*, values))) {
        for (result.value_ptr.items) |existing_id| {
            if (existing_id == row_id) continue;
            const existing = findRowByIdConst(table, existing_id) orelse continue;
            if (!existing.deleted and indexValuesEqual(index.*, existing.values, values)) return error.UniqueConstraintViolation;
        }
    }
    try result.value_ptr.append(row_id);
}

fn indexRemove(index: *Index, values: []const Value, row_id: RowId) void {
    const hash = indexHashValues(index.*, values);
    if (index.buckets.getPtr(hash)) |bucket| {
        for (bucket.items, 0..) |id, i| {
            if (id == row_id) {
                _ = bucket.swapRemove(i);
                break;
            }
        }
    }
}

fn indexHashValues(index: Index, values: []const Value) u64 {
    var hasher = std.hash.Wyhash.init(0x9e37_79b9_7f4a_7c15);
    for (index.columns) |column_index| updateIndexHash(&hasher, values[column_index]);
    return hasher.final();
}

fn indexHashProjectedValues(values: []const Value) u64 {
    var hasher = std.hash.Wyhash.init(0x9e37_79b9_7f4a_7c15);
    for (values) |value| updateIndexHash(&hasher, value);
    return hasher.final();
}

fn updateIndexHash(hasher: *std.hash.Wyhash, value: Value) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, valueHash(value), .little);
    hasher.update(&buf);
}

pub fn valueHash(value: Value) u64 {
    var hasher = std.hash.Wyhash.init(0);
    switch (value) {
        .null => hasher.update(&.{0}),
        .int => |v| {
            hasher.update(&.{1});
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, v, .little);
            hasher.update(&buf);
        },
        .text => |v| hashTaggedBytes(&hasher, 2, v),
        .bool => |v| {
            hasher.update(&.{ 3, @intFromBool(v) });
        },
        .real => |v| {
            hasher.update(&.{4});
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(v), .little);
            hasher.update(&buf);
        },
        .decimal => |v| hashTaggedBytes(&hasher, 5, v),
        .blob => |v| hashTaggedBytes(&hasher, 6, v),
        .date => |v| hashTaggedBytes(&hasher, 7, v),
        .datetime => |v| hashTaggedBytes(&hasher, 8, v),
        .time => |v| hashTaggedBytes(&hasher, 9, v),
        .year => |v| {
            hasher.update(&.{10});
            var buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &buf, v, .little);
            hasher.update(&buf);
        },
        .json => |v| hashTaggedBytes(&hasher, 11, v),
    }
    return hasher.final();
}

fn hashTaggedBytes(hasher: *std.hash.Wyhash, tag: u8, bytes: []const u8) void {
    hasher.update(&.{tag});
    hasher.update(bytes);
}

fn appendKind(out: *std.array_list.Managed(u8), kind: Column.Kind) !void {
    switch (kind) {
        .tiny_int => try out.append(1),
        .small_int => try out.append(2),
        .medium_int => try out.append(3),
        .int => try out.append(4),
        .big_int => try out.append(5),
        .text => try out.append(6),
        .tiny_text => try out.append(7),
        .medium_text => try out.append(8),
        .long_text => try out.append(9),
        .null => try out.append(10),
        .bool => try out.append(11),
        .real => try out.append(12),
        .decimal => try out.append(13),
        .bit => |len| {
            try out.append(14);
            try appendLe(u32, out, @intCast(len));
        },
        .char => |len| {
            try out.append(15);
            try appendLe(u32, out, @intCast(len));
        },
        .binary => |len| {
            try out.append(16);
            try appendLe(u32, out, @intCast(len));
        },
        .varchar => |len| {
            try out.append(17);
            try appendLe(u32, out, @intCast(len));
        },
        .varbinary => |len| {
            try out.append(18);
            try appendLe(u32, out, @intCast(len));
        },
        .blob => try out.append(19),
        .tiny_blob => try out.append(20),
        .medium_blob => try out.append(21),
        .long_blob => try out.append(22),
        .date => try out.append(23),
        .datetime => try out.append(24),
        .time => try out.append(25),
        .year => try out.append(26),
        .json => try out.append(27),
        .enum_values => |values| {
            try out.append(28);
            try appendStringList(out, values);
        },
        .set_values => |values| {
            try out.append(29);
            try appendStringList(out, values);
        },
    }
}

fn appendStringList(out: *std.array_list.Managed(u8), values: []const []const u8) !void {
    try appendLe(u32, out, @intCast(values.len));
    for (values) |value| try appendString(out, value);
}

fn appendValue(out: *std.array_list.Managed(u8), value: Value) !void {
    switch (value) {
        .null => try out.append(0),
        .int => |v| {
            try out.append(1);
            try appendLe(i64, out, v);
        },
        .text => |v| {
            try out.append(2);
            try appendString(out, v);
        },
        .bool => |v| {
            try out.append(3);
            try out.append(@intFromBool(v));
        },
        .real => |v| {
            try out.append(4);
            try appendLe(u64, out, @bitCast(v));
        },
        .decimal => |v| {
            try out.append(5);
            try appendString(out, v);
        },
        .blob => |v| {
            try out.append(6);
            try appendString(out, v);
        },
        .date => |v| {
            try out.append(7);
            try appendString(out, v);
        },
        .datetime => |v| {
            try out.append(8);
            try appendString(out, v);
        },
        .time => |v| {
            try out.append(9);
            try appendString(out, v);
        },
        .year => |v| {
            try out.append(10);
            try appendLe(i32, out, v);
        },
        .json => |v| {
            try out.append(11);
            try appendString(out, v);
        },
    }
}

fn appendLe(comptime T: type, out: *std.array_list.Managed(u8), value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(&buf);
}

fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn appendString(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try appendLe(u32, out, @intCast(bytes.len));
    try out.appendSlice(bytes);
}

fn readString(bytes: []const u8, cur: *usize) ![]const u8 {
    if (cur.* + 4 > bytes.len) return error.BadDump;
    const len = readLe(u32, bytes[cur.* .. cur.* + 4]);
    cur.* += 4;
    if (cur.* + len > bytes.len) return error.BadDump;
    const out = bytes[cur.* .. cur.* + len];
    cur.* += len;
    return out;
}

test "storage types truncate drop restore" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var storage = try Storage.init(allocator, io, path);
        defer storage.deinit();
        try storage.createTable("typed", &.{
            .{ .name = "id", .kind = .int },
            .{ .name = "ok", .kind = .bool },
            .{ .name = "score", .kind = .real },
            .{ .name = "price", .kind = .decimal },
            .{ .name = "name", .kind = .{ .varchar = 8 } },
            .{ .name = "payload", .kind = .blob },
            .{ .name = "d", .kind = .date },
            .{ .name = "ts", .kind = .datetime },
        });
        const table = storage.findTable("typed").?;
        try storage.createIndex(table, "idx_id", 0);
        _ = try storage.insertRow(table, &.{
            .{ .int = 1 },
            .{ .bool = true },
            .{ .real = 1.5 },
            .{ .decimal = "12.30" },
            .{ .text = "alpha" },
            .{ .blob = "bytes" },
            .{ .date = "2026-07-07" },
            .{ .datetime = "2026-07-07 12:00:00" },
        });
        const first_hits = (try storage.indexedLookup(allocator, table, 0, .{ .int = 1 })).?;
        defer allocator.free(first_hits);
        try std.testing.expectEqual(@as(usize, 1), first_hits.len);
        try storage.flush();
    }
    {
        var storage = try Storage.init(allocator, io, path);
        defer storage.deinit();
        const table = storage.findTable("typed").?;
        try std.testing.expectEqual(@as(usize, 8), table.columns.len);
        const restored_hits = (try storage.indexedLookup(allocator, table, 0, .{ .int = 1 })).?;
        defer allocator.free(restored_hits);
        try std.testing.expectEqual(@as(usize, 1), restored_hits.len);
        storage.truncateTable(table);
        try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
        try storage.dropTable("typed");
        try std.testing.expect(storage.findTable("typed") == null);
    }
}

test "unique indexes allow nulls and compare full keys inside hash buckets" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-unique-index-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var storage = try Storage.init(allocator, io, path);
    defer storage.deinit();
    try storage.createTable("items", &.{
        .{ .name = "id", .kind = .int, .nullable = false },
        .{ .name = "code", .kind = .int },
    });
    const table = storage.findTable("items").?;
    try storage.createIndexEx(table, "uq_code", &.{1}, true, false);

    _ = try storage.insertRow(table, &.{ .{ .int = 1 }, .null });
    _ = try storage.insertRow(table, &.{ .{ .int = 2 }, .null });

    const first_id = try storage.insertRow(table, &.{ .{ .int = 3 }, .{ .int = 10 } });
    const index = &table.indexes.items[0];
    const collision_hash = indexHashProjectedValues(&.{.{ .int = 20 }});
    const collision = try index.buckets.getOrPut(collision_hash);
    if (!collision.found_existing) collision.value_ptr.* = std.array_list.Managed(RowId).init(allocator);
    var has_first = false;
    for (collision.value_ptr.items) |row_id| has_first = has_first or row_id == first_id;
    if (!has_first) try collision.value_ptr.append(first_id);

    try std.testing.expect(Storage.findConflictRow(table, &.{ .{ .int = 4 }, .{ .int = 20 } }) == null);
    const second_id = try storage.insertRow(table, &.{ .{ .int = 4 }, .{ .int = 20 } });
    try std.testing.expectEqual(second_id, Storage.findConflictRow(table, &.{ .{ .int = 5 }, .{ .int = 20 } }).?);

    const hits = (try storage.indexedLookup(allocator, table, 1, .{ .int = 20 })).?;
    defer allocator.free(hits);
    try std.testing.expectEqualSlices(RowId, &.{second_id}, hits);
}
