//! moss static libraries — the locked code-sharing model: pure,
//! freestanding-safe, host-testable Zig modules, compiled into whatever
//! needs them. No dynamic loader exists or ever will; where key custody
//! matters, a capability service holds the secret instead.

pub const fabcert = @import("fabcert.zig");
pub const lz4 = @import("lz4.zig");
pub const mshl = @import("mshl.zig");
pub const settings = @import("settings.zig");
pub const usercred = @import("usercred.zig");
pub const xts = @import("xts.zig");

test {
    _ = fabcert;
    _ = lz4;
    _ = mshl;
    _ = settings;
    _ = usercred;
    _ = xts;
}
