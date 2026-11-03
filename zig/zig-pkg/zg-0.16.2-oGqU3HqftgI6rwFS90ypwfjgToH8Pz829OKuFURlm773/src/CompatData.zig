//! Compatibility Data

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const []const u21 = undefined,
};

const compat_data = compat_data: {
    const data = @import("compat");
    break :compat_data Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

/// Returns compatibility decomposition for `cp`.
pub fn toNfkd(cp: u21) []const u21 {
    return compat_data.s2[compat_data.s1[cp >> 8] + (cp & 0xff)];
}
