//! The Limine boot protocol (base revision 5), as Zig: the requests the
//! kernel places in its image and the responses the loader fills in.
//! Every pointer a response carries is a higher-half direct-map address
//! at the loader's offset (the HHDM response), not ours.

// The markers and the base revision tag are spelled out where they are
// placed (boot.zig): a named constant holding them would be materialized
// in .rodata too, and the loader takes the *first* end marker it finds —
// a stray copy before the real start marker leaves no window at all.

fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

pub const MemmapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,
    _,
};

pub const MemmapEntry = extern struct { base: u64, length: u64, type: MemmapType };
pub const MemmapResponse = extern struct { revision: u64, entry_count: u64, entries: [*]*MemmapEntry };
pub const MemmapRequest = extern struct {
    id: [4]u64 = id(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemmapResponse = null,
};

pub const HhdmResponse = extern struct { revision: u64, offset: u64 };
pub const HhdmRequest = extern struct {
    id: [4]u64 = id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const ExecutableAddressResponse = extern struct { revision: u64, physical_base: u64, virtual_base: u64 };
pub const ExecutableAddressRequest = extern struct {
    id: [4]u64 = id(0x71ba76863cc55f63, 0xb2644a48c516a487),
    revision: u64 = 0,
    response: ?*ExecutableAddressResponse = null,
};

pub const CmdlineResponse = extern struct { revision: u64, cmdline: [*:0]u8 };
pub const CmdlineRequest = extern struct {
    id: [4]u64 = id(0x4b161536e598651e, 0xb390ad4a2f1f303a),
    revision: u64 = 0,
    response: ?*CmdlineResponse = null,
};

pub const RsdpResponse = extern struct { revision: u64, address: u64 };
pub const RsdpRequest = extern struct {
    id: [4]u64 = id(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,
    response: ?*RsdpResponse = null,
};

pub const TscFrequencyResponse = extern struct { revision: u64, frequency: u64 };
pub const TscFrequencyRequest = extern struct {
    id: [4]u64 = id(0x10f2ee1d87d195e4, 0xf747a2b78f6ddb31),
    revision: u64 = 0,
    response: ?*TscFrequencyResponse = null,
};

pub const mp_x2apic: u64 = 1 << 0;
pub const MpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: u64,
    extra_argument: u64,
};
pub const MpResponse = extern struct { revision: u64, flags: u32, bsp_lapic_id: u32, cpu_count: u64, cpus: [*]*MpInfo };
pub const MpRequest = extern struct {
    id: [4]u64 = id(0x95a67b819a1b857e, 0xa0b61b723b6a73e0),
    revision: u64 = 0,
    response: ?*MpResponse = null,
    flags: u64 = mp_x2apic,
};

pub const BootloaderInfoResponse = extern struct { revision: u64, name: [*:0]u8, version: [*:0]u8 };
pub const BootloaderInfoRequest = extern struct {
    id: [4]u64 = id(0xf55038d8e2a1202f, 0x279426fcf5f59740),
    revision: u64 = 0,
    response: ?*BootloaderInfoResponse = null,
};
