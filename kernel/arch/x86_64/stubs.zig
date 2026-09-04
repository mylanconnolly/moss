//! What the port does not have yet, named honestly: the IOMMU answers
//! "nothing here" so the generic kernel carries on untranslated.

pub const iommu = struct {
    pub var active = false;
    pub var fault_count: u64 = 0;
    pub var last_fault_type: u32 = 0;
    pub var last_fault_sid: u32 = 0;
    pub var last_fault_addr: u64 = 0;
    pub var first_fault_addr: u64 = 0;
    pub fn attach(idx: u64, root: u64, asid: u16, who: *anyopaque) void {
        _ = .{ idx, root, asid, who };
    }
    pub fn attachStage2(idx: u64, s2_root: u64, vmid: u16, who: *anyopaque) void {
        _ = .{ idx, s2_root, vmid, who };
    }
    pub fn detachStage2(idx: u64, vmid: u16, who: *anyopaque) void {
        _ = .{ idx, vmid, who };
    }
    pub fn detachIfHolder(idx: u64, who: *anyopaque, asid: u16) void {
        _ = .{ idx, who, asid };
    }
    pub fn invalidateAsid(asid: u16) void {
        _ = asid;
    }
    pub fn handleIrq(intid: u32) bool {
        _ = intid;
        return false;
    }
};
