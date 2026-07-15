const std = @import("std");
const storage = @import("storage.zig");
const ast = @import("sql_ast.zig");
const render = @import("sql_render.zig");

const CompareOp = ast.CompareOp;
const BinaryOp = ast.BinaryOp;
const UnaryOp = ast.UnaryOp;
const Expr = ast.Expr;
const CaseArm = ast.CaseArm;
const Condition = ast.Condition;
const SelectExpr = ast.SelectExpr;
const SelectItem = ast.SelectItem;
const OrderBy = ast.OrderBy;
const JoinKind = ast.JoinKind;
const JoinSpec = ast.JoinSpec;
const Limit = ast.Limit;
const InsertStmtMode = ast.InsertStmtMode;
const AssignmentAst = ast.AssignmentAst;
const CreateColumn = ast.CreateColumn;
const CreateIndexDef = ast.CreateIndexDef;
const CreateCheckDef = ast.CreateCheckDef;
const AlterAction = ast.AlterAction;
const SelectStmt = ast.SelectStmt;
const InsertStmt = ast.InsertStmt;
const UpdateStmt = ast.UpdateStmt;
const DeleteStmt = ast.DeleteStmt;
const Statement = ast.Statement;

fn isIntegerKind(kind: storage.Column.Kind) bool {
    return switch (kind) {
        .tiny_int, .small_int, .medium_int, .int, .big_int => true,
        else => false,
    };
}

pub const TokenKind = enum {
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

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]Token {
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
                try tokens.append(.{ .kind = .minus, .text = input[i .. i + 1] });
                i += 1;
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

pub const Parser = struct {
    tokens: []const Token,
    index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn parseStatement(self: *Parser) !Statement {
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
        const expr_sql = try render.renderExprAlloc(self.allocator, expr);
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

    pub fn parseExpression(self: *Parser) anyerror!*const Expr {
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
        if (self.peek().kind == .minus and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].kind == .number) {
            return self.newExpr(.{ .literal = try self.parseLiteral() });
        }
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
        if (std.ascii.eqlIgnoreCase(tok.text, "current_date") or std.ascii.eqlIgnoreCase(tok.text, "current_timestamp")) return self.newExpr(.{ .call = .{ .name = tok.text, .args = &.{} } });
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
        if (self.matchKeyword("offset")) return .{ .offset = try self.expectNumber(), .count = first };
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
        const negative = self.match(.minus);
        const tok = self.next();
        if (negative and tok.kind != .number) return error.ExpectedLiteral;
        return switch (tok.kind) {
            .number => if (std.mem.indexOfScalar(u8, tok.text, '.') != null) .{
                .real = @as(f64, if (negative) -1.0 else 1.0) * try std.fmt.parseFloat(f64, tok.text),
            } else if (negative) blk: {
                const magnitude = try std.fmt.parseInt(u64, tok.text, 10);
                const min_magnitude = @as(u64, 1) << 63;
                if (magnitude > min_magnitude) return error.Overflow;
                break :blk .{ .int = if (magnitude == min_magnitude) std.math.minInt(i64) else -@as(i64, @intCast(magnitude)) };
            } else .{
                .int = try std.fmt.parseInt(i64, tok.text, 10),
            },
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

    pub fn expect(self: *Parser, kind: TokenKind) !void {
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
    const words = [_][]const u8{ "from", "where", "order", "limit", "offset", "as", "and", "or", "not", "desc", "asc", "inner", "left", "outer", "join", "on", "group", "having" };
    for (words) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    return false;
}

fn isAggregateName(text: []const u8) bool {
    const names = [_][]const u8{ "count", "sum", "avg", "min", "max" };
    for (names) |name| if (std.ascii.eqlIgnoreCase(text, name)) return true;
    return false;
}
