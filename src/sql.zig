const std = @import("std");
const storage = @import("storage.zig");

pub const Column = struct {
    name: []const u8,
    type_code: u8,
};

pub const Row = struct {
    values: []?[]const u8,
};

pub const Result = struct {
    kind: enum { ok, rows },
    columns: []Column = &.{},
    rows: []Row = &.{},
    affected_rows: u64 = 0,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            for (row.values) |value| if (value) |bytes| allocator.free(bytes);
            allocator.free(row.values);
        }
        allocator.free(self.rows);
        allocator.free(self.columns);
    }
};

const CompareOp = enum { eq, ne, lt, lte, gt, gte };

const BinaryOp = enum { @"and", @"or", add, sub, mul, div };
const UnaryOp = enum { not, neg };

const Expr = union(enum) {
    literal: storage.Value,
    column: []const u8,
    unary: struct { op: UnaryOp, expr: *const Expr },
    binary: struct { op: BinaryOp, left: *const Expr, right: *const Expr },
    compare: struct { op: CompareOp, left: *const Expr, right: *const Expr },
    like: struct { expr: *const Expr, pattern: *const Expr, negated: bool = false },
    in_list: struct { expr: *const Expr, values: []const *const Expr, negated: bool = false },
    is_null: struct { expr: *const Expr, negated: bool },
    case_expr: struct { operand: *const Expr, cases: []const CaseArm, else_expr: ?*const Expr },
    call: struct { name: []const u8, args: []const *const Expr },
    aggregate: struct { name: []const u8, arg: ?*const Expr },
};

const CaseArm = struct {
    when: *const Expr,
    then: *const Expr,
};

const Condition = union(enum) {
    compare: struct { column: []const u8, op: CompareOp, value: storage.Value },
    like: struct { column: []const u8, pattern: []const u8 },
    in_list: struct { column: []const u8, values: []const storage.Value },
    is_null: struct { column: []const u8, negated: bool },
};

const SelectExpr = union(enum) {
    star,
    expr: *const Expr,
};

const SelectItem = struct {
    expr: SelectExpr,
    alias: ?[]const u8 = null,
};

const OrderBy = struct {
    expr: *const Expr,
    desc: bool = false,
};

const JoinKind = enum { inner, left };

const JoinSpec = struct {
    kind: JoinKind,
    table: []const u8,
    alias: ?[]const u8 = null,
    on: *const Expr,
};

const Limit = struct {
    offset: usize = 0,
    count: usize,
};

const InsertStmtMode = enum { normal, ignore, replace };

const AssignmentAst = struct {
    column: []const u8,
    expr: *const Expr,
};

const CreateColumn = struct {
    column: storage.Column,
};

const CreateIndexDef = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool = false,
    primary: bool = false,
};

const CreateCheckDef = struct {
    name: []const u8,
    expr_sql: []const u8,
};

const AlterAction = union(enum) {
    add_column: CreateColumn,
    drop_column: []const u8,
    rename_column: struct { old_name: []const u8, new_name: []const u8 },
    modify_column: CreateColumn,
    change_column: struct { old_name: []const u8, column: CreateColumn },
    rename_to: []const u8,
    add_index: CreateIndexDef,
    add_check: CreateCheckDef,
    drop_index: []const u8,
    drop_primary_key,
    drop_check: []const u8,
};

const SelectStmt = struct {
    items: []const SelectItem,
    table: ?[]const u8,
    table_alias: ?[]const u8 = null,
    join: ?JoinSpec = null,
    conditions: []const Condition,
    where_expr: ?*const Expr = null,
    group_by: []const *const Expr = &.{},
    having: ?*const Expr = null,
    order_by: []const OrderBy = &.{},
    limit: ?Limit,
};

const InsertStmt = struct {
    table: []const u8,
    columns: ?[]const []const u8,
    rows: []const []const storage.Value,
    mode: InsertStmtMode = .normal,
    on_duplicate: []const AssignmentAst = &.{},
};

const UpdateStmt = struct {
    table: []const u8,
    assignments: []const AssignmentAst,
    conditions: []const Condition,
    where_expr: ?*const Expr = null,
};

const DeleteStmt = struct {
    table: []const u8,
    conditions: []const Condition,
    where_expr: ?*const Expr = null,
    limit: ?Limit = null,
};

const Statement = union(enum) {
    ok,
    select: SelectStmt,
    insert: InsertStmt,
    update: UpdateStmt,
    delete: DeleteStmt,
    create_table: struct { name: []const u8, columns: []const CreateColumn, indexes: []const CreateIndexDef, checks: []const CreateCheckDef, if_not_exists: bool = false },
    create_index: struct { name: []const u8, table: []const u8, columns: []const []const u8, unique: bool = false, primary: bool = false },
    drop_index: struct { name: []const u8, table: []const u8 },
    alter_table: struct { table: []const u8, action: AlterAction },
    drop_table: struct { name: []const u8, if_exists: bool = false },
    truncate_table: []const u8,
    describe: []const u8,
    show_create_table: []const u8,
    show_tables: struct { pattern: ?[]const u8 = null, full: bool = false },
    show_databases,
    show_columns: struct { table: []const u8, full: bool = false, field: ?[]const u8 = null },
    show_index: struct { table: []const u8, key_name: ?[]const u8 = null },
    show_variables: ?[]const u8,
    show_create_database: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, db: *storage.Storage, query: []const u8) !Result {
    const trimmed = trimSemi(std.mem.trim(u8, query, " \t\r\n"));
    if (trimmed.len == 0) return ok();
    if (startsWith(trimmed, "select @@version")) return singleColumnRows(allocator, "@@version", &.{"8.0.46-mysqlzig"});
    if (startsWith(trimmed, "select database()")) return singleColumnRows(allocator, "DATABASE()", &.{"main"});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try tokenize(scratch, trimmed);
    var parser = Parser{ .tokens = tokens, .allocator = scratch };
    const stmt = try parser.parseStatement();

    return switch (stmt) {
        .ok => ok(),
        .select => |s| selectQuery(allocator, db, s),
        .insert => |s| insertInto(db, s),
        .update => |s| updateRows(allocator, db, s),
        .delete => |s| deleteFrom(allocator, db, s),
        .create_table => |s| createTable(db, s.name, s.columns, s.indexes, s.checks, s.if_not_exists),
        .create_index => |s| createIndex(db, s),
        .drop_index => |s| dropIndex(db, s),
        .alter_table => |s| alterTable(db, s.table, s.action),
        .drop_table => |s| dropTable(db, s.name, s.if_exists),
        .truncate_table => |name| truncateTable(db, name),
        .describe => |name| describeTable(allocator, db, name, null),
        .show_create_table => |name| showCreateTable(allocator, db, name),
        .show_tables => |s| showTables(allocator, db, s.pattern, s.full),
        .show_databases => singleColumnRows(allocator, "Database", &.{"main"}),
        .show_columns => |s| if (s.full) showFullColumns(allocator, db, s.table, s.field) else describeTable(allocator, db, s.table, s.field),
        .show_index => |s| showIndex(allocator, db, s.table, s.key_name),
        .show_variables => |pattern| showVariables(allocator, pattern),
        .show_create_database => |name| showCreateDatabase(allocator, name),
    };
}

fn ok() Result {
    return .{ .kind = .ok };
}

fn okAffected(affected_rows: u64) Result {
    return .{ .kind = .ok, .affected_rows = affected_rows };
}

fn createTable(db: *storage.Storage, name: []const u8, parsed: []const CreateColumn, indexes: []const CreateIndexDef, checks: []const CreateCheckDef, if_not_exists: bool) !Result {
    if (db.findTable(name) != null) {
        if (if_not_exists) return ok();
        return error.TableExists;
    }
    var cols = std.array_list.Managed(storage.Column).init(db.allocator);
    defer cols.deinit();
    for (parsed) |col| try cols.append(col.column);
    for (indexes) |index| {
        for (index.columns) |index_column| {
            for (cols.items) |*col| {
                if (std.ascii.eqlIgnoreCase(col.name, index_column)) {
                    if (index.primary) {
                        col.primary = true;
                        col.unique = true;
                        col.nullable = false;
                    } else if (index.unique and index.columns.len == 1) {
                        col.unique = true;
                    }
                }
            }
        }
    }
    try db.createTable(name, cols.items);
    const table = db.findTable(name).?;
    for (parsed) |col| {
        if (col.column.primary) {
            const idx = storage.Storage.columnIndex(table, col.column.name) orelse return error.UnknownColumn;
            try db.createIndexEx(table, "PRIMARY", &.{idx}, true, true);
        } else if (col.column.unique) {
            const idx = storage.Storage.columnIndex(table, col.column.name) orelse return error.UnknownColumn;
            const index_name = try std.fmt.allocPrint(db.allocator, "{s}_unique", .{col.column.name});
            defer db.allocator.free(index_name);
            try db.createIndexEx(table, index_name, &.{idx}, true, false);
        }
    }
    for (indexes) |index| {
        const cols_idx = try resolveIndexColumns(db.allocator, table, index.columns);
        defer db.allocator.free(cols_idx);
        try db.createIndexEx(table, index.name, cols_idx, index.unique or index.primary, index.primary);
    }
    for (checks) |check| {
        try db.addCheck(table, check.name, check.expr_sql);
    }
    return ok();
}

fn createIndex(db: *storage.Storage, stmt: anytype) !Result {
    const table = db.findTable(stmt.table) orelse return error.UnknownTable;
    const column_indexes = try resolveIndexColumns(db.allocator, table, stmt.columns);
    defer db.allocator.free(column_indexes);
    try db.createIndexEx(table, stmt.name, column_indexes, stmt.unique or stmt.primary, stmt.primary);
    return ok();
}

fn resolveIndexColumns(allocator: std.mem.Allocator, table: *const storage.Table, columns: []const []const u8) ![]usize {
    if (columns.len == 0) return error.EmptyIndex;
    const out = try allocator.alloc(usize, columns.len);
    errdefer allocator.free(out);
    for (columns, 0..) |column, i| {
        out[i] = storage.Storage.columnIndex(table, column) orelse return error.UnknownColumn;
    }
    return out;
}

fn dropIndex(db: *storage.Storage, stmt: anytype) !Result {
    const table = db.findTable(stmt.table) orelse return error.UnknownTable;
    try db.dropIndex(table, stmt.name);
    return ok();
}

fn dropTable(db: *storage.Storage, name: []const u8, if_exists: bool) !Result {
    if (if_exists and db.findTable(name) == null) return ok();
    try db.dropTable(name);
    return ok();
}

fn truncateTable(db: *storage.Storage, name: []const u8) !Result {
    const table = db.findTable(name) orelse return error.UnknownTable;
    db.truncateTable(table);
    return ok();
}

fn defaultForColumn(allocator: std.mem.Allocator, table: *const storage.Table, col: storage.Column) !storage.Value {
    if (col.auto_increment) return .{ .int = @intCast(table.next_row_id) };
    if (col.default_value) |default_value| {
        if (defaultValueFunction(col.kind, default_value)) |computed| return computed;
        return try coerceColumn(allocator, col, default_value);
    }
    if (!col.nullable or col.primary) return error.NotNullViolation;
    return .null;
}

fn defaultValueFunction(kind: storage.Column.Kind, value: storage.Value) ?storage.Value {
    const text = valueText(value) orelse return null;
    if (std.ascii.eqlIgnoreCase(text, "current_timestamp") or std.ascii.eqlIgnoreCase(text, "now")) {
        return switch (kind) {
            .datetime => .{ .datetime = "2026-07-07 00:00:00" },
            .date => .{ .date = "2026-07-07" },
            else => null,
        };
    }
    if (std.ascii.eqlIgnoreCase(text, "current_date")) {
        return switch (kind) {
            .date => .{ .date = "2026-07-07" },
            .datetime => .{ .datetime = "2026-07-07 00:00:00" },
            else => null,
        };
    }
    return null;
}

fn fillAndValidateInsert(allocator: std.mem.Allocator, table: *const storage.Table, values: []storage.Value, provided: []const bool) !void {
    for (table.columns, 0..) |col, i| {
        if (!provided[i] or (col.auto_increment and values[i] == .null)) {
            values[i] = try defaultForColumn(allocator, table, col);
        } else {
            values[i] = try coerceColumn(allocator, col, values[i]);
        }
        if ((!col.nullable or col.primary) and values[i] == .null) return error.NotNullViolation;
    }
    try validateChecksForValues(allocator, table, values);
}

fn alterTable(db: *storage.Storage, table_name: []const u8, action: AlterAction) !Result {
    const table = db.findTable(table_name) orelse return error.UnknownTable;
    switch (action) {
        .add_column => |col| {
            const fill = try defaultForColumn(db.allocator, table, col.column);
            try db.addColumn(table, col.column, fill);
            try validateAllRows(db.allocator, table);
            if (col.column.primary or col.column.unique) {
                const idx = storage.Storage.columnIndex(table, col.column.name) orelse return error.UnknownColumn;
                try db.createIndexEx(table, if (col.column.primary) "PRIMARY" else col.column.name, &.{idx}, true, col.column.primary);
            }
        },
        .drop_column => |name| {
            const idx = storage.Storage.columnIndex(table, name) orelse return error.UnknownColumn;
            try db.dropColumn(table, idx);
        },
        .rename_column => |rename| {
            const idx = storage.Storage.columnIndex(table, rename.old_name) orelse return error.UnknownColumn;
            try db.renameColumn(table, idx, rename.new_name);
        },
        .modify_column => |col| try modifyColumn(db, table, col.column.name, col.column),
        .change_column => |change| try modifyColumn(db, table, change.old_name, change.column.column),
        .rename_to => |new_name| try db.renameTable(table, new_name),
        .add_index => |index| {
            const cols_idx = try resolveIndexColumns(db.allocator, table, index.columns);
            defer db.allocator.free(cols_idx);
            try db.createIndexEx(table, index.name, cols_idx, index.unique or index.primary, index.primary);
        },
        .add_check => |check| {
            try validateCheckForRows(db.allocator, table, check.expr_sql);
            try db.addCheck(table, check.name, check.expr_sql);
        },
        .drop_index => |name| try db.dropIndex(table, name),
        .drop_primary_key => try dropPrimaryKey(table, db),
        .drop_check => |name| try db.dropCheck(table, name),
    }
    return ok();
}

fn modifyColumn(db: *storage.Storage, table: *storage.Table, old_name: []const u8, new_col: storage.Column) !void {
    const idx = storage.Storage.columnIndex(table, old_name) orelse return error.UnknownColumn;
    var stored_col = new_col;
    for (table.indexes.items) |index| {
        if (indexContainsColumn(index, idx)) {
            if (index.primary) {
                stored_col.primary = true;
                stored_col.unique = true;
                stored_col.nullable = false;
            } else if (index.unique and index.columns.len == 1) {
                stored_col.unique = true;
            }
        }
    }
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var converted = try scratch.alloc(storage.Value, table.rows.items.len);
    for (table.rows.items, 0..) |row, i| {
        converted[i] = if (row.deleted) .null else try coerceColumn(scratch, stored_col, row.values[idx]);
        if (!row.deleted and (!stored_col.nullable or stored_col.primary) and converted[i] == .null) return error.NotNullViolation;
    }
    const old_col = table.columns[idx];
    table.columns[idx] = stored_col;
    validateAllRows(db.allocator, table) catch |err| {
        table.columns[idx] = old_col;
        return err;
    };
    table.columns[idx] = old_col;
    try validateConvertedUnique(scratch, table, idx, converted);
    try db.replaceColumn(table, idx, stored_col, converted);
}

fn dropPrimaryKey(table: *storage.Table, db: *storage.Storage) !void {
    try db.dropIndex(table, "PRIMARY");
    for (table.columns) |*col| {
        if (col.primary) {
            col.primary = false;
            col.unique = false;
        }
    }
}

fn validateConvertedUnique(allocator: std.mem.Allocator, table: *const storage.Table, column_index: usize, values: []const storage.Value) !void {
    var needs_check = false;
    var primary = false;
    for (table.indexes.items) |index| {
        if (indexContainsColumn(index, column_index) and index.unique and index.columns.len == 1) {
            needs_check = true;
            primary = primary or index.primary;
        }
    }
    if (!needs_check) return;
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (table.rows.items, 0..) |row, i| {
        if (row.deleted) continue;
        if (primary and values[i] == .null) return error.NotNullViolation;
        const result = try seen.getOrPut(storage.valueHash(values[i]));
        if (result.found_existing) return error.UniqueConstraintViolation;
    }
}

fn validateAssignments(allocator: std.mem.Allocator, table: *const storage.Table, row: *const storage.Row, assignments: []const storage.Assignment) !void {
    var values = try allocator.alloc(storage.Value, row.values.len);
    defer allocator.free(values);
    @memcpy(values, row.values);
    for (assignments) |assignment| values[assignment.column_index] = assignment.value;
    for (table.columns, 0..) |col, i| {
        if ((!col.nullable or col.primary) and values[i] == .null) return error.NotNullViolation;
    }
    try validateChecksForValues(allocator, table, values);
}

fn validateAllRows(allocator: std.mem.Allocator, table: *const storage.Table) !void {
    for (table.rows.items) |row| {
        if (!row.deleted) try validateChecksForValues(allocator, table, row.values);
    }
}

fn validateCheckForRows(allocator: std.mem.Allocator, table: *const storage.Table, expr_sql: []const u8) !void {
    for (table.rows.items) |row| {
        if (!row.deleted) try validateCheckForValues(allocator, table, row.values, expr_sql);
    }
}

fn validateChecksForValues(allocator: std.mem.Allocator, table: *const storage.Table, values: []const storage.Value) !void {
    for (table.checks.items) |check| try validateCheckForValues(allocator, table, values, check.expr_sql);
}

fn validateCheckForValues(allocator: std.mem.Allocator, table: *const storage.Table, values: []const storage.Value, expr_sql: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const tokens = try tokenize(scratch, expr_sql);
    var parser = Parser{ .tokens = tokens, .allocator = scratch };
    const expr = try parser.parseExpression();
    try parser.expect(.eof);
    const row = storage.Row{ .id = 0, .values = @constCast(values) };
    const ctx = RowContext{ .left_table = table, .left_row = &row };
    if (!try truthy(try evalExpr(scratch, ctx, expr, null))) return error.CheckConstraintViolation;
}

fn insertInto(db: *storage.Storage, stmt: InsertStmt) !Result {
    const table = db.findTable(stmt.table) orelse return error.UnknownTable;
    var affected_rows: u64 = 0;
    for (stmt.rows) |raw_row| {
        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var values = try db.allocator.alloc(storage.Value, table.columns.len);
        defer db.allocator.free(values);
        @memset(values, .null);
        var provided = try db.allocator.alloc(bool, table.columns.len);
        defer db.allocator.free(provided);
        @memset(provided, false);
        if (stmt.columns) |cols| {
            if (cols.len != raw_row.len) return error.ColumnCountMismatch;
            for (cols, 0..) |col, i| {
                const idx = storage.Storage.columnIndex(table, col) orelse return error.UnknownColumn;
                values[idx] = try coerceColumn(scratch, table.columns[idx], raw_row[i]);
                provided[idx] = true;
            }
        } else {
            if (raw_row.len != table.columns.len) return error.ColumnCountMismatch;
            for (raw_row, 0..) |value, i| {
                values[i] = try coerceColumn(scratch, table.columns[i], value);
                provided[i] = true;
            }
        }
        try fillAndValidateInsert(scratch, table, values, provided);
        if (stmt.mode == .replace) {
            if (storage.Storage.findConflictRow(table, values)) |row_id| {
                if (storage.Storage.findRowById(table, row_id)) |row| {
                    db.deleteRow(table, row);
                    affected_rows += 1;
                }
            }
            _ = try db.insertRow(table, values);
            affected_rows += 1;
            continue;
        }
        if (stmt.on_duplicate.len != 0) {
            if (storage.Storage.findConflictRow(table, values)) |row_id| {
                const row = storage.Storage.findRowById(table, row_id) orelse continue;
                const assignments = try buildDuplicateAssignments(scratch, table, row, stmt.on_duplicate, values);
                try validateAssignments(scratch, table, row, assignments);
                const changed = assignmentsChangeRow(row, assignments);
                try db.updateRow(table, row, assignments);
                if (changed) affected_rows += 2;
                continue;
            }
        }
        _ = db.insertRow(table, values) catch |err| switch (err) {
            error.UniqueConstraintViolation => if (stmt.mode == .ignore) continue else return err,
            else => return err,
        };
        affected_rows += 1;
    }
    return okAffected(affected_rows);
}

fn assignmentsChangeRow(row: *const storage.Row, assignments: []const storage.Assignment) bool {
    for (assignments) |assignment| {
        if (compareValues(row.values[assignment.column_index], assignment.value) != 0) return true;
    }
    return false;
}

fn buildDuplicateAssignments(allocator: std.mem.Allocator, table: *const storage.Table, row: *const storage.Row, parsed: []const AssignmentAst, incoming: []const storage.Value) ![]storage.Assignment {
    var assignments = try allocator.alloc(storage.Assignment, parsed.len);
    const ctx = RowContext{ .left_table = table, .left_row = row };
    for (parsed, 0..) |assignment, i| {
        const idx = storage.Storage.columnIndex(table, assignment.column) orelse return error.UnknownColumn;
        const raw = try evalDuplicateExpr(allocator, ctx, assignment.expr, table, incoming);
        assignments[i] = .{ .column_index = idx, .value = try coerceColumn(allocator, table.columns[idx], raw) };
        if (!table.columns[idx].nullable and assignments[i].value == .null) return error.NotNullViolation;
    }
    return assignments;
}

fn evalDuplicateExpr(allocator: std.mem.Allocator, ctx: RowContext, expr: *const Expr, table: *const storage.Table, incoming: []const storage.Value) anyerror!storage.Value {
    if (expr.* == .call and std.ascii.eqlIgnoreCase(expr.call.name, "values") and expr.call.args.len == 1 and expr.call.args[0].* == .column) {
        const idx = storage.Storage.columnIndex(table, expr.call.args[0].column) orelse return error.UnknownColumn;
        return incoming[idx];
    }
    return evalExpr(allocator, ctx, expr, null);
}

fn updateRows(allocator: std.mem.Allocator, db: *storage.Storage, stmt: UpdateStmt) !Result {
    const table = db.findTable(stmt.table) orelse return error.UnknownTable;
    const row_ids = try candidateRows(allocator, db, table, stmt.conditions);
    defer allocator.free(row_ids);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var affected_rows: u64 = 0;

    for (row_ids) |row_id| {
        const row = storage.Storage.findRowById(table, row_id) orelse continue;
        if (!row.deleted and try rowMatches(allocator, table, row, stmt.conditions, stmt.where_expr)) {
            const assignments = try buildUpdateAssignments(scratch, table, row, stmt.assignments);
            try validateAssignments(scratch, table, row, assignments);
            const changed = assignmentsChangeRow(row, assignments);
            try db.updateRow(table, row, assignments);
            if (changed) affected_rows += 1;
        }
    }
    return okAffected(affected_rows);
}

fn buildUpdateAssignments(allocator: std.mem.Allocator, table: *const storage.Table, row: *const storage.Row, parsed: []const AssignmentAst) ![]storage.Assignment {
    var assignments = try allocator.alloc(storage.Assignment, parsed.len);
    const ctx = RowContext{ .left_table = table, .left_row = row };
    for (parsed, 0..) |assignment, i| {
        const idx = storage.Storage.columnIndex(table, assignment.column) orelse return error.UnknownColumn;
        const raw = try evalExpr(allocator, ctx, assignment.expr, null);
        assignments[i] = .{ .column_index = idx, .value = try coerceColumn(allocator, table.columns[idx], raw) };
        if (!table.columns[idx].nullable and assignments[i].value == .null) return error.NotNullViolation;
    }
    return assignments;
}

fn deleteFrom(allocator: std.mem.Allocator, db: *storage.Storage, stmt: DeleteStmt) !Result {
    const table = db.findTable(stmt.table) orelse return error.UnknownTable;
    const row_ids = try candidateRows(allocator, db, table, stmt.conditions);
    defer allocator.free(row_ids);
    var deleted: usize = 0;
    for (row_ids) |row_id| {
        const row = storage.Storage.findRowById(table, row_id) orelse continue;
        if (!row.deleted and try rowMatches(allocator, table, row, stmt.conditions, stmt.where_expr)) {
            db.deleteRow(table, row);
            deleted += 1;
            if (stmt.limit) |limit| {
                if (deleted >= limit.count) break;
            }
        }
    }
    return okAffected(@intCast(deleted));
}

fn selectQuery(allocator: std.mem.Allocator, db: *storage.Storage, stmt: SelectStmt) !Result {
    if (stmt.table == null) return selectNoTable(allocator, stmt);
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();
    const table = db.findTable(stmt.table.?) orelse (try informationSchemaTable(temp, db, stmt.table.?)) orelse return error.UnknownTable;

    const contexts = try collectContexts(temp, db, table, stmt);
    var sorted = try allocator.dupe(RowContext, contexts);
    defer allocator.free(sorted);
    if (stmt.order_by.len != 0) {
        const orders = try temp.alloc(OrderBy, stmt.order_by.len);
        for (stmt.order_by, 0..) |order, i| {
            orders[i] = .{ .expr = resolveOrderExpr(stmt, order.expr), .desc = order.desc };
        }
        std.sort.insertion(RowContext, sorted, SortExprContext{ .allocator = temp, .orders = orders }, rowContextLessThan);
    }

    if (hasAggregates(stmt.items) or stmt.group_by.len != 0) {
        return aggregateResult(allocator, temp, table, stmt, sorted);
    }

    const column_sample = if (sorted.len > 0) sorted[0] else try emptyContext(temp, table, stmt.table_alias);
    const columns = try buildResultColumns(allocator, column_sample, stmt.items);
    errdefer allocator.free(columns);
    const offset = if (stmt.limit) |limit| @min(limit.offset, sorted.len) else 0;
    const end = if (stmt.limit) |limit| @min(sorted.len, offset + limit.count) else sorted.len;
    var rows = std.array_list.Managed(Row).init(allocator);
    errdefer freeRows(allocator, rows.items);
    for (sorted[offset..end]) |ctx| {
        var values = try allocator.alloc(?[]const u8, columns.len);
        errdefer allocator.free(values);
        var vi: usize = 0;
        for (stmt.items) |item| {
            switch (item.expr) {
                .star => {
                    vi = try appendStarValues(allocator, ctx, values, vi);
                },
                .expr => |expr| {
                    const value = try evalExpr(temp, ctx, expr, null);
                    values[vi] = try valueBytes(allocator, value);
                    vi += 1;
                },
            }
        }
        try rows.append(.{ .values = values });
    }
    return .{ .kind = .rows, .columns = columns, .rows = try rows.toOwnedSlice() };
}

const RowContext = struct {
    left_table: *const storage.Table,
    left_alias: ?[]const u8 = null,
    left_row: *const storage.Row,
    right_table: ?*const storage.Table = null,
    right_alias: ?[]const u8 = null,
    right_row: ?*const storage.Row = null,
};

fn collectContexts(allocator: std.mem.Allocator, db: *storage.Storage, table: *storage.Table, stmt: SelectStmt) ![]RowContext {
    var out = std.array_list.Managed(RowContext).init(allocator);
    const row_ids_all = try candidateRowsForWhere(allocator, db, table, stmt.conditions, stmt.where_expr);
    for (row_ids_all) |row_id| {
        const left = storage.Storage.findRowById(table, row_id) orelse continue;
        if (left.deleted) continue;
        const base = RowContext{ .left_table = table, .left_alias = stmt.table_alias, .left_row = left };
        if (stmt.join) |join| {
            const right_table = db.findTable(join.table) orelse return error.UnknownTable;
            var matched = false;
            for (right_table.rows.items) |*right| {
                if (right.deleted) continue;
                const ctx = RowContext{ .left_table = table, .left_alias = stmt.table_alias, .left_row = left, .right_table = right_table, .right_alias = join.alias, .right_row = right };
                if (try truthy(try evalExpr(allocator, ctx, join.on, null))) {
                    matched = true;
                    if (stmt.where_expr == null or try truthy(try evalExpr(allocator, ctx, stmt.where_expr.?, null))) try out.append(ctx);
                }
            }
            if (!matched and join.kind == .left) {
                const ctx = RowContext{ .left_table = table, .left_alias = stmt.table_alias, .left_row = left, .right_table = right_table, .right_alias = join.alias, .right_row = null };
                if (stmt.where_expr == null or try truthy(try evalExpr(allocator, ctx, stmt.where_expr.?, null))) try out.append(ctx);
            }
        } else if (stmt.where_expr == null or try truthy(try evalExpr(allocator, base, stmt.where_expr.?, null))) {
            try out.append(base);
        }
    }
    return out.toOwnedSlice();
}

fn resolveOrderExpr(stmt: SelectStmt, expr: *const Expr) *const Expr {
    if (expr.* == .column) {
        const name = expr.column;
        for (stmt.items) |item| {
            if (item.alias) |alias| {
                if (std.ascii.eqlIgnoreCase(alias, name) and item.expr == .expr) return item.expr.expr;
            }
        }
    }
    return expr;
}

fn candidateRowsForWhere(allocator: std.mem.Allocator, db: *storage.Storage, table: *storage.Table, conditions: []const Condition, where_expr: ?*const Expr) ![]storage.RowId {
    if (where_expr) |expr| {
        if (simpleIndexedPredicate(table, expr)) |pred| {
            const key = try coerceColumn(allocator, table.columns[pred.column_index], pred.value);
            if (db.indexedLookup(table, pred.column_index, key)) |hits| return allocator.dupe(storage.RowId, hits);
        }
    }
    return candidateRows(allocator, db, table, conditions);
}

const IndexedPredicate = struct {
    column_index: usize,
    value: storage.Value,
};

fn simpleIndexedPredicate(table: *const storage.Table, expr: *const Expr) ?IndexedPredicate {
    return switch (expr.*) {
        .binary => |b| if (b.op == .@"and") simpleIndexedPredicate(table, b.left) orelse simpleIndexedPredicate(table, b.right) else null,
        .compare => |c| blk: {
            if (c.op != .eq) break :blk null;
            if (c.left.* == .column and c.right.* == .literal) {
                const idx = storage.Storage.columnIndex(table, c.left.column) orelse break :blk null;
                break :blk .{ .column_index = idx, .value = c.right.literal };
            }
            if (c.right.* == .column and c.left.* == .literal) {
                const idx = storage.Storage.columnIndex(table, c.right.column) orelse break :blk null;
                break :blk .{ .column_index = idx, .value = c.left.literal };
            }
            break :blk null;
        },
        else => null,
    };
}

fn informationSchemaTable(allocator: std.mem.Allocator, db: *storage.Storage, name: []const u8) !?*storage.Table {
    if (!startsWith(name, "information_schema.")) return null;
    const short = name["information_schema.".len..];
    if (std.ascii.eqlIgnoreCase(short, "schemata")) return try buildInformationSchemaSchemata(allocator);
    if (std.ascii.eqlIgnoreCase(short, "tables")) return try buildInformationSchemaTables(allocator, db);
    if (std.ascii.eqlIgnoreCase(short, "columns")) return try buildInformationSchemaColumns(allocator, db);
    if (std.ascii.eqlIgnoreCase(short, "statistics")) return try buildInformationSchemaStatistics(allocator, db);
    return error.UnknownTable;
}

fn makeVirtualTable(allocator: std.mem.Allocator, name: []const u8, cols: []const []const u8) !*storage.Table {
    const table = try allocator.create(storage.Table);
    const columns = try allocator.alloc(storage.Column, cols.len);
    for (cols, 0..) |col, i| columns[i] = .{ .name = col, .kind = .text };
    table.* = .{
        .name = name,
        .columns = columns,
        .checks = std.array_list.Managed(storage.CheckConstraint).init(allocator),
        .rows = std.array_list.Managed(storage.Row).init(allocator),
        .indexes = std.array_list.Managed(storage.Index).init(allocator),
    };
    return table;
}

fn appendVirtualRow(allocator: std.mem.Allocator, table: *storage.Table, values: []const storage.Value) !void {
    const row_values = try allocator.alloc(storage.Value, values.len);
    @memcpy(row_values, values);
    try table.rows.append(.{ .id = @intCast(table.rows.items.len + 1), .values = row_values });
}

fn buildInformationSchemaSchemata(allocator: std.mem.Allocator) !*storage.Table {
    const table = try makeVirtualTable(allocator, "information_schema.schemata", &.{"SCHEMA_NAME"});
    try appendVirtualRow(allocator, table, &.{.{ .text = "main" }});
    return table;
}

fn buildInformationSchemaTables(allocator: std.mem.Allocator, db: *storage.Storage) !*storage.Table {
    const table = try makeVirtualTable(allocator, "information_schema.tables", &.{ "TABLE_SCHEMA", "TABLE_NAME", "TABLE_TYPE" });
    for (db.tables.items) |t| try appendVirtualRow(allocator, table, &.{ .{ .text = "main" }, .{ .text = t.name }, .{ .text = "BASE TABLE" } });
    return table;
}

fn buildInformationSchemaColumns(allocator: std.mem.Allocator, db: *storage.Storage) !*storage.Table {
    const table = try makeVirtualTable(allocator, "information_schema.columns", &.{ "TABLE_SCHEMA", "TABLE_NAME", "COLUMN_NAME", "ORDINAL_POSITION", "COLUMN_DEFAULT", "IS_NULLABLE", "DATA_TYPE", "COLUMN_TYPE", "COLUMN_KEY", "EXTRA", "CHARACTER_MAXIMUM_LENGTH", "NUMERIC_PRECISION", "NUMERIC_SCALE", "COLUMN_COMMENT", "DATETIME_PRECISION" });
    for (db.tables.items) |t| {
        for (t.columns, 0..) |col, i| {
            const kind_name = try columnTypeNameAlloc(allocator, col);
            const data_type = try columnTypeNameAlloc(allocator, col);
            const ordinal = try std.fmt.allocPrint(allocator, "{d}", .{i + 1});
            const default_value = if (col.default_value) |v| try valueBytes(allocator, v) else null;
            const char_len = try columnCharacterLengthAlloc(allocator, col.kind);
            const numeric_precision = try columnNumericPrecisionAlloc(allocator, col.kind);
            const numeric_scale = try columnNumericScaleAlloc(allocator, col.kind);
            try appendVirtualRow(allocator, table, &.{
                .{ .text = "main" },
                .{ .text = t.name },
                .{ .text = col.name },
                .{ .text = ordinal },
                if (default_value) |v| .{ .text = v } else .null,
                .{ .text = if (col.nullable and !col.primary) "YES" else "NO" },
                .{ .text = data_type },
                .{ .text = kind_name },
                .{ .text = columnKeyName(&t, i) },
                .{ .text = if (col.auto_increment) "auto_increment" else "" },
                if (char_len) |v| .{ .text = v } else .null,
                if (numeric_precision) |v| .{ .text = v } else .null,
                if (numeric_scale) |v| .{ .text = v } else .null,
                .{ .text = "" },
                .null,
            });
        }
    }
    return table;
}

fn buildInformationSchemaStatistics(allocator: std.mem.Allocator, db: *storage.Storage) !*storage.Table {
    const table = try makeVirtualTable(allocator, "information_schema.statistics", &.{ "TABLE_SCHEMA", "TABLE_NAME", "INDEX_NAME", "SEQ_IN_INDEX", "COLUMN_NAME", "NON_UNIQUE", "INDEX_TYPE" });
    for (db.tables.items) |t| {
        for (t.indexes.items) |index| {
            for (index.columns, 0..) |column_index, seq| {
                const seq_text = try std.fmt.allocPrint(allocator, "{d}", .{seq + 1});
                try appendVirtualRow(allocator, table, &.{
                    .{ .text = "main" },
                    .{ .text = t.name },
                    .{ .text = index.name },
                    .{ .text = seq_text },
                    .{ .text = t.columns[column_index].name },
                    .{ .text = if (index.unique) "0" else "1" },
                    .{ .text = "HASH" },
                });
            }
        }
    }
    return table;
}

fn buildResultColumns(allocator: std.mem.Allocator, sample: ?RowContext, items: []const SelectItem) ![]Column {
    var columns = std.array_list.Managed(Column).init(allocator);
    defer columns.deinit();
    for (items) |item| {
        switch (item.expr) {
            .star => {
                const ctx = sample orelse continue;
                for (ctx.left_table.columns) |col| try columns.append(.{ .name = col.name, .type_code = mysqlType(col.kind) });
                if (ctx.right_table) |rt| for (rt.columns) |col| try columns.append(.{ .name = col.name, .type_code = mysqlType(col.kind) });
            },
            .expr => |expr| try columns.append(.{ .name = item.alias orelse exprName(expr), .type_code = exprType(expr) }),
        }
    }
    return columns.toOwnedSlice();
}

fn selectNoTable(allocator: std.mem.Allocator, stmt: SelectStmt) !Result {
    var columns = try allocator.alloc(Column, stmt.items.len);
    errdefer allocator.free(columns);
    var values = try allocator.alloc(?[]const u8, stmt.items.len);
    errdefer allocator.free(values);
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();
    const dummy_table = storage.Table{ .name = "", .columns = &.{}, .checks = undefined, .rows = undefined, .indexes = undefined };
    const dummy_row = storage.Row{ .id = 0, .values = &.{} };
    const ctx = RowContext{ .left_table = &dummy_table, .left_row = &dummy_row };
    for (stmt.items, 0..) |item, i| {
        switch (item.expr) {
            .expr => |expr| {
                const v = try evalExpr(temp, ctx, expr, null);
                columns[i] = .{ .name = item.alias orelse exprName(expr), .type_code = exprType(expr) };
                values[i] = try valueBytes(allocator, v);
            },
            else => return error.BadSelect,
        }
    }
    var rows = try allocator.alloc(Row, 1);
    rows[0] = .{ .values = values };
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

const AggregateGroup = struct {
    contexts: []const RowContext,
};

fn hasAggregates(items: []const SelectItem) bool {
    for (items) |item| {
        if (item.expr == .expr and exprHasAggregate(item.expr.expr)) return true;
    }
    return false;
}

fn exprHasAggregate(expr: *const Expr) bool {
    return switch (expr.*) {
        .aggregate => true,
        .unary => |e| exprHasAggregate(e.expr),
        .binary => |e| exprHasAggregate(e.left) or exprHasAggregate(e.right),
        .compare => |e| exprHasAggregate(e.left) or exprHasAggregate(e.right),
        .like => |e| exprHasAggregate(e.expr) or exprHasAggregate(e.pattern),
        .in_list => |e| blk: {
            if (exprHasAggregate(e.expr)) break :blk true;
            for (e.values) |v| if (exprHasAggregate(v)) break :blk true;
            break :blk false;
        },
        .is_null => |e| exprHasAggregate(e.expr),
        .case_expr => |e| blk: {
            if (exprHasAggregate(e.operand)) break :blk true;
            for (e.cases) |arm| {
                if (exprHasAggregate(arm.when) or exprHasAggregate(arm.then)) break :blk true;
            }
            if (e.else_expr) |else_expr| if (exprHasAggregate(else_expr)) break :blk true;
            break :blk false;
        },
        .call => |e| blk: {
            for (e.args) |arg| if (exprHasAggregate(arg)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn aggregateResult(allocator: std.mem.Allocator, temp: std.mem.Allocator, table: *const storage.Table, stmt: SelectStmt, contexts: []const RowContext) !Result {
    var groups = std.array_list.Managed([]const RowContext).init(temp);
    if (stmt.group_by.len == 0) {
        try groups.append(contexts);
    } else {
        var keys = std.StringHashMap(std.array_list.Managed(RowContext)).init(temp);
        for (contexts) |ctx| {
            const key = try groupKey(temp, ctx, stmt.group_by);
            const entry = try keys.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed(RowContext).init(temp);
            try entry.value_ptr.append(ctx);
        }
        var it = keys.valueIterator();
        while (it.next()) |list| try groups.append(list.items);
    }

    const column_sample = if (contexts.len > 0) contexts[0] else try emptyContext(temp, table, stmt.table_alias);
    const columns = try buildResultColumns(allocator, column_sample, stmt.items);
    errdefer allocator.free(columns);
    var rows = std.array_list.Managed(Row).init(allocator);
    errdefer freeRows(allocator, rows.items);
    for (groups.items) |group_contexts| {
        if (group_contexts.len == 0 and stmt.group_by.len != 0) continue;
        const sample = if (group_contexts.len > 0) group_contexts[0] else try emptyContext(temp, table, stmt.table_alias);
        const group = AggregateGroup{ .contexts = group_contexts };
        if (stmt.having) |having| {
            if (!try truthy(try evalExpr(temp, sample, having, group))) continue;
        }
        var values = try allocator.alloc(?[]const u8, columns.len);
        errdefer allocator.free(values);
        var vi: usize = 0;
        for (stmt.items) |item| {
            switch (item.expr) {
                .star => vi = try appendStarValues(allocator, sample, values, vi),
                .expr => |expr| {
                    const value = try evalExpr(temp, sample, expr, group);
                    values[vi] = try valueBytes(allocator, value);
                    vi += 1;
                },
            }
        }
        try rows.append(.{ .values = values });
    }
    return .{ .kind = .rows, .columns = columns, .rows = try rows.toOwnedSlice() };
}

fn emptyContext(allocator: std.mem.Allocator, table: *const storage.Table, alias: ?[]const u8) !RowContext {
    const values = try allocator.alloc(storage.Value, table.columns.len);
    @memset(values, .null);
    const row = try allocator.create(storage.Row);
    row.* = .{ .id = 0, .values = values };
    return .{ .left_table = table, .left_alias = alias, .left_row = row };
}

fn groupKey(allocator: std.mem.Allocator, ctx: RowContext, exprs: []const *const Expr) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (exprs) |expr| {
        const value = try evalExpr(allocator, ctx, expr, null);
        const bytes = try valueBytes(allocator, value);
        if (bytes) |b| try out.appendSlice(b) else try out.appendSlice("<NULL>");
        try out.append(0);
    }
    return out.toOwnedSlice();
}

fn appendStarValues(allocator: std.mem.Allocator, ctx: RowContext, values: []?[]const u8, start: usize) !usize {
    var i = start;
    for (ctx.left_row.values) |value| {
        values[i] = try valueBytes(allocator, value);
        i += 1;
    }
    if (ctx.right_table) |rt| {
        if (ctx.right_row) |rr| {
            for (rr.values) |value| {
                values[i] = try valueBytes(allocator, value);
                i += 1;
            }
        } else {
            for (rt.columns) |_| {
                values[i] = null;
                i += 1;
            }
        }
    }
    return i;
}

const SortExprContext = struct {
    allocator: std.mem.Allocator,
    orders: []const OrderBy,
};

fn rowContextLessThan(ctx: SortExprContext, lhs: RowContext, rhs: RowContext) bool {
    for (ctx.orders) |order| {
        const l = evalExpr(ctx.allocator, lhs, order.expr, null) catch .null;
        const r = evalExpr(ctx.allocator, rhs, order.expr, null) catch .null;
        const cmp = compareValues(l, r);
        if (cmp != 0) return if (order.desc) cmp > 0 else cmp < 0;
    }
    return false;
}

fn evalExpr(allocator: std.mem.Allocator, ctx: RowContext, expr: *const Expr, group: ?AggregateGroup) anyerror!storage.Value {
    return switch (expr.*) {
        .literal => |v| v,
        .column => |name| try resolveColumn(ctx, name),
        .unary => |u| switch (u.op) {
            .not => .{ .bool = !try truthy(try evalExpr(allocator, ctx, u.expr, group)) },
            .neg => .{ .real = -try asReal(try evalExpr(allocator, ctx, u.expr, group)) },
        },
        .binary => |b| blk: {
            if (b.op == .@"and") {
                break :blk .{ .bool = try truthy(try evalExpr(allocator, ctx, b.left, group)) and try truthy(try evalExpr(allocator, ctx, b.right, group)) };
            }
            if (b.op == .@"or") {
                break :blk .{ .bool = try truthy(try evalExpr(allocator, ctx, b.left, group)) or try truthy(try evalExpr(allocator, ctx, b.right, group)) };
            }
            const left = try evalExpr(allocator, ctx, b.left, group);
            const right = try evalExpr(allocator, ctx, b.right, group);
            if (left == .null or right == .null) break :blk .null;
            const l = try asReal(left);
            const r = try asReal(right);
            break :blk .{ .real = switch (b.op) {
                .add => l + r,
                .sub => l - r,
                .mul => l * r,
                .div => if (r == 0) 0 else l / r,
                else => unreachable,
            } };
        },
        .compare => |c| .{ .bool = compareOp(try evalExpr(allocator, ctx, c.left, group), c.op, try evalExpr(allocator, ctx, c.right, group)) },
        .like => |l| blk: {
            const text = valueText(try evalExpr(allocator, ctx, l.expr, group)) orelse break :blk .{ .bool = false };
            const pattern = valueText(try evalExpr(allocator, ctx, l.pattern, group)) orelse break :blk .{ .bool = false };
            const matched = likeMatch(text, pattern);
            break :blk .{ .bool = if (l.negated) !matched else matched };
        },
        .in_list => |in| blk: {
            const left = try evalExpr(allocator, ctx, in.expr, group);
            if (left == .null) break :blk .null;
            var has_null = false;
            for (in.values) |value_expr| {
                const right = try evalExpr(allocator, ctx, value_expr, group);
                if (right == .null) {
                    has_null = true;
                } else if (compareOp(left, .eq, right)) {
                    break :blk .{ .bool = !in.negated };
                }
            }
            if (has_null) break :blk .null;
            break :blk .{ .bool = in.negated };
        },
        .is_null => |n| blk: {
            const is_null = (try evalExpr(allocator, ctx, n.expr, group)) == .null;
            break :blk .{ .bool = if (n.negated) !is_null else is_null };
        },
        .case_expr => |case_expr| blk: {
            const operand = try evalExpr(allocator, ctx, case_expr.operand, group);
            for (case_expr.cases) |arm| {
                const when = try evalExpr(allocator, ctx, arm.when, group);
                if (compareOp(operand, .eq, when)) break :blk try evalExpr(allocator, ctx, arm.then, group);
            }
            if (case_expr.else_expr) |else_expr| break :blk try evalExpr(allocator, ctx, else_expr, group);
            break :blk .null;
        },
        .call => |call| evalCall(allocator, ctx, call.name, call.args, group),
        .aggregate => |agg| evalAggregate(allocator, agg.name, agg.arg, group orelse return error.AggregateOutsideGroup),
    };
}

fn evalAggregate(allocator: std.mem.Allocator, name: []const u8, arg: ?*const Expr, group: AggregateGroup) anyerror!storage.Value {
    if (std.ascii.eqlIgnoreCase(name, "count")) {
        if (arg == null) return .{ .int = @intCast(group.contexts.len) };
        var count: i64 = 0;
        for (group.contexts) |ctx| {
            if ((try evalExpr(allocator, ctx, arg.?, null)) != .null) count += 1;
        }
        return .{ .int = count };
    }
    var seen = false;
    var sum: f64 = 0;
    var count: f64 = 0;
    var best: storage.Value = .null;
    for (group.contexts) |ctx| {
        const value = try evalExpr(allocator, ctx, arg orelse return error.BadAggregate, null);
        if (value == .null) continue;
        if (!seen) {
            best = value;
            seen = true;
        }
        if (std.ascii.eqlIgnoreCase(name, "sum") or std.ascii.eqlIgnoreCase(name, "avg")) {
            sum += try asReal(value);
            count += 1;
        } else if (std.ascii.eqlIgnoreCase(name, "min")) {
            if (compareValues(value, best) < 0) best = value;
        } else if (std.ascii.eqlIgnoreCase(name, "max")) {
            if (compareValues(value, best) > 0) best = value;
        }
    }
    if (!seen) return .null;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .{ .real = sum };
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .{ .real = sum / count };
    if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) return best;
    return error.UnknownFunction;
}

fn evalCall(allocator: std.mem.Allocator, ctx: RowContext, name: []const u8, args: []const *const Expr, group: ?AggregateGroup) anyerror!storage.Value {
    if (std.ascii.eqlIgnoreCase(name, "version")) {
        if (args.len != 0) return error.BadFunctionArity;
        return .{ .text = "8.0.46-mysqlzig" };
    }
    if (std.ascii.eqlIgnoreCase(name, "now")) return .{ .datetime = "2026-07-07 00:00:00" };
    if (std.ascii.eqlIgnoreCase(name, "current_date")) return .{ .date = "2026-07-07" };
    if (std.ascii.eqlIgnoreCase(name, "lower") or std.ascii.eqlIgnoreCase(name, "upper")) {
        if (args.len != 1) return error.BadFunctionArity;
        const text = valueText(try evalExpr(allocator, ctx, args[0], group)) orelse return .null;
        const out = try allocator.dupe(u8, text);
        for (out) |*c| c.* = if (std.ascii.eqlIgnoreCase(name, "lower")) std.ascii.toLower(c.*) else std.ascii.toUpper(c.*);
        return .{ .text = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "length")) {
        if (args.len != 1) return error.BadFunctionArity;
        return .{ .int = @intCast((valueText(try evalExpr(allocator, ctx, args[0], group)) orelse @as([]const u8, "")).len) };
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        var out = std.array_list.Managed(u8).init(allocator);
        for (args) |arg| if (valueText(try evalExpr(allocator, ctx, arg, group))) |text| try out.appendSlice(text);
        return .{ .text = try out.toOwnedSlice() };
    }
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        if (args.len != 1) return error.BadFunctionArity;
        const v = try asReal(try evalExpr(allocator, ctx, args[0], group));
        return .{ .real = if (v < 0) -v else v };
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) {
        if (args.len < 1) return error.BadFunctionArity;
        return .{ .real = @round(try asReal(try evalExpr(allocator, ctx, args[0], group))) };
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce") or std.ascii.eqlIgnoreCase(name, "ifnull")) {
        for (args) |arg| {
            const value = try evalExpr(allocator, ctx, arg, group);
            if (value != .null) return value;
        }
        return .null;
    }
    return error.UnknownFunction;
}

fn resolveColumn(ctx: RowContext, name: []const u8) !storage.Value {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        const qualifier = name[0..dot];
        const col = name[dot + 1 ..];
        if (matchesTable(ctx.left_table, ctx.left_alias, qualifier)) {
            const idx = storage.Storage.columnIndex(ctx.left_table, col) orelse return error.UnknownColumn;
            return ctx.left_row.values[idx];
        }
        if (ctx.right_table) |rt| {
            if (matchesTable(rt, ctx.right_alias, qualifier)) {
                const idx = storage.Storage.columnIndex(rt, col) orelse return error.UnknownColumn;
                return if (ctx.right_row) |rr| rr.values[idx] else .null;
            }
        }
        return error.UnknownTable;
    }
    var found: ?storage.Value = null;
    if (storage.Storage.columnIndex(ctx.left_table, name)) |idx| found = ctx.left_row.values[idx];
    if (ctx.right_table) |rt| {
        if (storage.Storage.columnIndex(rt, name)) |idx| {
            if (found != null) return error.AmbiguousColumn;
            found = if (ctx.right_row) |rr| rr.values[idx] else .null;
        }
    }
    return found orelse error.UnknownColumn;
}

fn matchesTable(table: *const storage.Table, alias: ?[]const u8, qualifier: []const u8) bool {
    return std.ascii.eqlIgnoreCase(table.name, qualifier) or (alias != null and std.ascii.eqlIgnoreCase(alias.?, qualifier));
}

fn truthy(value: storage.Value) !bool {
    if (value == .null) return false;
    if (numericValue(value)) |n| return n != 0;
    return (valueText(value) orelse @as([]const u8, "")).len != 0;
}

fn exprName(expr: *const Expr) []const u8 {
    return switch (expr.*) {
        .column => |name| name,
        .aggregate => |agg| if (std.ascii.eqlIgnoreCase(agg.name, "count") and agg.arg == null) "COUNT(*)" else agg.name,
        .call => |call| call.name,
        .literal => |v| literalColumnName(v),
        else => "expr",
    };
}

fn exprType(expr: *const Expr) u8 {
    return switch (expr.*) {
        .literal => |v| valueTypeCode(v),
        .compare, .like, .in_list, .is_null => 0x01,
        .binary => |b| switch (b.op) {
            .@"and", .@"or" => 0x01,
            else => 0x05,
        },
        .aggregate => |agg| if (std.ascii.eqlIgnoreCase(agg.name, "count")) 0x08 else 0x05,
        else => 0xfd,
    };
}

fn renderExprAlloc(allocator: std.mem.Allocator, expr: *const Expr) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try renderExpr(&out, expr);
    return out.toOwnedSlice();
}

fn renderExpr(out: *std.array_list.Managed(u8), expr: *const Expr) !void {
    switch (expr.*) {
        .literal => |v| try renderLiteral(out, v),
        .column => |name| try out.appendSlice(name),
        .unary => |u| {
            try out.appendSlice(if (u.op == .not) "NOT " else "-");
            try renderExpr(out, u.expr);
        },
        .binary => |b| {
            try out.append('(');
            try renderExpr(out, b.left);
            try out.print(" {s} ", .{switch (b.op) {
                .@"and" => "AND",
                .@"or" => "OR",
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
            }});
            try renderExpr(out, b.right);
            try out.append(')');
        },
        .compare => |c| {
            try out.append('(');
            try renderExpr(out, c.left);
            try out.print(" {s} ", .{switch (c.op) {
                .eq => "=",
                .ne => "!=",
                .lt => "<",
                .lte => "<=",
                .gt => ">",
                .gte => ">=",
            }});
            try renderExpr(out, c.right);
            try out.append(')');
        },
        .like => |l| {
            try renderExpr(out, l.expr);
            try out.appendSlice(if (l.negated) " NOT LIKE " else " LIKE ");
            try renderExpr(out, l.pattern);
        },
        .in_list => |in| {
            try renderExpr(out, in.expr);
            try out.appendSlice(if (in.negated) " NOT IN (" else " IN (");
            for (in.values, 0..) |value, i| {
                if (i != 0) try out.appendSlice(", ");
                try renderExpr(out, value);
            }
            try out.append(')');
        },
        .is_null => |n| {
            try renderExpr(out, n.expr);
            try out.appendSlice(if (n.negated) " IS NOT NULL" else " IS NULL");
        },
        .case_expr => |case_expr| {
            try out.appendSlice("CASE ");
            try renderExpr(out, case_expr.operand);
            for (case_expr.cases) |arm| {
                try out.appendSlice(" WHEN ");
                try renderExpr(out, arm.when);
                try out.appendSlice(" THEN ");
                try renderExpr(out, arm.then);
            }
            if (case_expr.else_expr) |else_expr| {
                try out.appendSlice(" ELSE ");
                try renderExpr(out, else_expr);
            }
            try out.appendSlice(" END");
        },
        .call => |call| {
            try out.print("{s}(", .{call.name});
            for (call.args, 0..) |arg, i| {
                if (i != 0) try out.appendSlice(", ");
                try renderExpr(out, arg);
            }
            try out.append(')');
        },
        .aggregate => |agg| {
            try out.print("{s}(", .{agg.name});
            if (agg.arg) |arg| try renderExpr(out, arg) else try out.append('*');
            try out.append(')');
        },
    }
}

fn renderLiteral(out: *std.array_list.Managed(u8), value: storage.Value) !void {
    switch (value) {
        .null => try out.appendSlice("NULL"),
        .int => |v| try out.print("{d}", .{v}),
        .bool => |v| try out.appendSlice(if (v) "true" else "false"),
        .real => |v| try out.print("{d}", .{v}),
        .year => |v| try out.print("{d}", .{v}),
        else => {
            const text = valueText(value) orelse "";
            try out.append('\'');
            for (text) |c| {
                if (c == '\'') try out.append('\'');
                try out.append(c);
            }
            try out.append('\'');
        },
    }
}

fn candidateRows(allocator: std.mem.Allocator, db: *storage.Storage, table: *storage.Table, conditions: []const Condition) ![]storage.RowId {
    for (conditions) |cond| {
        if (cond == .compare and cond.compare.op == .eq) {
            const idx = storage.Storage.columnIndex(table, cond.compare.column) orelse return error.UnknownColumn;
            const key = try coerceColumn(allocator, table.columns[idx], cond.compare.value);
            if (db.indexedLookup(table, idx, key)) |hits| return allocator.dupe(storage.RowId, hits);
        }
    }
    var rows = std.array_list.Managed(storage.RowId).init(allocator);
    defer rows.deinit();
    for (table.rows.items) |row| if (!row.deleted) try rows.append(row.id);
    return rows.toOwnedSlice();
}

fn rowMatches(allocator: std.mem.Allocator, table: *const storage.Table, row: *const storage.Row, conditions: []const Condition, where_expr: ?*const Expr) !bool {
    if (where_expr) |expr| {
        const ctx = RowContext{ .left_table = table, .left_row = row };
        return truthy(try evalExpr(allocator, ctx, expr, null));
    }
    for (conditions) |cond| {
        switch (cond) {
            .compare => |c| {
                const idx = storage.Storage.columnIndex(table, c.column) orelse return error.UnknownColumn;
                const right = try coerceColumn(allocator, table.columns[idx], c.value);
                if (!compareOp(row.values[idx], c.op, right)) return false;
            },
            .like => |c| {
                const idx = storage.Storage.columnIndex(table, c.column) orelse return error.UnknownColumn;
                const text = valueText(row.values[idx]) orelse return false;
                if (!likeMatch(text, c.pattern)) return false;
            },
            .in_list => |c| {
                const idx = storage.Storage.columnIndex(table, c.column) orelse return error.UnknownColumn;
                var matched = false;
                for (c.values) |value| {
                    const right = try coerceColumn(allocator, table.columns[idx], value);
                    if (compareOp(row.values[idx], .eq, right)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) return false;
            },
            .is_null => |c| {
                const idx = storage.Storage.columnIndex(table, c.column) orelse return error.UnknownColumn;
                const is_null = row.values[idx] == .null;
                if (c.negated == is_null) return false;
            },
        }
    }
    return true;
}

fn showTables(allocator: std.mem.Allocator, db: *storage.Storage, pattern: ?[]const u8, full: bool) !Result {
    var filtered = std.array_list.Managed([]const u8).init(allocator);
    defer filtered.deinit();
    for (db.tables.items) |table| {
        if (pattern == null or likeMatch(table.name, pattern.?)) try filtered.append(table.name);
    }
    const col_count: usize = if (full) 2 else 1;
    var columns = try allocator.alloc(Column, col_count);
    columns[0] = .{ .name = "Tables_in_main", .type_code = 0xfd };
    if (full) columns[1] = .{ .name = "Table_type", .type_code = 0xfd };
    var rows = try allocator.alloc(Row, filtered.items.len);
    errdefer allocator.free(rows);
    for (filtered.items, 0..) |name, i| {
        rows[i].values = try allocator.alloc(?[]const u8, col_count);
        rows[i].values[0] = try allocator.dupe(u8, name);
        if (full) rows[i].values[1] = try allocator.dupe(u8, "BASE TABLE");
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn describeTable(allocator: std.mem.Allocator, db: *storage.Storage, table_name: []const u8, field_name: ?[]const u8) !Result {
    const table = db.findTable(table_name) orelse return error.UnknownTable;
    const names = [_][]const u8{ "Field", "Type", "Null", "Key", "Default", "Extra" };
    var columns = try allocator.alloc(Column, names.len);
    for (names, 0..) |name, i| columns[i] = .{ .name = name, .type_code = 0xfd };
    const row_count = countMatchingColumns(table, field_name);
    var rows = try allocator.alloc(Row, row_count);
    errdefer allocator.free(rows);
    var ri: usize = 0;
    for (table.columns, 0..) |col, i| {
        if (field_name != null and !std.ascii.eqlIgnoreCase(col.name, field_name.?)) continue;
        rows[ri].values = try allocator.alloc(?[]const u8, names.len);
        rows[ri].values[0] = try allocator.dupe(u8, col.name);
        rows[ri].values[1] = try columnTypeNameAlloc(allocator, col);
        rows[ri].values[2] = try allocator.dupe(u8, if (col.nullable and !col.primary) "YES" else "NO");
        rows[ri].values[3] = try allocator.dupe(u8, columnKeyName(table, i));
        rows[ri].values[4] = if (col.default_value) |v| try valueBytes(allocator, v) else null;
        rows[ri].values[5] = try allocator.dupe(u8, if (col.auto_increment) "auto_increment" else "");
        ri += 1;
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn showFullColumns(allocator: std.mem.Allocator, db: *storage.Storage, table_name: []const u8, field_name: ?[]const u8) !Result {
    const table = db.findTable(table_name) orelse return error.UnknownTable;
    const names = [_][]const u8{ "Field", "Type", "Collation", "Null", "Key", "Default", "Extra", "Privileges", "Comment" };
    var columns = try allocator.alloc(Column, names.len);
    for (names, 0..) |name, i| columns[i] = .{ .name = name, .type_code = 0xfd };
    const row_count = countMatchingColumns(table, field_name);
    var rows = try allocator.alloc(Row, row_count);
    errdefer allocator.free(rows);
    var ri: usize = 0;
    for (table.columns, 0..) |col, i| {
        if (field_name != null and !std.ascii.eqlIgnoreCase(col.name, field_name.?)) continue;
        rows[ri].values = try allocator.alloc(?[]const u8, names.len);
        rows[ri].values[0] = try allocator.dupe(u8, col.name);
        rows[ri].values[1] = try columnTypeNameAlloc(allocator, col);
        rows[ri].values[2] = try allocator.dupe(u8, "utf8mb4_general_ci");
        rows[ri].values[3] = try allocator.dupe(u8, if (col.nullable and !col.primary) "YES" else "NO");
        rows[ri].values[4] = try allocator.dupe(u8, columnKeyName(table, i));
        rows[ri].values[5] = if (col.default_value) |v| try valueBytes(allocator, v) else null;
        rows[ri].values[6] = try allocator.dupe(u8, if (col.auto_increment) "auto_increment" else "");
        rows[ri].values[7] = try allocator.dupe(u8, "select,insert,update,references");
        rows[ri].values[8] = try allocator.dupe(u8, "");
        ri += 1;
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn countMatchingColumns(table: *const storage.Table, field_name: ?[]const u8) usize {
    if (field_name == null) return table.columns.len;
    var count: usize = 0;
    for (table.columns) |col| {
        if (std.ascii.eqlIgnoreCase(col.name, field_name.?)) count += 1;
    }
    return count;
}

fn showCreateTable(allocator: std.mem.Allocator, db: *storage.Storage, table_name: []const u8) !Result {
    const table = db.findTable(table_name) orelse return error.UnknownTable;
    var sql = std.array_list.Managed(u8).init(allocator);
    defer sql.deinit();
    try sql.print("CREATE TABLE `{s}` (", .{table.name});
    for (table.columns, 0..) |col, i| {
        if (i != 0) try sql.appendSlice(", ");
        const kind_name = try columnTypeNameAlloc(allocator, col);
        defer allocator.free(kind_name);
        try sql.print("`{s}` {s}", .{ col.name, kind_name });
        if (!col.nullable or col.primary) try sql.appendSlice(" NOT NULL");
        if (col.default_value) |default_value| {
            const bytes = try valueBytes(allocator, default_value);
            defer if (bytes) |b| allocator.free(b);
            if (bytes) |b| try sql.print(" DEFAULT '{s}'", .{b}) else try sql.appendSlice(" DEFAULT NULL");
        }
        if (col.auto_increment) try sql.appendSlice(" AUTO_INCREMENT");
        if (col.primary) try sql.appendSlice(" PRIMARY KEY") else if (col.unique) try sql.appendSlice(" UNIQUE");
    }
    for (table.indexes.items) |index| {
        const inline_constraint = index.columns.len == 1 and (table.columns[index.columns[0]].primary or table.columns[index.columns[0]].unique);
        if (inline_constraint) continue;
        try sql.appendSlice(", ");
        if (index.primary) {
            try appendIndexColumnList(&sql, "PRIMARY KEY", null, table, index.columns);
        } else if (index.unique) {
            try appendIndexColumnList(&sql, "UNIQUE KEY", index.name, table, index.columns);
        } else {
            try appendIndexColumnList(&sql, "KEY", index.name, table, index.columns);
        }
    }
    for (table.checks.items) |check| {
        try sql.print(", CONSTRAINT `{s}` CHECK ({s})", .{ check.name, check.expr_sql });
    }
    try sql.append(')');
    var columns = try allocator.alloc(Column, 2);
    columns[0] = .{ .name = "Table", .type_code = 0xfd };
    columns[1] = .{ .name = "Create Table", .type_code = 0xfd };
    var rows = try allocator.alloc(Row, 1);
    rows[0].values = try allocator.alloc(?[]const u8, 2);
    rows[0].values[0] = try allocator.dupe(u8, table.name);
    rows[0].values[1] = try sql.toOwnedSlice();
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn appendIndexColumnList(out: *std.array_list.Managed(u8), prefix: []const u8, name: ?[]const u8, table: *const storage.Table, columns: []const usize) !void {
    try out.appendSlice(prefix);
    if (name) |index_name| try out.print(" `{s}`", .{index_name});
    try out.appendSlice(" (");
    for (columns, 0..) |column_index, i| {
        if (i != 0) try out.appendSlice(", ");
        try out.print("`{s}`", .{table.columns[column_index].name});
    }
    try out.append(')');
}

fn showCreateDatabase(allocator: std.mem.Allocator, name: []const u8) !Result {
    var columns = try allocator.alloc(Column, 2);
    columns[0] = .{ .name = "Database", .type_code = 0xfd };
    columns[1] = .{ .name = "Create Database", .type_code = 0xfd };
    var rows = try allocator.alloc(Row, 1);
    rows[0].values = try allocator.alloc(?[]const u8, 2);
    rows[0].values[0] = try allocator.dupe(u8, name);
    rows[0].values[1] = try std.fmt.allocPrint(allocator, "CREATE DATABASE `{s}`", .{name});
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn showIndex(allocator: std.mem.Allocator, db: *storage.Storage, table_name: []const u8, key_name: ?[]const u8) !Result {
    const table = db.findTable(table_name) orelse return error.UnknownTable;
    var columns = try allocator.alloc(Column, 6);
    columns[0] = .{ .name = "Table", .type_code = 0xfd };
    columns[1] = .{ .name = "Non_unique", .type_code = 0x08 };
    columns[2] = .{ .name = "Key_name", .type_code = 0xfd };
    columns[3] = .{ .name = "Seq_in_index", .type_code = 0x08 };
    columns[4] = .{ .name = "Column_name", .type_code = 0xfd };
    columns[5] = .{ .name = "Index_type", .type_code = 0xfd };
    var row_count: usize = 0;
    for (table.indexes.items) |index| {
        if (key_name != null and !std.ascii.eqlIgnoreCase(index.name, key_name.?)) continue;
        row_count += index.columns.len;
    }
    var rows = try allocator.alloc(Row, row_count);
    errdefer allocator.free(rows);
    var ri: usize = 0;
    for (table.indexes.items) |index| {
        if (key_name != null and !std.ascii.eqlIgnoreCase(index.name, key_name.?)) continue;
        for (index.columns, 0..) |column_index, seq| {
            rows[ri].values = try allocator.alloc(?[]const u8, 6);
            rows[ri].values[0] = try allocator.dupe(u8, table.name);
            rows[ri].values[1] = try allocator.dupe(u8, if (index.unique) "0" else "1");
            rows[ri].values[2] = try allocator.dupe(u8, index.name);
            rows[ri].values[3] = try std.fmt.allocPrint(allocator, "{d}", .{seq + 1});
            rows[ri].values[4] = try allocator.dupe(u8, table.columns[column_index].name);
            rows[ri].values[5] = try allocator.dupe(u8, "HASH");
            ri += 1;
        }
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn showVariables(allocator: std.mem.Allocator, pattern: ?[]const u8) !Result {
    const pairs = [_][2][]const u8{
        .{ "version", "8.0.46-mysqlzig" },
        .{ "version_comment", "mysqlzig" },
        .{ "character_set_client", "utf8mb4" },
        .{ "character_set_connection", "utf8mb4" },
        .{ "character_set_results", "utf8mb4" },
        .{ "autocommit", "ON" },
    };
    var rows_tmp = std.array_list.Managed([2][]const u8).init(allocator);
    defer rows_tmp.deinit();
    for (pairs) |pair| {
        if (pattern == null or likeMatch(pair[0], pattern.?)) try rows_tmp.append(pair);
    }
    var columns = try allocator.alloc(Column, 2);
    columns[0] = .{ .name = "Variable_name", .type_code = 0xfd };
    columns[1] = .{ .name = "Value", .type_code = 0xfd };
    var rows = try allocator.alloc(Row, rows_tmp.items.len);
    errdefer allocator.free(rows);
    for (rows_tmp.items, 0..) |pair, i| {
        rows[i].values = try allocator.alloc(?[]const u8, 2);
        rows[i].values[0] = try allocator.dupe(u8, pair[0]);
        rows[i].values[1] = try allocator.dupe(u8, pair[1]);
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn singleColumnRows(allocator: std.mem.Allocator, name: []const u8, values: []const []const u8) !Result {
    var columns = try allocator.alloc(Column, 1);
    columns[0] = .{ .name = name, .type_code = 0xfd };
    var rows = try allocator.alloc(Row, values.len);
    errdefer allocator.free(rows);
    for (values, 0..) |value, i| {
        rows[i].values = try allocator.alloc(?[]const u8, 1);
        rows[i].values[0] = try allocator.dupe(u8, value);
    }
    return .{ .kind = .rows, .columns = columns, .rows = rows };
}

fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| {
        for (row.values) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(row.values);
    }
}

fn coerceColumn(allocator: std.mem.Allocator, col: storage.Column, value: storage.Value) !storage.Value {
    if (value == .null) return .null;
    switch (col.kind) {
        .tiny_int, .small_int, .medium_int, .int, .big_int => {
            const v = try asInt(value);
            try checkIntegerRange(col.kind, col.unsigned, v);
            return .{ .int = v };
        },
        .bit => |bits| {
            const v = try asInt(value);
            if (bits < 1 or bits > 64) return error.BadBitWidth;
            if (v < 0) return error.IntegerOutOfRange;
            if (bits < 63 and @as(u64, @intCast(v)) >= (@as(u64, 1) << @intCast(bits))) return error.IntegerOutOfRange;
            return .{ .int = v };
        },
        .binary => |len| {
            const bytes = try asBytes(value);
            if (bytes.len > len) return error.ValueTooLong;
            const out = try allocator.alloc(u8, len);
            @memset(out, 0);
            @memcpy(out[0..bytes.len], bytes);
            return .{ .blob = out };
        },
        .tiny_text => {
            const bytes = try asBytes(value);
            if (bytes.len > 255) return error.ValueTooLong;
            return .{ .text = bytes };
        },
        .medium_text => {
            const bytes = try asBytes(value);
            if (bytes.len > 16_777_215) return error.ValueTooLong;
            return .{ .text = bytes };
        },
        .long_text => return .{ .text = try asBytes(value) },
        .tiny_blob => {
            const bytes = try asBytes(value);
            if (bytes.len > 255) return error.ValueTooLong;
            return .{ .blob = bytes };
        },
        .medium_blob => {
            const bytes = try asBytes(value);
            if (bytes.len > 16_777_215) return error.ValueTooLong;
            return .{ .blob = bytes };
        },
        .long_blob => return .{ .blob = try asBytes(value) },
        else => return coerceValue(col.kind, value),
    }
}

fn checkIntegerRange(kind: storage.Column.Kind, unsigned: bool, v: i64) !void {
    const range = integerRange(kind, unsigned);
    if (v < range.min or v > range.max) return error.IntegerOutOfRange;
}

fn integerRange(kind: storage.Column.Kind, unsigned: bool) struct { min: i64, max: i64 } {
    if (unsigned) {
        return .{ .min = 0, .max = switch (kind) {
            .tiny_int => 255,
            .small_int => 65_535,
            .medium_int => 16_777_215,
            .int => 4_294_967_295,
            .big_int => std.math.maxInt(i64),
            else => std.math.maxInt(i64),
        } };
    }
    return .{ .min = switch (kind) {
        .tiny_int => -128,
        .small_int => -32_768,
        .medium_int => -8_388_608,
        .int => -2_147_483_648,
        .big_int => std.math.minInt(i64),
        else => std.math.minInt(i64),
    }, .max = switch (kind) {
        .tiny_int => 127,
        .small_int => 32_767,
        .medium_int => 8_388_607,
        .int => 2_147_483_647,
        .big_int => std.math.maxInt(i64),
        else => std.math.maxInt(i64),
    } };
}

fn coerceValue(kind: storage.Column.Kind, value: storage.Value) !storage.Value {
    if (value == .null) return .null;
    return switch (kind) {
        .null => .null,
        .tiny_int => blk: {
            const v = try asInt(value);
            if (v < -128 or v > 127) return error.IntegerOutOfRange;
            break :blk .{ .int = v };
        },
        .small_int => blk: {
            const v = try asInt(value);
            if (v < -32768 or v > 32767) return error.IntegerOutOfRange;
            break :blk .{ .int = v };
        },
        .medium_int => blk: {
            const v = try asInt(value);
            if (v < -8_388_608 or v > 8_388_607) return error.IntegerOutOfRange;
            break :blk .{ .int = v };
        },
        .int => .{ .int = try asInt(value) },
        .big_int => .{ .int = try asInt(value) },
        .bool => .{ .bool = try asBool(value) },
        .real => .{ .real = try asReal(value) },
        .decimal => .{ .decimal = try asDecimal(value) },
        .text => .{ .text = try asBytes(value) },
        .tiny_text => blk: {
            const bytes = try asBytes(value);
            if (bytes.len > 255) return error.ValueTooLong;
            break :blk .{ .text = bytes };
        },
        .medium_text => blk: {
            const bytes = try asBytes(value);
            if (bytes.len > 16_777_215) return error.ValueTooLong;
            break :blk .{ .text = bytes };
        },
        .long_text => .{ .text = try asBytes(value) },
        .char => |max_len| blk: {
            const bytes = try asBytes(value);
            if (bytes.len > max_len) return error.ValueTooLong;
            break :blk .{ .text = bytes };
        },
        .binary => |len| blk: {
            const bytes = try asBytes(value);
            if (bytes.len != len) return error.ValueLengthMismatch;
            break :blk .{ .blob = bytes };
        },
        .varchar => |max_len| blk: {
            const bytes = try asBytes(value);
            if (bytes.len > max_len) return error.ValueTooLong;
            break :blk .{ .text = bytes };
        },
        .varbinary => |max_len| blk: {
            const bytes = try asBytes(value);
            if (bytes.len > max_len) return error.ValueTooLong;
            break :blk .{ .blob = bytes };
        },
        .blob => .{ .blob = try asBytes(value) },
        .tiny_blob => blk: {
            const bytes = try asBytes(value);
            if (bytes.len > 255) return error.ValueTooLong;
            break :blk .{ .blob = bytes };
        },
        .medium_blob => blk: {
            const bytes = try asBytes(value);
            if (bytes.len > 16_777_215) return error.ValueTooLong;
            break :blk .{ .blob = bytes };
        },
        .long_blob => .{ .blob = try asBytes(value) },
        .bit => |bits| blk: {
            const v = try asInt(value);
            if (bits < 1 or bits > 64) return error.BadBitWidth;
            if (v < 0) return error.IntegerOutOfRange;
            if (bits < 63 and @as(u64, @intCast(v)) >= (@as(u64, 1) << @intCast(bits))) return error.IntegerOutOfRange;
            break :blk .{ .int = v };
        },
        .date => blk: {
            const bytes = try asBytes(value);
            if (!isDate(bytes)) return error.BadDate;
            break :blk .{ .date = bytes };
        },
        .datetime => blk: {
            const bytes = try asBytes(value);
            if (!isDateTime(bytes)) return error.BadDateTime;
            break :blk .{ .datetime = bytes };
        },
        .time => blk: {
            const bytes = try asBytes(value);
            if (!isTime(bytes)) return error.BadTime;
            break :blk .{ .time = bytes };
        },
        .year => blk: {
            const v = try asInt(value);
            if (v < 0 or v > 9999) return error.BadYear;
            break :blk .{ .year = @intCast(v) };
        },
        .json => blk: {
            const bytes = try asBytes(value);
            if (!isJson(bytes)) return error.BadJson;
            break :blk .{ .json = bytes };
        },
        .enum_values => |allowed| blk: {
            const bytes = try asBytes(value);
            for (allowed) |item| {
                if (std.mem.eql(u8, item, bytes)) break :blk .{ .text = bytes };
            }
            return error.BadEnumValue;
        },
        .set_values => |allowed| blk: {
            const bytes = try asBytes(value);
            var it = std.mem.splitScalar(u8, bytes, ',');
            while (it.next()) |part| {
                var found = false;
                for (allowed) |item| {
                    if (std.mem.eql(u8, item, part)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.BadSetValue;
            }
            break :blk .{ .text = bytes };
        },
    };
}

fn compareOp(left: storage.Value, op: CompareOp, right: storage.Value) bool {
    const cmp = compareValues(left, right);
    return switch (op) {
        .eq => cmp == 0,
        .ne => cmp != 0,
        .lt => cmp < 0,
        .lte => cmp <= 0,
        .gt => cmp > 0,
        .gte => cmp >= 0,
    };
}

fn compareValues(left: storage.Value, right: storage.Value) i8 {
    if (left == .null and right == .null) return 0;
    if (left == .null) return -1;
    if (right == .null) return 1;
    if (numericValue(left)) |l| {
        if (numericValue(right)) |r| return if (l < r) -1 else if (l > r) 1 else 0;
    }
    const l = valueText(left) orelse "";
    const r = valueText(right) orelse "";
    return switch (std.mem.order(u8, l, r)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn valueBytes(allocator: std.mem.Allocator, value: storage.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .int => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .bool => |v| try allocator.dupe(u8, if (v) "1" else "0"),
        .real => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .text => |v| try allocator.dupe(u8, v),
        .decimal => |v| try allocator.dupe(u8, v),
        .blob => |v| try allocator.dupe(u8, v),
        .date => |v| try allocator.dupe(u8, v),
        .datetime => |v| try allocator.dupe(u8, v),
        .time => |v| try allocator.dupe(u8, v),
        .year => |v| try std.fmt.allocPrint(allocator, "{d:0>4}", .{v}),
        .json => |v| try allocator.dupe(u8, v),
    };
}

fn mysqlType(kind: storage.Column.Kind) u8 {
    return switch (kind) {
        .null => 0x06,
        .tiny_int => 0x01,
        .small_int => 0x02,
        .medium_int => 0x09,
        .int => 0x03,
        .big_int => 0x08,
        .bit => 0x10,
        .bool => 0x01,
        .real => 0x05,
        .decimal => 0x00,
        .blob, .tiny_blob, .medium_blob, .long_blob => 0xfc,
        .date => 0x0a,
        .datetime => 0x0c,
        .time => 0x0b,
        .year => 0x0d,
        .text, .tiny_text, .medium_text, .long_text, .char, .binary, .varchar, .varbinary, .json, .enum_values, .set_values => 0xfd,
    };
}

fn valueTypeCode(value: storage.Value) u8 {
    return switch (value) {
        .null => 0x06,
        .int => 0x08,
        .bool => 0x01,
        .real => 0x05,
        .decimal => 0x00,
        .blob => 0xfc,
        .date => 0x0a,
        .datetime => 0x0c,
        .time => 0x0b,
        .year => 0x0d,
        .json => 0xfd,
        .text => 0xfd,
    };
}

fn literalColumnName(value: storage.Value) []const u8 {
    return switch (value) {
        .null => "NULL",
        .int => "literal",
        .bool => "literal",
        .real => "literal",
        .text => "literal",
        .decimal => "literal",
        .blob => "literal",
        .date => "literal",
        .datetime => "literal",
        .time => "literal",
        .year => "literal",
        .json => "literal",
    };
}

fn kindNameAlloc(allocator: std.mem.Allocator, kind: storage.Column.Kind) ![]const u8 {
    return switch (kind) {
        .null => allocator.dupe(u8, "null"),
        .tiny_int => allocator.dupe(u8, "tinyint"),
        .small_int => allocator.dupe(u8, "smallint"),
        .medium_int => allocator.dupe(u8, "mediumint"),
        .int => allocator.dupe(u8, "int"),
        .big_int => allocator.dupe(u8, "bigint"),
        .text => allocator.dupe(u8, "text"),
        .tiny_text => allocator.dupe(u8, "tinytext"),
        .medium_text => allocator.dupe(u8, "mediumtext"),
        .long_text => allocator.dupe(u8, "longtext"),
        .bool => allocator.dupe(u8, "bool"),
        .real => allocator.dupe(u8, "double"),
        .decimal => allocator.dupe(u8, "decimal"),
        .bit => |len| std.fmt.allocPrint(allocator, "bit({d})", .{len}),
        .char => |len| std.fmt.allocPrint(allocator, "char({d})", .{len}),
        .binary => |len| std.fmt.allocPrint(allocator, "binary({d})", .{len}),
        .varchar => |len| std.fmt.allocPrint(allocator, "varchar({d})", .{len}),
        .varbinary => |len| std.fmt.allocPrint(allocator, "varbinary({d})", .{len}),
        .blob => allocator.dupe(u8, "blob"),
        .tiny_blob => allocator.dupe(u8, "tinyblob"),
        .medium_blob => allocator.dupe(u8, "mediumblob"),
        .long_blob => allocator.dupe(u8, "longblob"),
        .date => allocator.dupe(u8, "date"),
        .datetime => allocator.dupe(u8, "datetime"),
        .time => allocator.dupe(u8, "time"),
        .year => allocator.dupe(u8, "year"),
        .json => allocator.dupe(u8, "json"),
        .enum_values => |values| enumSetNameAlloc(allocator, "enum", values),
        .set_values => |values| enumSetNameAlloc(allocator, "set", values),
    };
}

fn columnTypeNameAlloc(allocator: std.mem.Allocator, col: storage.Column) ![]const u8 {
    const base = try kindNameAlloc(allocator, col.kind);
    if (!col.unsigned) return base;
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s} unsigned", .{base});
}

fn columnDataTypeNameAlloc(allocator: std.mem.Allocator, col: storage.Column) ![]const u8 {
    const name: []const u8 = switch (col.kind) {
        .null => "null",
        .tiny_int => "tinyint",
        .small_int => "smallint",
        .medium_int => "mediumint",
        .int => "int",
        .big_int => "bigint",
        .text => "text",
        .tiny_text => "tinytext",
        .medium_text => "mediumtext",
        .long_text => "longtext",
        .bool => "tinyint",
        .real => "double",
        .decimal => "decimal",
        .bit => "bit",
        .char => "char",
        .binary => "binary",
        .varchar => "varchar",
        .varbinary => "varbinary",
        .blob => "blob",
        .tiny_blob => "tinyblob",
        .medium_blob => "mediumblob",
        .long_blob => "longblob",
        .date => "date",
        .datetime => "datetime",
        .time => "time",
        .year => "year",
        .json => "json",
        .enum_values => "enum",
        .set_values => "set",
    };
    return allocator.dupe(u8, name);
}

fn columnCharacterLengthAlloc(allocator: std.mem.Allocator, kind: storage.Column.Kind) !?[]const u8 {
    const len: ?usize = switch (kind) {
        .char, .binary, .varchar, .varbinary => |n| n,
        .tiny_text, .tiny_blob => 255,
        .text, .blob => 65_535,
        .medium_text, .medium_blob => 16_777_215,
        .long_text, .long_blob => 4_294_967_295,
        .json => 4_294_967_295,
        else => null,
    };
    return if (len) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null;
}

fn columnNumericPrecisionAlloc(allocator: std.mem.Allocator, kind: storage.Column.Kind) !?[]const u8 {
    const precision: ?usize = switch (kind) {
        .tiny_int, .bool => 3,
        .small_int => 5,
        .medium_int => 7,
        .int => 10,
        .big_int => 19,
        .bit => |n| n,
        .real => 53,
        .decimal => 10,
        .year => 4,
        else => null,
    };
    return if (precision) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null;
}

fn columnNumericScaleAlloc(allocator: std.mem.Allocator, kind: storage.Column.Kind) !?[]const u8 {
    return switch (kind) {
        .decimal => try allocator.dupe(u8, "0"),
        .real => try allocator.dupe(u8, "0"),
        else => null,
    };
}

fn enumSetNameAlloc(allocator: std.mem.Allocator, name: []const u8, values: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try out.print("{s}(", .{name});
    for (values, 0..) |value, i| {
        if (i != 0) try out.append(',');
        try out.append('\'');
        try out.appendSlice(value);
        try out.append('\'');
    }
    try out.append(')');
    return out.toOwnedSlice();
}

fn columnHasIndex(table: *const storage.Table, column_index: usize) bool {
    for (table.indexes.items) |index| {
        if (indexContainsColumn(index, column_index)) return true;
    }
    return false;
}

fn columnKeyName(table: *const storage.Table, column_index: usize) []const u8 {
    for (table.indexes.items) |index| {
        if (indexContainsColumn(index, column_index)) {
            if (index.primary) return "PRI";
            if (index.unique and index.columns.len == 1) return "UNI";
            return "MUL";
        }
    }
    return "";
}

fn indexContainsColumn(index: storage.Index, column_index: usize) bool {
    for (index.columns) |idx| if (idx == column_index) return true;
    return false;
}

fn isIntegerKind(kind: storage.Column.Kind) bool {
    return switch (kind) {
        .tiny_int, .small_int, .medium_int, .int, .big_int => true,
        else => false,
    };
}

fn asInt(value: storage.Value) !i64 {
    return switch (value) {
        .int => |v| v,
        .bool => |v| @intFromBool(v),
        .real => |v| @intFromFloat(v),
        .year => |v| v,
        else => {
            const text = valueText(value) orelse return error.BadInteger;
            return std.fmt.parseInt(i64, text, 10);
        },
    };
}

fn asBool(value: storage.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        .int => |v| v != 0,
        .real => |v| v != 0,
        else => {
            const text = valueText(value) orelse return error.BadBool;
            if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "on") or std.mem.eql(u8, text, "1")) return true;
            if (std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "off") or std.mem.eql(u8, text, "0")) return false;
            return error.BadBool;
        },
    };
}

fn asReal(value: storage.Value) !f64 {
    return switch (value) {
        .real => |v| v,
        .int => |v| @floatFromInt(v),
        .bool => |v| if (v) 1 else 0,
        else => std.fmt.parseFloat(f64, valueText(value) orelse return error.BadReal),
    };
}

fn asDecimal(value: storage.Value) ![]const u8 {
    const text = valueText(value) orelse return error.BadDecimal;
    _ = try std.fmt.parseFloat(f64, text);
    return text;
}

fn asBytes(value: storage.Value) ![]const u8 {
    return valueText(value) orelse error.BadText;
}

fn numericValue(value: storage.Value) ?f64 {
    return switch (value) {
        .int => |v| @floatFromInt(v),
        .bool => |v| if (v) 1 else 0,
        .real => |v| v,
        else => if (valueText(value)) |text| std.fmt.parseFloat(f64, text) catch null else null,
    };
}

fn valueText(value: storage.Value) ?[]const u8 {
    return switch (value) {
        .null => null,
        .text => |v| v,
        .decimal => |v| v,
        .blob => |v| v,
        .date => |v| v,
        .datetime => |v| v,
        .time => |v| v,
        .json => |v| v,
        else => null,
    };
}

fn isDate(text: []const u8) bool {
    return text.len == 10 and text[4] == '-' and text[7] == '-' and allDigits(text[0..4]) and allDigits(text[5..7]) and allDigits(text[8..10]);
}

fn isDateTime(text: []const u8) bool {
    return text.len == 19 and isDate(text[0..10]) and text[10] == ' ' and text[13] == ':' and text[16] == ':' and allDigits(text[11..13]) and allDigits(text[14..16]) and allDigits(text[17..19]);
}

fn isTime(text: []const u8) bool {
    return text.len == 8 and text[2] == ':' and text[5] == ':' and allDigits(text[0..2]) and allDigits(text[3..5]) and allDigits(text[6..8]);
}

fn isJson(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return true;
    if (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return true;
    if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return true;
    if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') return true;
    _ = std.fmt.parseFloat(f64, trimmed) catch return false;
    return true;
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn likeMatch(text: []const u8, pattern: []const u8) bool {
    return likeMatchAt(text, 0, pattern, 0);
}

fn likeMatchAt(text: []const u8, ti: usize, pattern: []const u8, pi: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '%') {
        var i = ti;
        while (i <= text.len) : (i += 1) {
            if (likeMatchAt(text, i, pattern, pi + 1)) return true;
        }
        return false;
    }
    if (ti >= text.len) return false;
    if (pattern[pi] == '_' or pattern[pi] == text[ti]) return likeMatchAt(text, ti + 1, pattern, pi + 1);
    return false;
}

const TokenKind = enum {
    ident,
    number,
    string,
    comma,
    lparen,
    rparen,
    star,
    plus,
    minus,
    slash,
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    atat,
    eof,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]Token {
    var tokens = std.array_list.Managed(Token).init(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        switch (c) {
            ',' => {
                try tokens.append(.{ .kind = .comma, .text = input[i .. i + 1] });
                i += 1;
            },
            '(' => {
                try tokens.append(.{ .kind = .lparen, .text = input[i .. i + 1] });
                i += 1;
            },
            ')' => {
                try tokens.append(.{ .kind = .rparen, .text = input[i .. i + 1] });
                i += 1;
            },
            '*' => {
                try tokens.append(.{ .kind = .star, .text = input[i .. i + 1] });
                i += 1;
            },
            '+' => {
                try tokens.append(.{ .kind = .plus, .text = input[i .. i + 1] });
                i += 1;
            },
            '-' => {
                if (i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
                    const start = i;
                    i += 1;
                    while (i < input.len and (std.ascii.isDigit(input[i]) or input[i] == '.')) i += 1;
                    try tokens.append(.{ .kind = .number, .text = input[start..i] });
                } else {
                    try tokens.append(.{ .kind = .minus, .text = input[i .. i + 1] });
                    i += 1;
                }
            },
            '/' => {
                try tokens.append(.{ .kind = .slash, .text = input[i .. i + 1] });
                i += 1;
            },
            '=' => {
                try tokens.append(.{ .kind = .eq, .text = input[i .. i + 1] });
                i += 1;
            },
            '!' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try tokens.append(.{ .kind = .ne, .text = input[i .. i + 2] });
                    i += 2;
                } else return error.BadToken;
            },
            '<' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try tokens.append(.{ .kind = .lte, .text = input[i .. i + 2] });
                    i += 2;
                } else if (i + 1 < input.len and input[i + 1] == '>') {
                    try tokens.append(.{ .kind = .ne, .text = input[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(.{ .kind = .lt, .text = input[i .. i + 1] });
                    i += 1;
                }
            },
            '>' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try tokens.append(.{ .kind = .gte, .text = input[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(.{ .kind = .gt, .text = input[i .. i + 1] });
                    i += 1;
                }
            },
            '\'' => {
                const parsed = try parseStringLiteral(allocator, input, i);
                try tokens.append(.{ .kind = .string, .text = parsed.text });
                i = parsed.next;
            },
            '`' => {
                const parsed = try parseQuotedIdentifierPath(allocator, input, i);
                try tokens.append(.{ .kind = .ident, .text = parsed.text });
                i = parsed.next;
            },
            '@' => {
                if (i + 1 < input.len and input[i + 1] == '@') {
                    try tokens.append(.{ .kind = .atat, .text = "@@" });
                    i += 2;
                } else return error.BadToken;
            },
            else => {
                if (std.ascii.isDigit(c)) {
                    const start = i;
                    i += 1;
                    while (i < input.len and (std.ascii.isDigit(input[i]) or input[i] == '.')) i += 1;
                    try tokens.append(.{ .kind = .number, .text = input[start..i] });
                } else if (isIdentStart(c)) {
                    const start = i;
                    i += 1;
                    while (i < input.len and isIdentContinue(input[i])) i += 1;
                    try tokens.append(.{ .kind = .ident, .text = input[start..i] });
                } else return error.BadToken;
            },
        }
    }
    try tokens.append(.{ .kind = .eof, .text = "" });
    return tokens.toOwnedSlice();
}

const ParsedString = struct { text: []const u8, next: usize };

fn parseQuotedIdentifierPath(allocator: std.mem.Allocator, input: []const u8, start_quote: usize) !ParsedString {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i = start_quote;
    while (true) {
        if (i >= input.len or input[i] != '`') return error.UnterminatedIdentifier;
        i += 1;
        const start = i;
        while (i < input.len and input[i] != '`') i += 1;
        if (i >= input.len) return error.UnterminatedIdentifier;
        if (out.items.len != 0) try out.append('.');
        try out.appendSlice(input[start..i]);
        i += 1;
        if (i + 1 >= input.len or input[i] != '.' or input[i + 1] != '`') break;
        i += 1;
    }
    return .{ .text = try out.toOwnedSlice(), .next = i };
}

fn parseStringLiteral(allocator: std.mem.Allocator, input: []const u8, start_quote: usize) !ParsedString {
    var out = std.array_list.Managed(u8).init(allocator);
    var i = start_quote + 1;
    while (i < input.len) {
        const c = input[i];
        if (c == '\'') {
            if (i + 1 < input.len and input[i + 1] == '\'') {
                try out.append('\'');
                i += 2;
                continue;
            }
            return .{ .text = try out.toOwnedSlice(), .next = i + 1 };
        }
        if (c == '\\' and i + 1 < input.len) {
            i += 1;
            try out.append(input[i]);
            i += 1;
            continue;
        }
        try out.append(c);
        i += 1;
    }
    return error.UnterminatedString;
}

const Parser = struct {
    tokens: []const Token,
    index: usize = 0,
    allocator: std.mem.Allocator,

    fn parseStatement(self: *Parser) !Statement {
        if (self.matchKeyword("set")) return .ok;
        if (self.matchKeyword("use")) return .ok;
        if (self.matchKeyword("begin")) return .ok;
        if (self.matchKeyword("commit")) return .ok;
        if (self.matchKeyword("rollback")) return .ok;
        if (self.matchKeyword("start")) {
            try self.expectKeyword("transaction");
            try self.expect(.eof);
            return .ok;
        }
        if (self.matchKeyword("select")) return .{ .select = try self.parseSelect() };
        if (self.matchKeyword("insert")) return .{ .insert = try self.parseInsert(.normal) };
        if (self.matchKeyword("replace")) return .{ .insert = try self.parseInsert(.replace) };
        if (self.matchKeyword("update")) return .{ .update = try self.parseUpdate() };
        if (self.matchKeyword("delete")) return .{ .delete = try self.parseDelete() };
        if (self.matchKeyword("create")) return self.parseCreate();
        if (self.matchKeyword("alter")) return self.parseAlter();
        if (self.matchKeyword("drop")) return self.parseDrop();
        if (self.matchKeyword("truncate")) return .{ .truncate_table = try self.parseTableNameAfterOptionalTable() };
        if (self.matchKeyword("describe") or self.matchKeyword("desc")) return .{ .describe = try self.expectIdentLike() };
        if (self.matchKeyword("show")) return self.parseShow();
        return error.UnsupportedSql;
    }

    fn parseSelect(self: *Parser) !SelectStmt {
        var items = std.array_list.Managed(SelectItem).init(self.allocator);
        while (true) {
            try items.append(try self.parseSelectItem());
            if (!self.match(.comma)) break;
        }
        var table: ?[]const u8 = null;
        var table_alias: ?[]const u8 = null;
        var join: ?JoinSpec = null;
        const conditions: []const Condition = &.{};
        var where_expr: ?*const Expr = null;
        var group_by: []const *const Expr = &.{};
        var having: ?*const Expr = null;
        var order_by: []const OrderBy = &.{};
        var limit: ?Limit = null;
        if (self.matchKeyword("from")) {
            table = try self.expectIdentLike();
            table_alias = try self.parseOptionalAlias();
            if (self.matchKeyword("inner") or self.matchKeyword("join")) {
                if (!std.ascii.eqlIgnoreCase(self.tokens[self.index - 1].text, "join")) try self.expectKeyword("join");
                const right = try self.expectIdentLike();
                const alias = try self.parseOptionalAlias();
                try self.expectKeyword("on");
                join = .{ .kind = .inner, .table = right, .alias = alias, .on = try self.parseExpression() };
            } else if (self.matchKeyword("left")) {
                _ = self.matchKeyword("outer");
                try self.expectKeyword("join");
                const right = try self.expectIdentLike();
                const alias = try self.parseOptionalAlias();
                try self.expectKeyword("on");
                join = .{ .kind = .left, .table = right, .alias = alias, .on = try self.parseExpression() };
            }
            where_expr = try self.parseOptionalWhereExpr();
            if (self.matchKeyword("group")) {
                try self.expectKeyword("by");
                var groups = std.array_list.Managed(*const Expr).init(self.allocator);
                while (true) {
                    try groups.append(try self.parseExpression());
                    if (!self.match(.comma)) break;
                }
                group_by = try groups.toOwnedSlice();
            }
            if (self.matchKeyword("having")) having = try self.parseExpression();
            if (self.matchKeyword("order")) {
                try self.expectKeyword("by");
                var orders = std.array_list.Managed(OrderBy).init(self.allocator);
                while (true) {
                    const expr = try self.parseExpression();
                    var desc = false;
                    if (self.matchKeyword("desc")) desc = true else _ = self.matchKeyword("asc");
                    try orders.append(.{ .expr = expr, .desc = desc });
                    if (!self.match(.comma)) break;
                }
                order_by = try orders.toOwnedSlice();
            }
            limit = try self.parseOptionalLimit();
        }
        try self.expect(.eof);
        return .{ .items = try items.toOwnedSlice(), .table = table, .table_alias = table_alias, .join = join, .conditions = conditions, .where_expr = where_expr, .group_by = group_by, .having = having, .order_by = order_by, .limit = limit };
    }

    fn parseSelectItem(self: *Parser) !SelectItem {
        var item: SelectItem = undefined;
        if (self.match(.star)) {
            item = .{ .expr = .star };
        } else {
            item = .{ .expr = .{ .expr = try self.parseExpression() } };
        }
        if (self.matchKeyword("as")) {
            item.alias = try self.expectIdentLike();
        } else if (self.peek().kind == .ident and !isReserved(self.peek().text)) {
            item.alias = self.next().text;
        }
        return item;
    }

    fn parseInsert(self: *Parser, initial_mode: InsertStmtMode) !InsertStmt {
        var mode = initial_mode;
        if (mode == .normal and self.matchKeyword("ignore")) mode = .ignore;
        try self.expectKeyword("into");
        const table = try self.expectIdentLike();
        var columns: ?[]const []const u8 = null;
        if (self.match(.lparen)) {
            var cols = std.array_list.Managed([]const u8).init(self.allocator);
            while (true) {
                try cols.append(try self.expectIdentLike());
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            columns = try cols.toOwnedSlice();
        }
        try self.expectKeyword("values");
        var rows = std.array_list.Managed([]const storage.Value).init(self.allocator);
        while (true) {
            try self.expect(.lparen);
            var values = std.array_list.Managed(storage.Value).init(self.allocator);
            while (true) {
                try values.append(try self.parseLiteral());
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            try rows.append(try values.toOwnedSlice());
            if (!self.match(.comma)) break;
        }
        var on_duplicate: []const AssignmentAst = &.{};
        if (self.matchKeyword("on")) {
            try self.expectKeyword("duplicate");
            try self.expectKeyword("key");
            try self.expectKeyword("update");
            on_duplicate = try self.parseAssignmentList();
        }
        try self.expect(.eof);
        return .{ .table = table, .columns = columns, .rows = try rows.toOwnedSlice(), .mode = mode, .on_duplicate = on_duplicate };
    }

    fn parseUpdate(self: *Parser) !UpdateStmt {
        const table = try self.expectIdentLike();
        try self.expectKeyword("set");
        const assignments = try self.parseAssignmentList();
        const where_expr = try self.parseOptionalWhereExpr();
        try self.expect(.eof);
        return .{ .table = table, .assignments = assignments, .conditions = &.{}, .where_expr = where_expr };
    }

    fn parseDelete(self: *Parser) !DeleteStmt {
        try self.expectKeyword("from");
        const table = try self.expectIdentLike();
        const where_expr = try self.parseOptionalWhereExpr();
        const limit = try self.parseOptionalLimit();
        try self.expect(.eof);
        return .{ .table = table, .conditions = &.{}, .where_expr = where_expr, .limit = limit };
    }

    fn parseCreate(self: *Parser) !Statement {
        if (self.matchKeyword("database")) {
            _ = self.matchKeyword("if") and self.matchKeyword("not") and self.matchKeyword("exists");
            _ = try self.expectIdentLike();
            try self.consumeRemaining();
            return .ok;
        }
        if (self.matchKeyword("table")) {
            const if_not_exists = self.matchKeyword("if") and self.matchKeyword("not") and self.matchKeyword("exists");
            const name = try self.expectIdentLike();
            try self.expect(.lparen);
            var cols = std.array_list.Managed(CreateColumn).init(self.allocator);
            var indexes = std.array_list.Managed(CreateIndexDef).init(self.allocator);
            var checks = std.array_list.Managed(CreateCheckDef).init(self.allocator);
            while (true) {
                if (self.peekKeyword("constraint")) {
                    _ = self.matchKeyword("constraint");
                    const constraint_name = try self.expectIdentLike();
                    if (self.peekKeyword("check")) {
                        try checks.append(try self.parseCheckConstraint(constraint_name));
                    } else {
                        try indexes.append(try self.parseTableConstraint());
                    }
                } else if (self.peekKeyword("primary") or self.peekKeyword("unique") or self.looksLikeIndexConstraint()) {
                    try indexes.append(try self.parseTableConstraint());
                } else if (self.peekKeyword("check")) {
                    try checks.append(try self.parseCheckConstraint(null));
                } else {
                    try cols.append(try self.parseColumnDefinition());
                }
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            try self.consumeTableOptions();
            try self.expect(.eof);
            return .{ .create_table = .{ .name = name, .columns = try cols.toOwnedSlice(), .indexes = try indexes.toOwnedSlice(), .checks = try checks.toOwnedSlice(), .if_not_exists = if_not_exists } };
        }
        if (self.matchKeyword("unique")) {
            _ = self.matchKeyword("key") or self.matchKeyword("index");
            const name = try self.expectIdentLike();
            try self.expectKeyword("on");
            const table = try self.expectIdentLike();
            const columns = try self.parseColumnNameList();
            try self.expect(.eof);
            return .{ .create_index = .{ .name = name, .table = table, .columns = columns, .unique = true } };
        }
        if (self.matchKeyword("index")) {
            const name = try self.expectIdentLike();
            try self.expectKeyword("on");
            const table = try self.expectIdentLike();
            const columns = try self.parseColumnNameList();
            try self.expect(.eof);
            return .{ .create_index = .{ .name = name, .table = table, .columns = columns } };
        }
        return error.UnsupportedSql;
    }

    fn parseAlter(self: *Parser) !Statement {
        try self.expectKeyword("table");
        const table = try self.expectIdentLike();
        if (self.matchKeyword("add")) {
            if (self.matchKeyword("constraint")) {
                const name = try self.expectIdentLike();
                if (self.peekKeyword("check")) {
                    const check = try self.parseCheckConstraint(name);
                    try self.expect(.eof);
                    return .{ .alter_table = .{ .table = table, .action = .{ .add_check = check } } };
                }
                return error.UnsupportedSql;
            }
            if (self.peekKeyword("check")) {
                const check = try self.parseCheckConstraint(null);
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .add_check = check } } };
            }
            if (self.matchKeyword("column")) {
                const col = try self.parseColumnDefinition();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .add_column = col } } };
            }
            if (self.peekKeyword("primary") or self.peekKeyword("unique") or self.looksLikeIndexConstraint()) {
                const index = try self.parseTableConstraint();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .add_index = index } } };
            }
        }
        if (self.matchKeyword("drop")) {
            if (self.matchKeyword("primary")) {
                try self.expectKeyword("key");
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .drop_primary_key } };
            }
            if (self.matchKeyword("check")) {
                const name = try self.expectIdentLike();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .drop_check = name } } };
            }
            if (self.matchKeyword("column")) {
                const col = try self.expectIdentLike();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .drop_column = col } } };
            }
            if (self.matchKeyword("index") or self.matchKeyword("key")) {
                const name = try self.expectIdentLike();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .drop_index = name } } };
            }
        }
        if (self.matchKeyword("rename")) {
            if (self.matchKeyword("column")) {
                const old_name = try self.expectIdentLike();
                try self.expectKeyword("to");
                const new_name = try self.expectIdentLike();
                try self.expect(.eof);
                return .{ .alter_table = .{ .table = table, .action = .{ .rename_column = .{ .old_name = old_name, .new_name = new_name } } } };
            }
            try self.expectKeyword("to");
            const new_name = try self.expectIdentLike();
            try self.expect(.eof);
            return .{ .alter_table = .{ .table = table, .action = .{ .rename_to = new_name } } };
        }
        if (self.matchKeyword("modify")) {
            _ = self.matchKeyword("column");
            const col = try self.parseColumnDefinition();
            try self.expect(.eof);
            return .{ .alter_table = .{ .table = table, .action = .{ .modify_column = col } } };
        }
        if (self.matchKeyword("change")) {
            _ = self.matchKeyword("column");
            const old_name = try self.expectIdentLike();
            const col = try self.parseColumnDefinition();
            try self.expect(.eof);
            return .{ .alter_table = .{ .table = table, .action = .{ .change_column = .{ .old_name = old_name, .column = col } } } };
        }
        return error.UnsupportedSql;
    }

    fn parseDrop(self: *Parser) !Statement {
        if (self.matchKeyword("table")) {
            const if_exists = self.matchKeyword("if") and self.matchKeyword("exists");
            const table = try self.expectIdentLike();
            try self.expect(.eof);
            return .{ .drop_table = .{ .name = table, .if_exists = if_exists } };
        }
        if (self.matchKeyword("database")) {
            _ = self.matchKeyword("if") and self.matchKeyword("exists");
            _ = try self.expectIdentLike();
            try self.consumeRemaining();
            return .ok;
        }
        try self.expectKeyword("index");
        const name = try self.expectIdentLike();
        try self.expectKeyword("on");
        const table = try self.expectIdentLike();
        try self.expect(.eof);
        return .{ .drop_index = .{ .name = name, .table = table } };
    }

    fn parseShow(self: *Parser) !Statement {
        if (self.matchKeyword("create")) {
            if (self.matchKeyword("database")) {
                const database = try self.expectIdentLike();
                try self.expect(.eof);
                return .{ .show_create_database = database };
            }
            try self.expectKeyword("table");
            const table = try self.expectIdentLike();
            try self.expect(.eof);
            return .{ .show_create_table = table };
        }
        const full = self.matchKeyword("full");
        if (self.matchKeyword("tables")) {
            _ = try self.parseOptionalFromDatabase();
            var pattern = try self.parseOptionalLikePattern();
            if (self.matchKeyword("where")) {
                _ = try self.expectIdentLike();
                try self.expect(.eq);
                pattern = try self.expectStringOrIdent();
            }
            try self.expect(.eof);
            return .{ .show_tables = .{ .pattern = pattern, .full = full } };
        }
        if (self.matchKeyword("databases")) {
            try self.expect(.eof);
            return .show_databases;
        }
        if (self.matchKeyword("variables")) {
            const pattern = try self.parseOptionalLikePattern();
            try self.expect(.eof);
            return .{ .show_variables = pattern };
        }
        if (self.matchKeyword("columns") or self.matchKeyword("fields")) {
            try self.expectKeyword("from");
            const table = try self.expectIdentLike();
            _ = try self.parseOptionalFromDatabase();
            var field: ?[]const u8 = null;
            if (self.matchKeyword("where")) {
                const column = try self.expectIdentLike();
                try self.expect(.eq);
                const value = try self.expectStringOrIdent();
                if (std.ascii.eqlIgnoreCase(column, "field")) field = value;
            }
            try self.expect(.eof);
            return .{ .show_columns = .{ .table = table, .full = full, .field = field } };
        }
        if (self.matchKeyword("index") or self.matchKeyword("indexes") or self.matchKeyword("keys")) {
            try self.expectKeyword("from");
            const table = try self.expectIdentLike();
            _ = try self.parseOptionalFromDatabase();
            var key_name: ?[]const u8 = null;
            if (self.matchKeyword("where")) {
                const column = try self.expectIdentLike();
                try self.expect(.eq);
                const value = try self.expectStringOrIdent();
                if (std.ascii.eqlIgnoreCase(column, "key_name")) key_name = value;
            }
            try self.expect(.eof);
            return .{ .show_index = .{ .table = table, .key_name = key_name } };
        }
        return error.UnsupportedSql;
    }

    fn parseOptionalFromDatabase(self: *Parser) !?[]const u8 {
        if (!self.matchKeyword("from")) return null;
        return try self.expectIdentLike();
    }

    fn looksLikeIndexConstraint(self: *Parser) bool {
        if (!self.peekKeyword("index") and !self.peekKeyword("key")) return false;
        const next_token = self.tokens[@min(self.index + 1, self.tokens.len - 1)];
        if (next_token.kind == .lparen) return true;
        if (next_token.kind == .ident or next_token.kind == .string or next_token.kind == .number) {
            const after = self.tokens[@min(self.index + 2, self.tokens.len - 1)];
            return after.kind == .lparen;
        }
        return false;
    }

    fn parseTableNameAfterOptionalTable(self: *Parser) ![]const u8 {
        _ = self.matchKeyword("table");
        const name = try self.expectIdentLike();
        try self.expect(.eof);
        return name;
    }

    fn parseColumnKind(self: *Parser) !storage.Column.Kind {
        const kind_text = try self.expectIdentLike();
        if (std.ascii.eqlIgnoreCase(kind_text, "tinyint")) {
            try self.consumeOptionalWidth();
            return .tiny_int;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "smallint")) {
            try self.consumeOptionalWidth();
            return .small_int;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "mediumint")) {
            try self.consumeOptionalWidth();
            return .medium_int;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "int") or std.ascii.eqlIgnoreCase(kind_text, "integer")) {
            try self.consumeOptionalWidth();
            return .int;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "bigint")) {
            try self.consumeOptionalWidth();
            return .big_int;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "text")) {
            try self.consumeOptionalWidth();
            return .text;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "tinytext")) return .tiny_text;
        if (std.ascii.eqlIgnoreCase(kind_text, "mediumtext")) return .medium_text;
        if (std.ascii.eqlIgnoreCase(kind_text, "longtext")) return .long_text;
        if (std.ascii.eqlIgnoreCase(kind_text, "null")) return .null;
        if (std.ascii.eqlIgnoreCase(kind_text, "bool") or std.ascii.eqlIgnoreCase(kind_text, "boolean")) return .bool;
        if (std.ascii.eqlIgnoreCase(kind_text, "real") or std.ascii.eqlIgnoreCase(kind_text, "float") or std.ascii.eqlIgnoreCase(kind_text, "double")) {
            try self.consumeOptionalPrecision();
            return .real;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "decimal")) {
            if (self.match(.lparen)) {
                _ = try self.expectNumber();
                if (self.match(.comma)) _ = try self.expectNumber();
                try self.expect(.rparen);
            }
            return .decimal;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "bit")) {
            var len: usize = 1;
            if (self.match(.lparen)) {
                len = try self.expectNumber();
                try self.expect(.rparen);
            }
            if (len < 1 or len > 64) return error.BadBitWidth;
            return .{ .bit = len };
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "char")) {
            try self.expect(.lparen);
            const len = try self.expectNumber();
            try self.expect(.rparen);
            return .{ .char = len };
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "binary")) {
            try self.expect(.lparen);
            const len = try self.expectNumber();
            try self.expect(.rparen);
            return .{ .binary = len };
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "varchar")) {
            try self.expect(.lparen);
            const len = try self.expectNumber();
            try self.expect(.rparen);
            return .{ .varchar = len };
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "varbinary")) {
            try self.expect(.lparen);
            const len = try self.expectNumber();
            try self.expect(.rparen);
            return .{ .varbinary = len };
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "blob")) {
            try self.consumeOptionalWidth();
            return .blob;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "tinyblob")) return .tiny_blob;
        if (std.ascii.eqlIgnoreCase(kind_text, "mediumblob")) return .medium_blob;
        if (std.ascii.eqlIgnoreCase(kind_text, "longblob")) return .long_blob;
        if (std.ascii.eqlIgnoreCase(kind_text, "date")) return .date;
        if (std.ascii.eqlIgnoreCase(kind_text, "datetime") or std.ascii.eqlIgnoreCase(kind_text, "timestamp")) {
            try self.consumeOptionalWidth();
            return .datetime;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "time")) {
            try self.consumeOptionalWidth();
            return .time;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "year")) {
            try self.consumeOptionalWidth();
            return .year;
        }
        if (std.ascii.eqlIgnoreCase(kind_text, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(kind_text, "enum")) return .{ .enum_values = try self.parseStringList() };
        if (std.ascii.eqlIgnoreCase(kind_text, "set")) return .{ .set_values = try self.parseStringList() };
        return error.UnsupportedColumnType;
    }

    fn parseStringList(self: *Parser) ![]const []const u8 {
        try self.expect(.lparen);
        var values = std.array_list.Managed([]const u8).init(self.allocator);
        while (true) {
            const tok = self.next();
            if (tok.kind != .string) return error.ExpectedLiteral;
            try values.append(tok.text);
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return values.toOwnedSlice();
    }

    fn parseColumnDefinition(self: *Parser) !CreateColumn {
        var col = storage.Column{
            .name = try self.expectIdentLike(),
            .kind = try self.parseColumnKind(),
        };
        while (self.peek().kind != .comma and self.peek().kind != .rparen and self.peek().kind != .eof) {
            if (self.matchKeyword("not")) {
                try self.expectKeyword("null");
                col.nullable = false;
            } else if (self.matchKeyword("null")) {
                col.nullable = true;
            } else if (self.matchKeyword("default")) {
                col.default_value = try self.parseDefaultLiteral();
            } else if (self.matchKeyword("unsigned")) {
                if (!isIntegerKind(col.kind)) return error.UnsignedOnlyValidForInteger;
                col.unsigned = true;
            } else if (self.matchKeyword("comment")) {
                _ = try self.expectStringOrIdent();
            } else if (self.matchKeyword("collate") or self.matchKeyword("charset")) {
                _ = try self.expectIdentLike();
            } else if (self.matchKeyword("character")) {
                _ = self.matchKeyword("set");
                _ = try self.expectIdentLike();
            } else if (self.matchKeyword("on")) {
                try self.expectKeyword("update");
                _ = try self.parsePrimary();
            } else if (self.matchKeyword("auto_increment")) {
                col.auto_increment = true;
                col.nullable = false;
            } else if (self.matchKeyword("primary")) {
                try self.expectKeyword("key");
                col.primary = true;
                col.unique = true;
                col.nullable = false;
            } else if (self.matchKeyword("unique")) {
                _ = self.matchKeyword("key") or self.matchKeyword("index");
                col.unique = true;
            } else {
                return error.UnsupportedColumnAttribute;
            }
        }
        return .{ .column = col };
    }

    fn parseTableConstraint(self: *Parser) !CreateIndexDef {
        if (self.matchKeyword("primary")) {
            try self.expectKeyword("key");
            const columns = try self.parseColumnNameList();
            return .{ .name = "PRIMARY", .columns = columns, .unique = true, .primary = true };
        }
        if (self.matchKeyword("unique")) {
            _ = self.matchKeyword("key") or self.matchKeyword("index");
            var name: ?[]const u8 = null;
            if (self.peek().kind == .ident and self.tokens[@min(self.index + 1, self.tokens.len - 1)].kind == .lparen) {
                name = self.next().text;
            }
            const columns = try self.parseColumnNameList();
            return .{ .name = name orelse columns[0], .columns = columns, .unique = true };
        }
        _ = self.matchKeyword("index") or self.matchKeyword("key");
        var name: ?[]const u8 = null;
        if (self.peek().kind == .ident and self.tokens[@min(self.index + 1, self.tokens.len - 1)].kind == .lparen) {
            name = self.next().text;
        }
        const columns = try self.parseColumnNameList();
        return .{ .name = name orelse columns[0], .columns = columns };
    }

    fn parseCheckConstraint(self: *Parser, maybe_name: ?[]const u8) !CreateCheckDef {
        try self.expectKeyword("check");
        try self.expect(.lparen);
        const expr = try self.parseExpression();
        try self.expect(.rparen);
        const expr_sql = try renderExprAlloc(self.allocator, expr);
        return .{ .name = maybe_name orelse try self.autoCheckName(), .expr_sql = expr_sql };
    }

    fn autoCheckName(self: *Parser) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "chk_{d}", .{self.index});
    }

    fn parseAssignmentList(self: *Parser) ![]const AssignmentAst {
        var assignments = std.array_list.Managed(AssignmentAst).init(self.allocator);
        while (true) {
            const col = try self.expectIdentLike();
            try self.expect(.eq);
            try assignments.append(.{ .column = col, .expr = try self.parseExpression() });
            if (!self.match(.comma)) break;
        }
        return assignments.toOwnedSlice();
    }

    fn parseColumnNameList(self: *Parser) ![]const []const u8 {
        try self.expect(.lparen);
        var columns = std.array_list.Managed([]const u8).init(self.allocator);
        while (true) {
            try columns.append(try self.expectIdentLike());
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return columns.toOwnedSlice();
    }

    fn parseDefaultLiteral(self: *Parser) !storage.Value {
        const tok = self.peek();
        if (tok.kind == .ident and (std.ascii.eqlIgnoreCase(tok.text, "current_timestamp") or std.ascii.eqlIgnoreCase(tok.text, "now") or std.ascii.eqlIgnoreCase(tok.text, "current_date"))) {
            _ = self.next();
            if (self.match(.lparen)) try self.expect(.rparen);
            return .{ .text = tok.text };
        }
        return self.parseLiteral();
    }

    fn consumeOptionalWidth(self: *Parser) !void {
        if (!self.match(.lparen)) return;
        _ = try self.expectNumber();
        try self.expect(.rparen);
    }

    fn consumeOptionalPrecision(self: *Parser) !void {
        if (!self.match(.lparen)) return;
        _ = try self.expectNumber();
        if (self.match(.comma)) _ = try self.expectNumber();
        try self.expect(.rparen);
    }

    fn consumeTableOptions(self: *Parser) !void {
        while (self.peek().kind != .eof) {
            _ = self.next();
            if (self.peek().kind == .eq) {
                _ = self.next();
                if (self.peek().kind != .eof) _ = self.next();
            }
        }
    }

    fn consumeRemaining(self: *Parser) !void {
        while (self.peek().kind != .eof) _ = self.next();
    }

    fn parseOptionalAlias(self: *Parser) !?[]const u8 {
        if (self.matchKeyword("as")) return try self.expectIdentLike();
        if (self.peek().kind == .ident and !isReserved(self.peek().text)) return self.next().text;
        return null;
    }

    fn parseOptionalWhereExpr(self: *Parser) !?*const Expr {
        if (!self.matchKeyword("where")) return null;
        return try self.parseExpression();
    }

    fn parseExpression(self: *Parser) anyerror!*const Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) anyerror!*const Expr {
        var expr = try self.parseAnd();
        while (self.matchKeyword("or")) {
            expr = try self.newExpr(.{ .binary = .{ .op = .@"or", .left = expr, .right = try self.parseAnd() } });
        }
        return expr;
    }

    fn parseAnd(self: *Parser) anyerror!*const Expr {
        var expr = try self.parseNot();
        while (self.matchKeyword("and")) {
            expr = try self.newExpr(.{ .binary = .{ .op = .@"and", .left = expr, .right = try self.parseNot() } });
        }
        return expr;
    }

    fn parseNot(self: *Parser) anyerror!*const Expr {
        if (self.matchKeyword("not")) return self.newExpr(.{ .unary = .{ .op = .not, .expr = try self.parseNot() } });
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) anyerror!*const Expr {
        var expr = try self.parseAdd();
        const negated = self.matchKeyword("not");
        if (self.matchKeyword("like")) {
            expr = try self.newExpr(.{ .like = .{ .expr = expr, .pattern = try self.parseAdd(), .negated = negated } });
        } else if (self.matchKeyword("in")) {
            try self.expect(.lparen);
            var values = std.array_list.Managed(*const Expr).init(self.allocator);
            while (true) {
                try values.append(try self.parseExpression());
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            expr = try self.newExpr(.{ .in_list = .{ .expr = expr, .values = try values.toOwnedSlice(), .negated = negated } });
        } else if (negated) {
            return error.UnexpectedToken;
        } else if (self.matchKeyword("is")) {
            const is_negated = self.matchKeyword("not");
            try self.expectKeyword("null");
            expr = try self.newExpr(.{ .is_null = .{ .expr = expr, .negated = is_negated } });
        } else if (self.peek().kind == .eq or self.peek().kind == .ne or self.peek().kind == .lt or self.peek().kind == .lte or self.peek().kind == .gt or self.peek().kind == .gte) {
            const op = try self.parseCompareOp();
            expr = try self.newExpr(.{ .compare = .{ .op = op, .left = expr, .right = try self.parseAdd() } });
        }
        return expr;
    }

    fn parseAdd(self: *Parser) anyerror!*const Expr {
        var expr = try self.parseMul();
        while (self.peek().kind == .plus or self.peek().kind == .minus) {
            const op: BinaryOp = if (self.match(.plus)) .add else blk: {
                try self.expect(.minus);
                break :blk .sub;
            };
            expr = try self.newExpr(.{ .binary = .{ .op = op, .left = expr, .right = try self.parseMul() } });
        }
        return expr;
    }

    fn parseMul(self: *Parser) anyerror!*const Expr {
        var expr = try self.parseUnary();
        while (self.peek().kind == .star or self.peek().kind == .slash) {
            const op: BinaryOp = if (self.match(.star)) .mul else blk: {
                try self.expect(.slash);
                break :blk .div;
            };
            expr = try self.newExpr(.{ .binary = .{ .op = op, .left = expr, .right = try self.parseUnary() } });
        }
        return expr;
    }

    fn parseUnary(self: *Parser) anyerror!*const Expr {
        if (self.match(.minus)) return self.newExpr(.{ .unary = .{ .op = .neg, .expr = try self.parseUnary() } });
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) anyerror!*const Expr {
        if (self.match(.lparen)) {
            const expr = try self.parseExpression();
            try self.expect(.rparen);
            return expr;
        }
        if (self.peek().kind == .number or self.peek().kind == .string) return self.newExpr(.{ .literal = try self.parseLiteral() });
        const tok = self.next();
        if (tok.kind != .ident) return error.ExpectedExpression;
        if (std.ascii.eqlIgnoreCase(tok.text, "null") or std.ascii.eqlIgnoreCase(tok.text, "true") or std.ascii.eqlIgnoreCase(tok.text, "false")) {
            self.index -= 1;
            return self.newExpr(.{ .literal = try self.parseLiteral() });
        }
        if (std.ascii.eqlIgnoreCase(tok.text, "case")) {
            const operand = try self.parseExpression();
            var cases = std.array_list.Managed(CaseArm).init(self.allocator);
            while (self.matchKeyword("when")) {
                const when = try self.parseExpression();
                try self.expectKeyword("then");
                const then_expr = try self.parseExpression();
                try cases.append(.{ .when = when, .then = then_expr });
            }
            var else_expr: ?*const Expr = null;
            if (self.matchKeyword("else")) else_expr = try self.parseExpression();
            try self.expectKeyword("end");
            return self.newExpr(.{ .case_expr = .{ .operand = operand, .cases = try cases.toOwnedSlice(), .else_expr = else_expr } });
        }
        if (std.ascii.eqlIgnoreCase(tok.text, "current_date")) return self.newExpr(.{ .call = .{ .name = tok.text, .args = &.{} } });
        if (self.match(.lparen)) {
            if (std.ascii.eqlIgnoreCase(tok.text, "count") and self.match(.star)) {
                try self.expect(.rparen);
                return self.newExpr(.{ .aggregate = .{ .name = tok.text, .arg = null } });
            }
            var args = std.array_list.Managed(*const Expr).init(self.allocator);
            if (!self.match(.rparen)) {
                while (true) {
                    try args.append(try self.parseExpression());
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rparen);
            }
            const owned_args = try args.toOwnedSlice();
            if (isAggregateName(tok.text)) return self.newExpr(.{ .aggregate = .{ .name = tok.text, .arg = if (owned_args.len == 0) null else owned_args[0] } });
            return self.newExpr(.{ .call = .{ .name = tok.text, .args = owned_args } });
        }
        return self.newExpr(.{ .column = tok.text });
    }

    fn newExpr(self: *Parser, expr: Expr) !*const Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ptr;
    }

    fn parseOptionalWhere(self: *Parser) ![]const Condition {
        if (!self.matchKeyword("where")) return &.{};
        var conds = std.array_list.Managed(Condition).init(self.allocator);
        while (true) {
            const column = try self.expectIdentLike();
            if (self.matchKeyword("like")) {
                const pattern = try self.expectStringOrIdent();
                try conds.append(.{ .like = .{ .column = column, .pattern = pattern } });
            } else if (self.matchKeyword("in")) {
                try self.expect(.lparen);
                var values = std.array_list.Managed(storage.Value).init(self.allocator);
                while (true) {
                    try values.append(try self.parseLiteral());
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rparen);
                try conds.append(.{ .in_list = .{ .column = column, .values = try values.toOwnedSlice() } });
            } else if (self.matchKeyword("is")) {
                const negated = self.matchKeyword("not");
                try self.expectKeyword("null");
                try conds.append(.{ .is_null = .{ .column = column, .negated = negated } });
            } else {
                const op = try self.parseCompareOp();
                try conds.append(.{ .compare = .{ .column = column, .op = op, .value = try self.parseLiteral() } });
            }
            if (!self.matchKeyword("and")) break;
        }
        return conds.toOwnedSlice();
    }

    fn parseOptionalLimit(self: *Parser) !?Limit {
        if (!self.matchKeyword("limit")) return null;
        const first = try self.expectNumber();
        if (self.match(.comma)) return .{ .offset = first, .count = try self.expectNumber() };
        return .{ .count = first };
    }

    fn parseOptionalLikePattern(self: *Parser) !?[]const u8 {
        if (!self.matchKeyword("like")) return null;
        return try self.expectStringOrIdent();
    }

    fn parseCompareOp(self: *Parser) !CompareOp {
        return switch (self.next().kind) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .lte => .lte,
            .gt => .gt,
            .gte => .gte,
            else => error.ExpectedComparison,
        };
    }

    fn parseLiteral(self: *Parser) !storage.Value {
        const tok = self.next();
        return switch (tok.kind) {
            .number => if (std.mem.indexOfScalar(u8, tok.text, '.') != null)
                .{ .real = try std.fmt.parseFloat(f64, tok.text) }
            else
                .{ .int = try std.fmt.parseInt(i64, tok.text, 10) },
            .string => .{ .text = tok.text },
            .ident => if (std.ascii.eqlIgnoreCase(tok.text, "null"))
                .null
            else if (std.ascii.eqlIgnoreCase(tok.text, "true"))
                .{ .bool = true }
            else if (std.ascii.eqlIgnoreCase(tok.text, "false"))
                .{ .bool = false }
            else
                .{ .text = tok.text },
            else => error.ExpectedLiteral,
        };
    }

    fn expectNumber(self: *Parser) !usize {
        const tok = self.next();
        if (tok.kind != .number) return error.ExpectedNumber;
        return std.fmt.parseInt(usize, tok.text, 10);
    }

    fn expectStringOrIdent(self: *Parser) ![]const u8 {
        const tok = self.next();
        return switch (tok.kind) {
            .string, .ident, .number => tok.text,
            else => error.ExpectedLiteral,
        };
    }

    fn expectIdentLike(self: *Parser) ![]const u8 {
        const tok = self.next();
        return switch (tok.kind) {
            .ident, .number, .string => tok.text,
            else => error.ExpectedIdentifier,
        };
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) !void {
        if (!self.matchKeyword(keyword)) return error.ExpectedKeyword;
    }

    fn expect(self: *Parser, kind: TokenKind) !void {
        if (!self.match(kind)) return error.UnexpectedToken;
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        const tok = self.peek();
        if (tok.kind != .ident or !std.ascii.eqlIgnoreCase(tok.text, keyword)) return false;
        self.index += 1;
        return true;
    }

    fn peekKeyword(self: *Parser, keyword: []const u8) bool {
        const tok = self.peek();
        return tok.kind == .ident and std.ascii.eqlIgnoreCase(tok.text, keyword);
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.peek().kind != kind) return false;
        self.index += 1;
        return true;
    }

    fn next(self: *Parser) Token {
        const tok = self.peek();
        if (self.index < self.tokens.len) self.index += 1;
        return tok;
    }

    fn peek(self: *Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.';
}

fn isReserved(text: []const u8) bool {
    const words = [_][]const u8{ "from", "where", "order", "limit", "as", "and", "or", "not", "desc", "asc", "inner", "left", "outer", "join", "on", "group", "having" };
    for (words) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    return false;
}

fn isAggregateName(text: []const u8) bool {
    const names = [_][]const u8{ "count", "sum", "avg", "min", "max" };
    for (names) |name| if (std.ascii.eqlIgnoreCase(text, name)) return true;
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn trimSemi(text: []const u8) []const u8 {
    var out = text;
    while (out.len > 0 and out[out.len - 1] == ';') out = out[0 .. out.len - 1];
    return std.mem.trim(u8, out, " \t\r\n");
}

test "sql extended types and syntax" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-sql-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
    defer db.deinit();

    var r = try execute(allocator, &db, "SELECT VERSION()");
    try std.testing.expectEqualStrings("8.0.46-mysqlzig", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "create table typed (id int, ok bool, score double, price decimal(10,2), name varchar(8), payload blob, d date, ts datetime)");
    r.deinit(allocator);
    r = try execute(allocator, &db, "insert into typed values (1, true, 1.5, '12.30', 'alpha', 'bytes', '2026-07-07', '2026-07-07 12:00:00'), (2, false, 2.5, '3.14', 'beta', 'raw', '2026-07-08', '2026-07-08 13:00:00')");
    try std.testing.expectEqual(@as(u64, 2), r.affected_rows);
    r.deinit(allocator);
    r = try execute(allocator, &db, "update typed set score = 1.5 where id = 1");
    try std.testing.expectEqual(@as(u64, 0), r.affected_rows);
    r.deinit(allocator);
    r = try execute(allocator, &db, "update typed set score = 3.5 where id = 1");
    try std.testing.expectEqual(@as(u64, 1), r.affected_rows);
    r.deinit(allocator);
    r = try execute(allocator, &db, "select count(*) as c from typed where name like 'a%'");
    try std.testing.expectEqualStrings("1", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "select id as ident, name from typed where id in (1, 3) and ok is not null order by id desc");
    try std.testing.expectEqualStrings("ident", r.columns[0].name);
    try std.testing.expectEqualStrings("1", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "select name from typed where name not like 'a%' order by name asc");
    try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    try std.testing.expectEqualStrings("beta", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "select name from typed where id not in (1) order by name asc");
    try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    try std.testing.expectEqualStrings("beta", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "delete from typed where id = 2 limit 1");
    try std.testing.expectEqual(@as(u64, 1), r.affected_rows);
    r.deinit(allocator);
    r = try execute(allocator, &db, "describe typed");
    try std.testing.expectEqualStrings("varchar(8)", r.rows[4].values[1].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "show create table typed");
    try std.testing.expect(std.mem.indexOf(u8, r.rows[0].values[1].?, "varchar(8)") != null);
    r.deinit(allocator);
    r = try execute(allocator, &db, "show tables like 'typ%'");
    try std.testing.expectEqualStrings("typed", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "truncate table typed");
    r.deinit(allocator);
    r = try execute(allocator, &db, "select count(*) from typed");
    try std.testing.expectEqualStrings("0", r.rows[0].values[0].?);
    r.deinit(allocator);
    r = try execute(allocator, &db, "drop table typed");
    r.deinit(allocator);
    try std.testing.expect(db.findTable("typed") == null);
}

test "sql small app completeness features" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-small-app-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
        defer db.deinit();

        var r = try execute(allocator, &db, "create table users (id int auto_increment, email varchar(32) not null, age smallint not null default 18, role enum('admin','user'), flags set('a','b'), profile json, born date, at time, yy year, cc char(3), raw varbinary(4), primary key(id), unique key uq_email(email))");
        r.deinit(allocator);
        r = try execute(allocator, &db, "insert into users (email, role, flags, profile, born, at, yy, cc, raw) values ('A@X.COM', 'admin', 'a,b', '{\"ok\":true}', '2026-07-07', '12:00:01', 2026, 'abc', 'bin'), ('b@x.com', 'user', 'a', 'null', '2026-07-08', '13:00:02', 2025, 'xy', 'zz')");
        r.deinit(allocator);
        try std.testing.expectError(error.UniqueConstraintViolation, execute(allocator, &db, "insert into users (email) values ('A@X.COM')"));

        r = try execute(allocator, &db, "alter table users add column nickname varchar(8) default 'anon'");
        r.deinit(allocator);
        r = try execute(allocator, &db, "alter table users add index idx_age(age)");
        r.deinit(allocator);
        r = try execute(allocator, &db, "create table orders (uid int, total double)");
        r.deinit(allocator);
        r = try execute(allocator, &db, "insert into orders values (1, 10.5), (1, 2.5), (2, 7.0)");
        r.deinit(allocator);
        r = try execute(allocator, &db, "create table `rare_mine_1` (`layer` int,`index` int,`content` Blob )");
        r.deinit(allocator);
        r = try execute(allocator, &db, "show columns from `rare_mine_1` from `main` where Field = 'index'");
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("index", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "show indexes from `rare_mine_1` from `main` where Key_name = 'layer_index'");
        try std.testing.expectEqual(@as(usize, 0), r.rows.len);
        r.deinit(allocator);
        r = try execute(allocator, &db, "create unique index layer_index on `rare_mine_1`(`layer`,`index`)");
        r.deinit(allocator);
        r = try execute(allocator, &db, "show indexes from `rare_mine_1` from `main` where Key_name = 'layer_index'");
        try std.testing.expectEqual(@as(usize, 2), r.rows.len);
        r.deinit(allocator);
        r = try execute(allocator, &db, "create table `player_datas_1` (`uuid` varchar(255),`content` MediumBlob,`updated_at` bigint, primary key(`uuid`))");
        r.deinit(allocator);
        r = try execute(allocator, &db, "insert into `player_datas_1` (`uuid`,`content`,`updated_at`) values ('113.entire_mail','{}',1)");
        r.deinit(allocator);
        r = try execute(allocator, &db, "select * from `player_datas_1` where (`uuid` = '113.entire_mail') order by `player_datas_1`.`uuid` asc limit 1");
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("113.entire_mail", r.rows[0].values[0].?);
        r.deinit(allocator);

        r = try execute(allocator, &db, "select email as e from users where email = 'b@x.com' or not (age < 18) order by e desc");
        try std.testing.expectEqualStrings("e", r.columns[0].name);
        try std.testing.expectEqual(@as(usize, 2), r.rows.len);
        r.deinit(allocator);

        r = try execute(allocator, &db, "select lower(email) as le, length(email) as ln, concat(role, flags) as c, abs(-3) as a, round(1.6) as rr, coalesce(null, nickname) as n from users where id = 1");
        try std.testing.expectEqualStrings("a@x.com", r.rows[0].values[0].?);
        try std.testing.expectEqualStrings("7", r.rows[0].values[1].?);
        try std.testing.expectEqualStrings("admina,b", r.rows[0].values[2].?);
        try std.testing.expectEqualStrings("3", r.rows[0].values[3].?);
        try std.testing.expectEqualStrings("2", r.rows[0].values[4].?);
        try std.testing.expectEqualStrings("anon", r.rows[0].values[5].?);
        r.deinit(allocator);

        r = try execute(allocator, &db, "select u.email, sum(o.total) as total, count(*) as c from users u left join orders o on u.id = o.uid group by u.email having sum(o.total) > 10");
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("A@X.COM", r.rows[0].values[0].?);
        r.deinit(allocator);

        r = try execute(allocator, &db, "select table_name from information_schema.tables where table_name = 'users'");
        try std.testing.expectEqualStrings("users", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "SELECT SCHEMA_NAME from Information_schema.SCHEMATA where SCHEMA_NAME LIKE 'main%' ORDER BY SCHEMA_NAME='main' DESC limit 1");
        try std.testing.expectEqualStrings("main", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'main' AND table_name = 'users' AND table_type = 'BASE TABLE'");
        try std.testing.expectEqualStrings("1", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "SELECT column_name, column_default, is_nullable = 'YES', data_type, character_maximum_length, column_type, column_key, extra, column_comment, numeric_precision, numeric_scale, datetime_precision FROM information_schema.columns WHERE table_schema = 'main' AND table_name = 'users' ORDER BY ordinal_position");
        try std.testing.expectEqualStrings("id", r.rows[0].values[0].?);
        try std.testing.expect(r.rows[0].values[11] == null);
        r.deinit(allocator);
        r = try execute(allocator, &db, "describe users");
        try std.testing.expectEqualStrings("PRI", r.rows[0].values[3].?);
        try std.testing.expectEqualStrings("auto_increment", r.rows[0].values[5].?);
        r.deinit(allocator);
        try db.flush();
    }

    {
        var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
        defer db.deinit();
        var r = try execute(allocator, &db, "select count(*) from users");
        try std.testing.expectEqualStrings("2", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "show create table users");
        try std.testing.expect(std.mem.indexOf(u8, r.rows[0].values[1].?, "AUTO_INCREMENT") != null);
        r.deinit(allocator);
    }
}

test "sql ddl constraints and unsigned extended types" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-ddl-types-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
        defer db.deinit();

        var r = try execute(allocator, &db, "create table ext (id int unsigned auto_increment, m mediumint unsigned not null, bits bit(3), bin binary(4), tt tinytext, tb tinyblob, mt mediumtext, mb mediumblob, lt longtext, lb longblob, primary key(id), check (m <= 16777215 and bits < 8))");
        r.deinit(allocator);
        r = try execute(allocator, &db, "insert into ext (m, bits, bin, tt, tb, mt, mb, lt, lb) values (16777215, 7, 'ab', 'tiny', 'blob', 'medium text', 'medium blob', 'long text', 'long blob')");
        r.deinit(allocator);
        try std.testing.expectError(error.IntegerOutOfRange, execute(allocator, &db, "insert into ext (m, bits, bin) values (-1, 1, 'ab')"));
        try std.testing.expectError(error.IntegerOutOfRange, execute(allocator, &db, "insert into ext (m, bits, bin) values (1, 8, 'ab')"));
        try std.testing.expectError(error.ValueTooLong, execute(allocator, &db, "insert into ext (m, bits, bin) values (1, 1, 'abcde')"));

        const table = db.findTable("ext").?;
        try std.testing.expectEqual(@as(usize, 4), table.rows.items[0].values[3].blob.len);
        try std.testing.expectEqual(@as(u8, 0), table.rows.items[0].values[3].blob[2]);
        try std.testing.expect(table.columns[1].unsigned);

        try std.testing.expectError(error.IntegerOutOfRange, execute(allocator, &db, "alter table ext modify column m mediumint not null"));
        r = try execute(allocator, &db, "alter table ext rename column tt to tiny_t");
        r.deinit(allocator);
        r = try execute(allocator, &db, "alter table ext modify column m mediumint unsigned not null");
        r.deinit(allocator);
        r = try execute(allocator, &db, "alter table ext change column tiny_t tiny_t2 tinytext");
        r.deinit(allocator);
        r = try execute(allocator, &db, "alter table ext add constraint chk_m check (m >= 1)");
        r.deinit(allocator);
        try std.testing.expectError(error.CheckConstraintViolation, execute(allocator, &db, "update ext set m = 0 where id = 1"));
        r = try execute(allocator, &db, "alter table ext drop check chk_m");
        r.deinit(allocator);
        r = try execute(allocator, &db, "alter table ext drop primary key");
        r.deinit(allocator);
        r = try execute(allocator, &db, "insert into ext (id, m, bits, bin) values (1, 2, 2, 'zz')");
        r.deinit(allocator);

        r = try execute(allocator, &db, "describe ext");
        try std.testing.expectEqualStrings("int unsigned", r.rows[0].values[1].?);
        try std.testing.expectEqualStrings("mediumint unsigned", r.rows[1].values[1].?);
        try std.testing.expectEqualStrings("bit(3)", r.rows[2].values[1].?);
        try std.testing.expectEqualStrings("binary(4)", r.rows[3].values[1].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "show create table ext");
        try std.testing.expect(std.mem.indexOf(u8, r.rows[0].values[1].?, "CHECK") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.rows[0].values[1].?, "`tiny_t2` tinytext") != null);
        r.deinit(allocator);
        try db.flush();
    }

    {
        var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
        defer db.deinit();
        var r = try execute(allocator, &db, "select count(*) from ext");
        try std.testing.expectEqualStrings("2", r.rows[0].values[0].?);
        r.deinit(allocator);
        r = try execute(allocator, &db, "select data_type from information_schema.columns where table_name = 'ext' and column_name = 'm'");
        try std.testing.expectEqualStrings("mediumint unsigned", r.rows[0].values[0].?);
        r.deinit(allocator);
    }
}

test "select supports multiple order by expressions" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-order-by-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
    defer db.deinit();
    var r = try execute(allocator, &db, "create table game_versions (version varchar(16), white_device_only bool, small_update_type int, created_at int)");
    r.deinit(allocator);
    r = try execute(allocator, &db, "insert into game_versions values ('2.0', false, 1, 10), ('1.0', false, 1, 10), ('3.0', false, 4, 20)");
    r.deinit(allocator);
    r = try execute(allocator, &db, "SELECT * FROM `game_versions` WHERE (white_device_only = false and small_update_type != 4) ORDER BY created_at DESC,`game_versions`.`version` ASC LIMIT 1");
    defer r.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    try std.testing.expectEqualStrings("1.0", r.rows[0].values[0].?);
}

test "select uses a single-column index outside the first table column" {
    const allocator = std.testing.allocator;
    const path = "mysqlzig-non-first-index-test.dump";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var db = try storage.Storage.init(allocator, io, 1024 * 1024, path);
    defer db.deinit();

    var r = try execute(allocator, &db, "create table white_devices (id int primary key, name varchar(32), device_id varchar(64), is_delete bool, unique index did (device_id))");
    r.deinit(allocator);
    r = try execute(allocator, &db, "insert into white_devices values (1, 'allowed', '', false), (2, 'deleted', 'old-device', true)");
    r.deinit(allocator);
    r = try execute(allocator, &db, "SELECT * FROM white_devices WHERE (device_id = '' and is_delete = false) ORDER BY white_devices.id ASC LIMIT 1");
    defer r.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    try std.testing.expectEqualStrings("1", r.rows[0].values[0].?);
    try std.testing.expectEqualStrings("allowed", r.rows[0].values[1].?);
}
