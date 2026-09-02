//! A guest: bare-metal EL1 code running inside a moss VM. It has no
//! kernel, no MMU (stage 2 alone confines it), and knows three things
//! about its world: a UART byte register at 0x09000000 (every store to
//! it is a stage-2 fault the VMM turns into a log line), the GICv3
//! system-register CPU interface (virtual, thanks to the hypervisor),
//! and the virtual timer (PPI 27, injected through the vGIC). It says
//! hello, counts three ticks, and asks PSCI to power off — an SMC the
//! hypervisor traps.

const uart: *volatile u8 = @ptrFromInt(0x0900_0000);
const vtimer_ppi: u64 = 27;
const psci_system_off: u64 = 0x8400_0008;

var ticks: u32 = 0;
var period: u64 = 0;

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        \\        ldr     x0, =__stack_top
        \\        mov     sp, x0
        \\        ldr     x0, =__vectors
        \\        msr     vbar_el1, x0
        \\        isb
        \\        bl      gmain
        \\1:      wfi
        \\        b       1b
        \\
        \\// Exception vectors: only "current EL, SPx, IRQ" is expected.
        \\        .balign 2048
        \\.global __vectors
        \\__vectors:
        \\        .rept 5
        \\        .balign 128
        \\        b       ghang
        \\        .endr
        \\        .balign 128
        \\        b       girq_entry
        \\        .rept 10
        \\        .balign 128
        \\        b       ghang
        \\        .endr
        \\
        \\girq_entry:
        \\        sub     sp, sp, #176
        \\        stp     x0, x1, [sp, #0]
        \\        stp     x2, x3, [sp, #16]
        \\        stp     x4, x5, [sp, #32]
        \\        stp     x6, x7, [sp, #48]
        \\        stp     x8, x9, [sp, #64]
        \\        stp     x10, x11, [sp, #80]
        \\        stp     x12, x13, [sp, #96]
        \\        stp     x14, x15, [sp, #112]
        \\        stp     x16, x17, [sp, #128]
        \\        stp     x18, x29, [sp, #144]
        \\        str     x30, [sp, #160]
        \\        bl      girq
        \\        ldp     x0, x1, [sp, #0]
        \\        ldp     x2, x3, [sp, #16]
        \\        ldp     x4, x5, [sp, #32]
        \\        ldp     x6, x7, [sp, #48]
        \\        ldp     x8, x9, [sp, #64]
        \\        ldp     x10, x11, [sp, #80]
        \\        ldp     x12, x13, [sp, #96]
        \\        ldp     x14, x15, [sp, #112]
        \\        ldp     x16, x17, [sp, #128]
        \\        ldp     x18, x29, [sp, #144]
        \\        ldr     x30, [sp, #160]
        \\        add     sp, sp, #176
        \\        eret
        \\
        \\ghang:  wfi
        \\        b       ghang
    );
}

fn puts(s: []const u8) void {
    for (s) |c| uart.* = c;
    uart.* = '\n';
}

fn putsNum(prefix: []const u8, n: u32) void {
    for (prefix) |c| uart.* = c;
    var digits: [10]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
        v /= 10;
        if (v == 0) break;
    }
    while (d > 0) {
        d -= 1;
        uart.* = digits[d];
    }
    uart.* = '\n';
}

fn cntvct() u64 {
    return asm volatile ("mrs %[v], cntvct_el0"
        : [v] "=r" (-> u64),
    );
}

fn armTimer() void {
    asm volatile (
        \\msr cntv_cval_el0, %[cval]
        \\msr cntv_ctl_el0, %[on]
        \\isb
        :
        : [cval] "r" (cntvct() + period),
          [on] "r" (@as(u64, 1)),
    );
}

export fn gmain() callconv(.c) void {
    // The (virtual) GIC CPU interface: system-register access, all
    // priorities, group 1 on.
    asm volatile (
        \\msr icc_sre_el1, %[one]
        \\isb
        \\msr icc_pmr_el1, %[pmr]
        \\msr icc_igrpen1_el1, %[one]
        \\isb
        :
        : [one] "r" (@as(u64, 1)),
          [pmr] "r" (@as(u64, 0xff)),
    );
    const freq = asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    period = freq / 5; // 200ms
    armTimer();
    asm volatile ("msr daifclr, #2");

    puts("guest: hello from EL1, inside a moss VM");
    while (ticks < 3) asm volatile ("wfi");
    puts("guest: three ticks; powering off");
    asm volatile (".inst 0xd4000003" // smc #0
        :
        : [fid] "{x0}" (psci_system_off),
        : .{ .memory = true });
    while (true) asm volatile ("wfi");
}

export fn girq() callconv(.c) void {
    const iar = asm volatile ("mrs %[v], icc_iar1_el1"
        : [v] "=r" (-> u64),
    );
    if (iar == vtimer_ppi) {
        ticks += 1;
        putsNum("guest: tick ", ticks);
        armTimer();
    }
    asm volatile ("msr icc_eoir1_el1, %[v]"
        :
        : [v] "r" (iar),
    );
}
