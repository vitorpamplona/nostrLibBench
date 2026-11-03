//! General Categories

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u5 = undefined,
    s3: []const u5 = undefined,
};

const general_categories = general_categories: {
    const data = @import("gencat");
    break :general_categories Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
        .s3 = &data.s3,
    };
};

/// General Category
pub const Gc = enum {
    Cc, // Other, Control
    Cf, // Other, Format
    Cn, // Other, Unassigned
    Co, // Other, Private Use
    Cs, // Other, Surrogate
    Ll, // Letter, Lowercase
    Lm, // Letter, Modifier
    Lo, // Letter, Other
    Lu, // Letter, Uppercase
    Lt, // Letter, Titlecase
    Mc, // Mark, Spacing Combining
    Me, // Mark, Enclosing
    Mn, // Mark, Non-Spacing
    Nd, // Number, Decimal Digit
    Nl, // Number, Letter
    No, // Number, Other
    Pc, // Punctuation, Connector
    Pd, // Punctuation, Dash
    Pe, // Punctuation, Close
    Pf, // Punctuation, Final quote (may behave like Ps or Pe depending on usage)
    Pi, // Punctuation, Initial quote (may behave like Ps or Pe depending on usage)
    Po, // Punctuation, Other
    Ps, // Punctuation, Open
    Sc, // Symbol, Currency
    Sk, // Symbol, Modifier
    Sm, // Symbol, Math
    So, // Symbol, Other
    Zl, // Separator, Line
    Zp, // Separator, Paragraph
    Zs, // Separator, Space
};

/// Lookup the General Category for `cp`.
pub fn gc(cp: u21) Gc {
    return @enumFromInt(general_categories.s3[general_categories.s2[general_categories.s1[cp >> 8] + (cp & 0xff)]]);
}

/// True if `cp` has an C general category.
pub fn isControl(cp: u21) bool {
    return switch (gc(cp)) {
        .Cc,
        .Cf,
        .Cn,
        .Co,
        .Cs,
        => true,
        else => false,
    };
}

/// True if `cp` has an L general category.
pub fn isLetter(cp: u21) bool {
    return switch (gc(cp)) {
        .Ll,
        .Lm,
        .Lo,
        .Lu,
        .Lt,
        => true,
        else => false,
    };
}

/// True if `cp` has an M general category.
pub fn isMark(cp: u21) bool {
    return switch (gc(cp)) {
        .Mc,
        .Me,
        .Mn,
        => true,
        else => false,
    };
}

/// True if `cp` has an N general category.
pub fn isNumber(cp: u21) bool {
    return switch (gc(cp)) {
        .Nd,
        .Nl,
        .No,
        => true,
        else => false,
    };
}

/// True if `cp` has an P general category.
pub fn isPunctuation(cp: u21) bool {
    return switch (gc(cp)) {
        .Pc,
        .Pd,
        .Pe,
        .Pf,
        .Pi,
        .Po,
        .Ps,
        => true,
        else => false,
    };
}

/// True if `cp` has an S general category.
pub fn isSymbol(cp: u21) bool {
    return switch (gc(cp)) {
        .Sc,
        .Sk,
        .Sm,
        .So,
        => true,
        else => false,
    };
}

/// True if `cp` has an Z general category.
pub fn isSeparator(cp: u21) bool {
    return switch (gc(cp)) {
        .Zl,
        .Zp,
        .Zs,
        => true,
        else => false,
    };
}
