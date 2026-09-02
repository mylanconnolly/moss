//! The kernel entropy pool: a ChaCha8 fast-key-erasure CSPRNG
//! (std.Random.ChaCha) that the kernel never seeds itself. Hardware
//! entropy arrives only through rng_seed from a domain holding the
//! entropy cap — the userspace virtio-rng driver — so the pool is
//! fail-closed: getrandom refuses with bad_state until the first seed
//! lands. No cycle-counter "entropy", no boot-time guesswork: an unseeded
//! pool is an honest error, not a weak random number.
//!
//! The generator is pure integer code (the kernel is FP-free; std's
//! ChaCha vectors lower to scalar ops without NEON) and lives under its
//! own spinlock — a getrandom never touches a scheduler or IPC lock.

const std = @import("std");
const lock = @import("lock.zig");
const shared = @import("shared");

const Drbg = std.Random.ChaCha;

var pool_lock: lock.SpinLock = .{};
var drbg: Drbg = undefined;
var seeded = false;
var seed_count: u64 = 0;
var bytes_served: u64 = 0;

/// Mix `entropy` into the pool. The first seed keys the generator (it
/// must be at least Drbg.secret_seed_length bytes; the caller checks
/// shared.rng_min_seed); later seeds refresh the key with fast key
/// erasure semantics. The caller zeroizes its copy.
pub fn seed(entropy: []const u8) void {
    std.debug.assert(entropy.len >= Drbg.secret_seed_length);
    const daif = pool_lock.lockIrqSave();
    defer pool_lock.unlockRestore(daif);
    if (!seeded) {
        drbg = Drbg.init(entropy[0..Drbg.secret_seed_length].*);
        if (entropy.len > Drbg.secret_seed_length) {
            drbg.addEntropy(entropy[Drbg.secret_seed_length..]);
        }
        seeded = true;
    } else {
        drbg.addEntropy(entropy);
    }
    seed_count += 1;
}

pub const Error = error{Unseeded};

/// Fill `out` with random bytes, or Unseeded before the first seed.
pub fn fill(out: []u8) Error!void {
    const daif = pool_lock.lockIrqSave();
    defer pool_lock.unlockRestore(daif);
    if (!seeded) return Error.Unseeded;
    drbg.fill(out);
    bytes_served += out.len;
}

pub fn isSeeded() bool {
    const daif = pool_lock.lockIrqSave();
    defer pool_lock.unlockRestore(daif);
    return seeded;
}

/// How many seeds have landed (boot seed + reseeds) — introspection for
/// the rng drill.
pub fn seedCount() u64 {
    const daif = pool_lock.lockIrqSave();
    defer pool_lock.unlockRestore(daif);
    return seed_count;
}

comptime {
    std.debug.assert(shared.rng_min_seed >= Drbg.secret_seed_length);
}
