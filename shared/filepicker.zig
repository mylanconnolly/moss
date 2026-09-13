//! Selected-document authority. Editors receive document endpoints; directory
//! capabilities from the chooser or Files handoff remain inside the broker.
//! Buffer bytes [0..max_bytes] hold document data; name is at name_offset.
pub const max_bytes = 256 * 1024;
pub const name_offset = max_bytes;
pub const pages = 65;
pub const Req = union(enum(u64)) {
    register: void,
    attach_buf: void,
    open: void,
    /// Read the already selected document without another chooser.
    load: void,
    /// Sender buffer name_offset holds one basename; cap is a fresh parent view.
    offer: struct { path_len: u64 },
    /// Commit only after the recipient has been launched successfully.
    enqueue: struct { ticket: u64 },
    cancel_offer: struct { ticket: u64 },
    /// Exported receiver capability only; transfers a selected-document channel.
    take: void,
    save: struct { len: u64 },
    save_as: struct { len: u64 },
};
pub const Resp = union(enum(u64)) {
    registered: void,
    offered: struct { ticket: u64 },
    selected: void,
    empty: void,
    ok: void,
    cancelled: void,
    document: struct { len: u64, name_len: u64, read_only: u64 },
    failed: struct { code: u64 },
};
pub const Error = enum(u64) {
    unavailable = 1,
    bad_path,
    not_found,
    read_only,
    no_space,
    not_text,
    too_large,
    not_file,
    busy,
    commit_uncertain,
};
