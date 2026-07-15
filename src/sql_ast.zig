const storage = @import("storage.zig");

pub const CompareOp = enum { eq, ne, lt, lte, gt, gte };

pub const BinaryOp = enum { @"and", @"or", add, sub, mul, div };
pub const UnaryOp = enum { not, neg };

pub const Expr = union(enum) {
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

pub const CaseArm = struct {
    when: *const Expr,
    then: *const Expr,
};

pub const Condition = union(enum) {
    compare: struct { column: []const u8, op: CompareOp, value: storage.Value },
    like: struct { column: []const u8, pattern: []const u8 },
    in_list: struct { column: []const u8, values: []const storage.Value },
    is_null: struct { column: []const u8, negated: bool },
};

pub const SelectExpr = union(enum) {
    star,
    expr: *const Expr,
};

pub const SelectItem = struct {
    expr: SelectExpr,
    alias: ?[]const u8 = null,
};

pub const OrderBy = struct {
    expr: *const Expr,
    desc: bool = false,
};

pub const JoinKind = enum { inner, left };

pub const JoinSpec = struct {
    kind: JoinKind,
    table: []const u8,
    alias: ?[]const u8 = null,
    on: *const Expr,
};

pub const Limit = struct {
    offset: usize = 0,
    count: usize,
};

pub const InsertStmtMode = enum { normal, ignore, replace };

pub const AssignmentAst = struct {
    column: []const u8,
    expr: *const Expr,
};

pub const CreateColumn = struct {
    column: storage.Column,
};

pub const CreateIndexDef = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool = false,
    primary: bool = false,
};

pub const CreateCheckDef = struct {
    name: []const u8,
    expr_sql: []const u8,
};

pub const AlterAction = union(enum) {
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

pub const SelectStmt = struct {
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

pub const InsertStmt = struct {
    table: []const u8,
    columns: ?[]const []const u8,
    rows: []const []const storage.Value,
    mode: InsertStmtMode = .normal,
    on_duplicate: []const AssignmentAst = &.{},
};

pub const UpdateStmt = struct {
    table: []const u8,
    assignments: []const AssignmentAst,
    conditions: []const Condition,
    where_expr: ?*const Expr = null,
};

pub const DeleteStmt = struct {
    table: []const u8,
    conditions: []const Condition,
    where_expr: ?*const Expr = null,
    limit: ?Limit = null,
};

pub const Statement = union(enum) {
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
