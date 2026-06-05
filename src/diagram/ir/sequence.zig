//! Semantic model for sequence diagrams. Unlike the graph IR, this is a
//! lane/time model: ordered participants own vertical lifelines, and an ordered
//! stream of events (messages, notes, activations, and — later — block frames)
//! flows top-to-bottom. Layout and rendering consume this and never see Mermaid
//! syntax.

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
    /// `+` after the arrow: start an activation on the target at this message.
    activate_target: bool = false,
    /// `-` after the arrow: end the source's activation at this message.
    deactivate_source: bool = false,

    pub fn isSelf(self: Message) bool {
        return self.from == self.to;
    }
};

pub const NotePlacement = enum {
    left_of,
    right_of,
    over,
};

pub const Note = struct {
    placement: NotePlacement,
    /// Participant span. For `left of`/`right of`, `from == to`. For `over A,B`,
    /// the note spans the lane range `[from, to]` (already ordered low..high).
    from: ParticipantId,
    to: ParticipantId,
    text: []const u8,
};

pub const BlockKind = enum {
    alt, // alternative paths (with `else` sections)
    opt, // optional
    loop, // repeated
    par, // parallel (with `and` sections)
};

pub const Block = struct {
    kind: BlockKind,
    /// Condition/description text, e.g. `is valid` or `retry x3`.
    label: []const u8,
};

/// One ordered item in the diagram timeline. Blocks (`alt`/`opt`/`loop`/`par`)
/// bracket a run of events with `block_start` … (`block_else`) … `block_end`.
pub const Event = union(enum) {
    message: Message,
    note: Note,
    activate: ParticipantId,
    deactivate: ParticipantId,
    block_start: Block,
    block_else: []const u8, // `else`/`and` section label
    block_end: void,
};

pub const SequenceDiagram = struct {
    participants: []Participant,
    events: []Event,
};
