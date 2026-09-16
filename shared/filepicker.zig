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
    /// Chooser only (the badge the broker minted for it in `hello`): wait
    /// for a dialog job. The reply is `job` once an application asks to
    /// open or save; the broker parks this call meanwhile.
    chooser_ready: void,
    /// Chooser only: the user chose a path (path_len bytes at name_offset
    /// in the chooser's buffer) or cancelled (path_len 0). The reply is
    /// the next job, as for chooser_ready.
    chooser_done: struct { path_len: u64 },
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
    /// A dialog job for the chooser: saving or opening, with the initial
    /// name (name_len bytes at name_offset in the chooser's buffer).
    job: struct { saving: u64, name_len: u64 },
};

/// The broker's one call on the chooser, right after init started it: the
/// cap is the broker endpoint minted for the chooser alone. Everything
/// after that the chooser initiates, so the broker never blocks on it.
pub const ChooserReq = union(enum(u64)) {
    hello: void,
};
pub const ChooserResp = union(enum(u64)) {
    ok: void,
    refused: void,
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
