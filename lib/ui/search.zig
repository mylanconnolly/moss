//! Case-insensitive word filtering; match names before descriptions.
const std = @import("std");
fn contains(text: []const u8, term: []const u8) bool {
    if (term.len > text.len) return false;
    for (0..text.len - term.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..term.len], term)) return true;
    return false;
}
pub fn score(name: []const u8, description: []const u8, query: []const u8) ?usize {
    var terms = std.mem.tokenizeAny(u8, query, " \t\n");
    var result: usize = 0;
    while (terms.next()) |term| {
        if (std.ascii.startsWithIgnoreCase(name, term)) continue;
        if (contains(name, term)) result += 1 else if (contains(description, term)) result += 2 else return null;
    }
    return result;
}
test "search requires every word and ranks names before descriptions" {
    try std.testing.expectEqual(@as(?usize, 0), score("Editor", "Write text documents", "EDI"));
    try std.testing.expectEqual(@as(?usize, 4), score("Editor", "Write text documents", "text documents"));
    try std.testing.expectEqual(@as(?usize, null), score("Editor", "Write text documents", "text music"));
    try std.testing.expectEqual(@as(?usize, 0), score("Files", "Browse folders", "  "));
}
