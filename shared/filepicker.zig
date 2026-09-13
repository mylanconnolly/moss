//! Selected-document authority. Only the picker sees directory capabilities.
//! Buffer bytes [0..max_bytes] hold document data; name is at name_offset.
pub const max_bytes = 256 * 1024;
pub const name_offset = max_bytes;
pub const pages = 65;
pub const Req = union(enum(u64)) {
    register: void,
    attach_buf: void,
    open: void,
    save: struct { len: u64 },
    save_as: struct { len: u64 },
};
pub const Resp = union(enum(u64)) {
    registered: void,
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
