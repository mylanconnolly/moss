//! Terminal-style character cell widths (wcwidth): 0 for combining marks
//! and other zero-width codepoints, 2 for East Asian wide/fullwidth and
//! emoji, 1 otherwise. Deliberately a pragmatic subset of the Unicode
//! tables — the goal is that CJK, emoji, and accented text keep the
//! cursor, selection, and glyphs aligned, not full UAX conformance.

const std = @import("std");

const Range = [2]u21;

const zero_ranges = [_]Range{
    .{ 0x00AD, 0x00AD }, // soft hyphen
    .{ 0x0300, 0x036F }, // combining diacritical marks
    .{ 0x0483, 0x0489 },
    .{ 0x0591, 0x05C7 },
    .{ 0x0610, 0x061A },
    .{ 0x064B, 0x065F },
    .{ 0x0670, 0x0670 },
    .{ 0x06D6, 0x06DC },
    .{ 0x06DF, 0x06E4 },
    .{ 0x06E7, 0x06E8 },
    .{ 0x06EA, 0x06ED },
    .{ 0x0711, 0x0711 },
    .{ 0x0730, 0x074A },
    .{ 0x07A6, 0x07B0 },
    .{ 0x0816, 0x0823 },
    .{ 0x0E31, 0x0E31 },
    .{ 0x0E34, 0x0E3A },
    .{ 0x0E47, 0x0E4E },
    .{ 0x1AB0, 0x1AFF }, // combining extended
    .{ 0x1DC0, 0x1DFF }, // combining supplement
    .{ 0x200B, 0x200F }, // zero-width space/joiners, marks
    .{ 0x2060, 0x2064 },
    .{ 0x20D0, 0x20FF }, // combining for symbols
    .{ 0xFE00, 0xFE0F }, // variation selectors
    .{ 0xFE20, 0xFE2F }, // combining half marks
    .{ 0xE0100, 0xE01EF }, // variation selectors supplement
};

const wide_ranges = [_]Range{
    .{ 0x1100, 0x115F }, // Hangul jamo
    .{ 0x2329, 0x232A },
    .{ 0x2E80, 0x303E }, // CJK radicals, punctuation
    .{ 0x3041, 0x33FF }, // kana, CJK symbols
    .{ 0x3400, 0x4DBF }, // CJK ext A
    .{ 0x4E00, 0x9FFF }, // CJK unified
    .{ 0xA000, 0xA4CF }, // Yi
    .{ 0xA960, 0xA97F },
    .{ 0xAC00, 0xD7A3 }, // Hangul syllables
    .{ 0xF900, 0xFAFF }, // CJK compat
    .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE52 },
    .{ 0xFE54, 0xFE66 },
    .{ 0xFE68, 0xFE6B },
    .{ 0xFF00, 0xFF60 }, // fullwidth forms
    .{ 0xFFE0, 0xFFE6 },
    .{ 0x1B000, 0x1B001 },
    .{ 0x1F200, 0x1F251 },
    .{ 0x1F300, 0x1F64F }, // emoji
    .{ 0x1F680, 0x1F6FF }, // transport emoji
    .{ 0x1F900, 0x1FAFF }, // supplemental emoji
    .{ 0x20000, 0x2FFFD }, // CJK ext B+
    .{ 0x30000, 0x3FFFD },
};

fn inRanges(ranges: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else if (cp < ranges[mid][0]) {
            hi = mid;
        } else {
            return true;
        }
    }
    return false;
}

pub fn isZeroWidth(cp: u21) bool {
    return inRanges(&zero_ranges, cp);
}

/// Cells one codepoint occupies (0, 1, or 2).
pub fn cellWidth(cp: u21) usize {
    if (cp < 0x0300) return 1; // fast path: ASCII / Latin-1
    if (inRanges(&zero_ranges, cp)) return 0;
    if (inRanges(&wide_ranges, cp)) return 2;
    return 1;
}

test "widths" {
    try std.testing.expectEqual(@as(usize, 1), cellWidth('a'));
    try std.testing.expectEqual(@as(usize, 2), cellWidth(0x4F60)); // 你
    try std.testing.expectEqual(@as(usize, 2), cellWidth(0x1F600)); // 😀
    try std.testing.expectEqual(@as(usize, 0), cellWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(usize, 0), cellWidth(0xFE0F)); // VS16
    try std.testing.expectEqual(@as(usize, 1), cellWidth(0x00E9)); // é precomposed
}
