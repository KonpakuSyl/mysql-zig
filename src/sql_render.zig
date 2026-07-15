const std = @import("std");
const storage = @import("storage.zig");
const ast = @import("sql_ast.zig");
const Expr = ast.Expr;

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

pub fn renderExprAlloc(allocator: std.mem.Allocator, expr: *const Expr) ![]const u8 {
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
