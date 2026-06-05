//! Structured diagnostics for the Mermaid frontend. The goal is precise,
//! agent-actionable feedback: if a planner emits bad Mermaid, the message and
//! 1-based line/column should say exactly what to fix.

pub const MermaidErrorKind = enum {
    /// The diagram header (`flowchart`/`graph`) was missing or unrecognized.
    missing_header,
    /// A direction keyword was expected but something else appeared.
    invalid_direction,
    /// `end` used as a bare node id. Mermaid silently breaks flowcharts here, so
    /// we reject with a clear diagnostic instead of emitting a broken graph.
    reserved_keyword_end,
    /// A node identifier was expected at this position.
    expected_node,
    /// A shape was opened (`[`, `(`, `{`) but never closed before end of input.
    unterminated_shape,
    /// A pipe edge label (`-->|...|`) was opened but never closed.
    unterminated_label,
    /// A token appeared that the supported subset does not allow here.
    unexpected_token,
    /// Syntax that is valid Mermaid but outside the implemented subset.
    unsupported_syntax,
    /// (Sequence) A participant identifier was expected at this position.
    expected_participant,
    /// (Sequence) The message arrow operator was malformed.
    invalid_arrow,
};

pub const MermaidError = struct {
    kind: MermaidErrorKind,
    /// 1-based line of the offending token.
    line: u32,
    /// 1-based column of the offending token.
    column: u32,
    /// Human-readable description. Points at a static string so it carries no
    /// allocation lifetime; locate the site with `line`/`column`.
    message: []const u8,
};

/// The single error returned to callers; the detailed `MermaidError` is written
/// through the out-parameter the parser was given.
pub const ParseError = error{
    MermaidSyntax,
    OutOfMemory,
    InvalidUtf8,
};
