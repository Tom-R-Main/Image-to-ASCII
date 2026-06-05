//! Hand-written lexer for the Mermaid flowchart subset.
//!
//! Design notes:
//! - Single forward cursor over UTF-8 source. Tokens carry 1-based line/column
//!   spans so the parser can produce precise diagnostics.
//! - `%%` comments are stripped to end of line.
//! - Shape/label *contents* are NOT tokenized here. Free text inside `[...]`,
//!   `(...)`, `{...}` and pipe labels can contain spaces and punctuation, so the
//!   parser reads it raw via `readLabel` after seeing the opening delimiter.
//!   That keeps the token grammar small and avoids mis-splitting label words.
//! - Edge operators are fully classified into stroke/arrow/length by the lexer,
//!   because that is where the character run is in hand. This also lets us match
//!   Mermaid's `A---oB` / `A---xB` trap exactly: a trailing `o`/`x` glued to the
//!   dash run is the edge's endpoint decoration, not part of the next node id.

const std = @import("std");
const ir = @import("../ir/graph.zig");

pub const TokenKind = enum {
    identifier,
    string, // quoted "..." (quotes stripped in lexeme)
    lbracket, // [
    rbracket, // ]
    lparen, // (
    rparen, // )
    ldparen, // ((
    rdparen, // ))
    lbrace, // {
    rbrace, // }
    pipe, // |
    edge, // an edge operator; see Token.edge
    newline, // statement separator (newline or ';')
    eof,
};

pub const EdgeOp = struct {
    line: ir.LineKind = .solid,
    arrow: ir.ArrowKind = .arrow,
    /// Count of dash/equals characters in the run; the parser derives min_len.
    length: u8 = 2,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    column: u32,
    edge: EdgeOp = .{},
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    fn peekByte(self: *const Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekByteAt(self: *const Lexer, ahead: usize) ?u8 {
        const i = self.pos + ahead;
        if (i >= self.source.len) return null;
        return self.source[i];
    }

    fn advanceByte(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        if (self.source[self.pos] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.pos += 1;
    }

    /// Skip spaces, tabs, carriage returns, and `%%` comments — but NOT newlines,
    /// which are significant statement separators.
    fn skipTrivia(self: *Lexer) void {
        while (self.peekByte()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advanceByte();
            } else if (c == '%' and self.peekByteAt(1) == '%') {
                while (self.peekByte()) |cc| {
                    if (cc == '\n') break;
                    self.advanceByte();
                }
            } else break;
        }
    }

    pub fn next(self: *Lexer) !Token {
        self.skipTrivia();
        const start_line = self.line;
        const start_col = self.column;
        const c = self.peekByte() orelse return self.make(.eof, self.source[self.pos..self.pos], start_line, start_col);

        if (c == '\n' or c == ';') {
            const start = self.pos;
            self.advanceByte();
            return self.make(.newline, self.source[start..self.pos], start_line, start_col);
        }

        if (c == '"') return self.lexString(start_line, start_col);

        if (isEdgeStart(c)) {
            if (self.tryLexEdge(start_line, start_col)) |tok| return tok;
            // Not a valid edge run (e.g. a lone '-'); fall through to error.
        }

        switch (c) {
            '[' => return self.single(.lbracket, start_line, start_col),
            ']' => return self.single(.rbracket, start_line, start_col),
            '{' => return self.single(.lbrace, start_line, start_col),
            '}' => return self.single(.rbrace, start_line, start_col),
            '|' => return self.single(.pipe, start_line, start_col),
            '(' => {
                if (self.peekByteAt(1) == '(') {
                    const start = self.pos;
                    self.advanceByte();
                    self.advanceByte();
                    return self.make(.ldparen, self.source[start..self.pos], start_line, start_col);
                }
                return self.single(.lparen, start_line, start_col);
            },
            ')' => {
                if (self.peekByteAt(1) == ')') {
                    const start = self.pos;
                    self.advanceByte();
                    self.advanceByte();
                    return self.make(.rdparen, self.source[start..self.pos], start_line, start_col);
                }
                return self.single(.rparen, start_line, start_col);
            },
            else => {},
        }

        if (isIdentStart(c)) return self.lexIdentifier(start_line, start_col);

        return error.UnexpectedByte;
    }

    fn single(self: *Lexer, kind: TokenKind, line: u32, col: u32) Token {
        const start = self.pos;
        self.advanceByte();
        return self.make(kind, self.source[start..self.pos], line, col);
    }

    fn make(self: *const Lexer, kind: TokenKind, lexeme: []const u8, line: u32, col: u32) Token {
        _ = self;
        return .{ .kind = kind, .lexeme = lexeme, .line = line, .column = col };
    }

    fn lexIdentifier(self: *Lexer, line: u32, col: u32) Token {
        const start = self.pos;
        while (self.peekByte()) |c| {
            if (!isIdentPart(c)) break;
            self.advanceByte();
        }
        return self.make(.identifier, self.source[start..self.pos], line, col);
    }

    fn lexString(self: *Lexer, line: u32, col: u32) !Token {
        self.advanceByte(); // opening quote
        const start = self.pos;
        while (self.peekByte()) |c| {
            if (c == '"') break;
            self.advanceByte();
        }
        if (self.peekByte() == null) return error.UnterminatedString;
        const lexeme = self.source[start..self.pos];
        self.advanceByte(); // closing quote
        return self.make(.string, lexeme, line, col);
    }

    /// Scan an edge operator run. Returns null (without consuming) if the run is
    /// not a valid edge (e.g. a single `-`).
    fn tryLexEdge(self: *Lexer, line: u32, col: u32) ?Token {
        const start = self.pos;
        var dashes: u8 = 0;
        var has_eq = false;
        var has_dot = false;

        // Stroke body: a run of '-', '.', '=' (dotted edges interleave dots).
        while (self.peekByte()) |c| {
            switch (c) {
                '-' => dashes +|= 1,
                '=' => {
                    has_eq = true;
                    dashes +|= 1;
                },
                '.' => has_dot = true,
                else => break,
            }
            self.advanceByte();
        }

        // Endpoint decoration glued directly to the run.
        var arrow: ir.ArrowKind = .none;
        if (self.peekByte()) |c| switch (c) {
            '>' => {
                arrow = .arrow;
                self.advanceByte();
            },
            'o' => {
                arrow = .circle;
                self.advanceByte();
            },
            'x' => {
                arrow = .cross;
                self.advanceByte();
            },
            else => {},
        };

        const run_len = self.pos - start;
        // A valid edge needs at least two stroke chars (`--`, `==`, `-.-`) or a
        // shorter run that ends in an explicit decoration (`-->` has 2 dashes,
        // but guard against a lone `-`).
        const valid = (dashes >= 2) or (dashes >= 1 and arrow != .none and run_len >= 2);
        if (!valid) {
            // Roll the cursor back; the byte will be reported as unexpected.
            self.pos = start;
            self.line = line;
            self.column = col;
            return null;
        }

        const stroke: ir.LineKind = if (has_eq) .thick else if (has_dot) .dotted else .solid;
        return self.make2(.edge, self.source[start..self.pos], line, col, .{
            .line = stroke,
            .arrow = arrow,
            .length = dashes,
        });
    }

    fn make2(self: *const Lexer, kind: TokenKind, lexeme: []const u8, line: u32, col: u32, edge: EdgeOp) Token {
        _ = self;
        return .{ .kind = kind, .lexeme = lexeme, .line = line, .column = col, .edge = edge };
    }

    /// Read raw label text from the current cursor until (not including) the
    /// matching close delimiter, which is then consumed. Surrounding whitespace
    /// is trimmed and a single layer of quotes is stripped. Used by the parser
    /// for shape bodies and pipe labels. Returns error if the close is missing.
    pub fn readLabel(self: *Lexer, close: u8) ![]const u8 {
        const start = self.pos;
        while (self.peekByte()) |c| {
            if (c == close) break;
            if (c == '\n') return error.UnterminatedLabel;
            self.advanceByte();
        }
        if (self.peekByte() == null) return error.UnterminatedLabel;
        const raw = self.source[start..self.pos];
        self.advanceByte(); // consume close
        return trimLabel(raw);
    }

    /// Read a `((...))` double-paren body. The cursor sits just past `((`.
    pub fn readDoubleParenLabel(self: *Lexer) ![]const u8 {
        const start = self.pos;
        while (self.peekByte()) |c| {
            if (c == ')' and self.peekByteAt(1) == ')') break;
            if (c == '\n') return error.UnterminatedLabel;
            self.advanceByte();
        }
        if (self.peekByte() == null) return error.UnterminatedLabel;
        const raw = self.source[start..self.pos];
        self.advanceByte(); // first )
        self.advanceByte(); // second )
        return trimLabel(raw);
    }
};

fn trimLabel(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn isEdgeStart(c: u8) bool {
    return c == '-' or c == '=';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "lexer tokenizes a simple edge chain" {
    var lex = Lexer.init("A --> B");
    const a = try lex.next();
    try std.testing.expectEqual(TokenKind.identifier, a.kind);
    try std.testing.expectEqualStrings("A", a.lexeme);

    const e = try lex.next();
    try std.testing.expectEqual(TokenKind.edge, e.kind);
    try std.testing.expectEqual(ir.LineKind.solid, e.edge.line);
    try std.testing.expectEqual(ir.ArrowKind.arrow, e.edge.arrow);

    const b = try lex.next();
    try std.testing.expectEqual(TokenKind.identifier, b.kind);
    try std.testing.expectEqualStrings("B", b.lexeme);

    try std.testing.expectEqual(TokenKind.eof, (try lex.next()).kind);
}

test "lexer classifies stroke styles" {
    {
        var lex = Lexer.init("-.->");
        const e = try lex.next();
        try std.testing.expectEqual(ir.LineKind.dotted, e.edge.line);
        try std.testing.expectEqual(ir.ArrowKind.arrow, e.edge.arrow);
    }
    {
        var lex = Lexer.init("==>");
        const e = try lex.next();
        try std.testing.expectEqual(ir.LineKind.thick, e.edge.line);
    }
    {
        var lex = Lexer.init("---");
        const e = try lex.next();
        try std.testing.expectEqual(ir.ArrowKind.none, e.edge.arrow);
        try std.testing.expectEqual(ir.LineKind.solid, e.edge.line);
    }
}

test "lexer matches the A---oB circle-edge trap" {
    var lex = Lexer.init("A---oB");
    try std.testing.expectEqualStrings("A", (try lex.next()).lexeme);
    const e = try lex.next();
    try std.testing.expectEqual(TokenKind.edge, e.kind);
    try std.testing.expectEqual(ir.ArrowKind.circle, e.edge.arrow);
    const b = try lex.next();
    try std.testing.expectEqualStrings("B", b.lexeme); // not "oB"
}

test "lexer strips comments and counts lines" {
    var lex = Lexer.init("A %% trailing comment\nB");
    try std.testing.expectEqualStrings("A", (try lex.next()).lexeme);
    try std.testing.expectEqual(TokenKind.newline, (try lex.next()).kind);
    const b = try lex.next();
    try std.testing.expectEqualStrings("B", b.lexeme);
    try std.testing.expectEqual(@as(u32, 2), b.line);
}

test "lexer reads a bracket label body raw" {
    var lex = Lexer.init("[Hello World]");
    try std.testing.expectEqual(TokenKind.lbracket, (try lex.next()).kind);
    const label = try lex.readLabel(']');
    try std.testing.expectEqualStrings("Hello World", label);
}
