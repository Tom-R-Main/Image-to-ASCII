//! Semantic model for sequence diagrams. Unlike the graph IR, this is a
//! lane/time model: ordered participants own vertical lifelines, and ordered
//! messages flow top-to-bottom between them. Layout and rendering consume this
//! and never see Mermaid syntax.

/// Stroke of a message line. Mermaid: `->>`/`-)`/`-x` are solid, the `--`
/// variants (`-->>`, `--)`, `--x`) are dotted.
pub const LineStyle = enum {
    solid,
    dotted,
};

/// Decoration at the message's receiving end.
pub const HeadStyle = enum {
    none, // `->`  /  `-->`
    arrow, // `->>` /  `-->>`  (filled arrowhead)
    open, // `-)`  /  `--)`   (async / open arrowhead)
    cross, // `-x`  /  `--x`   (lost message)
};

pub const ParticipantKind = enum {
    participant,
    actor,
};

/// Index into `SequenceDiagram.participants`.
pub const ParticipantId = u32;

pub const Participant = struct {
    id: []const u8,
    label: []const u8,
    kind: ParticipantKind = .participant,
};

pub const Message = struct {
    from: ParticipantId,
    to: ParticipantId,
    text: []const u8,
    line: LineStyle,
    head: HeadStyle,

    pub fn isSelf(self: Message) bool {
        return self.from == self.to;
    }
};

pub const SequenceDiagram = struct {
    participants: []Participant,
    messages: []Message,
};
