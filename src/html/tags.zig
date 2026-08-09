// I am satisfied with how this ended up.
// Tho i wonder, could there be an even faster way to do this?
const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const tables = @import("tables.zig");

/// Packs the first up-to-8 tag bytes into a key.
///
/// Byte `i` (little-endian) stores `name[i]`.
/// Only for canonical (already lowercase) bytes: comptime literals and
/// selector source lowered by the selector parser. Prefer `first8KeyWithMode`
/// for document source bytes.
inline fn first8Key(name: []const u8) u64 {
    var hash: u64 = 0;
    const n: usize = @min(name.len, 8);
    @memcpy(std.mem.asBytes(&hash)[0..n], name[0..n]);
    return hash;
}

/// Returns a canonical lowercase key of the first up-to-8 tag bytes.
///
/// Destructive parse canonicalizes the source in place, so the byte-exact
/// pack is used. Non-destructive parse keeps original-case source bytes and
/// must lowercase while packing so keys match comptime literals and parser
/// keys.
pub inline fn first8KeyWithMode(name: []const u8, comptime non_destructive: bool) u64 {
    if (!comptime non_destructive) return first8Key(name);
    var key: u64 = 0;
    const n: usize = @min(name.len, 8);
    for (name[0..n], 0..) |c, i| {
        key |= @as(u64, std.ascii.toLower(c)) << @as(u6, @intCast(i * 8));
    }
    return key;
}

/// Case-insensitive equality check accelerated by `(len,key)` prechecks.
///
/// The packed keys are byte-exact; callers are expected to canonicalize the
/// first eight bytes with `first8KeyWithMode` (parser keys are already
/// lowercase).
pub inline fn equalByLenAndKeyIgnoreCase(a: []const u8, a_key: u64, b: []const u8, b_key: u64) bool {
    if (a.len != b.len or a_key != b_key) return false;
    if (a.len <= 8) return true;
    return std.ascii.eqlIgnoreCase(a[@min(8, a.len)..], b[@min(8, b.len)..]);
}

const KEY = struct {
    inline fn litKey(comptime s: []const u8) u64 {
        return comptime first8Key(s);
    }

    const AREA = litKey("area");
    const BASE = litKey("base");
    const BR = litKey("br");
    const COL = litKey("col");
    const EMBED = litKey("embed");
    const HR = litKey("hr");
    const IMG = litKey("img");
    const INPUT = litKey("input");
    const LINK = litKey("link");
    const META = litKey("meta");
    const PARAM = litKey("param");
    const SOURCE = litKey("source");
    const TRACK = litKey("track");
    const WBR = litKey("wbr");

    const SCRIPT = litKey("script");
    const STYLE = litKey("style");
    const TITLE = litKey("title");
    const TEXTAREA = litKey("textarea");
    const PLAINTEXT = litKey("plaintex");

    const LI = litKey("li");
    const P = litKey("p");
    const DT = litKey("dt");
    const DD = litKey("dd");
    const OPTION = litKey("option");
    const OPTGROUP = litKey("optgroup");
    const TR = litKey("tr");
    const TD = litKey("td");
    const TH = litKey("th");
    const HEAD = litKey("head");
    const BODY = litKey("body");
    const HTML = litKey("html");
    const APPLET = litKey("applet");
    const BUTTON = litKey("button");
    const CAPTION = litKey("caption");
    const MARQUEE = litKey("marquee");
    const OBJECT = litKey("object");
    const TEMPLATE = litKey("template");
    const SELECT = litKey("select");
    const DATALIST = litKey("datalist");

    const ADDRESS = litKey("address");
    const ARTICLE = litKey("article");
    const ASIDE = litKey("aside");
    const BLOCKQUOTE = litKey("blockquote");
    const DETAILS = litKey("details");
    const DIALOG = litKey("dialog");
    const DIV = litKey("div");
    const DL = litKey("dl");
    const FIELDSET = litKey("fieldset");
    const FIGCAPTION = litKey("figcaption");
    const FIGURE = litKey("figure");
    const FOOTER = litKey("footer");
    const FORM = litKey("form");
    const H1 = litKey("h1");
    const H2 = litKey("h2");
    const H3 = litKey("h3");
    const H4 = litKey("h4");
    const H5 = litKey("h5");
    const H6 = litKey("h6");
    const HEADER = litKey("header");
    const HGROUP = litKey("hgroup");
    const MAIN = litKey("main");
    const MENU = litKey("menu");
    const NAV = litKey("nav");
    const OL = litKey("ol");
    const PRE = litKey("pre");
    const SEARCH = litKey("search");
    const SECTION = litKey("section");
    const TABLE = litKey("table");
    const UL = litKey("ul");

    const SVG = litKey("svg");
    const MATH = litKey("math");
};

pub const OpenTagKind = enum(u8) { normal, void, text_only, plaintext, svg };

/// Classifies parser-relevant start-tag behavior in one `(len,key)` dispatch.
pub inline fn classifyOpenTag(name: []const u8, key: u64) OpenTagKind {
    const first: u8 = @truncate(key);
    return switch (name.len) {
        2 => switch (first) {
            'b' => if (key == KEY.BR) .void else .normal,
            'h' => if (key == KEY.HR) .void else .normal,
            else => .normal,
        },
        3 => switch (first) {
            'c' => if (key == KEY.COL) .void else .normal,
            'i' => if (key == KEY.IMG) .void else .normal,
            's' => if (key == KEY.SVG) .svg else .normal,
            'w' => if (key == KEY.WBR) .void else .normal,
            else => .normal,
        },
        4 => switch (first) {
            'a' => if (key == KEY.AREA) .void else .normal,
            'b' => if (key == KEY.BASE) .void else .normal,
            'l' => if (key == KEY.LINK) .void else .normal,
            'm' => if (key == KEY.META) .void else .normal,
            else => .normal,
        },
        5 => switch (first) {
            'e' => if (key == KEY.EMBED) .void else .normal,
            'i' => if (key == KEY.INPUT) .void else .normal,
            'p' => if (key == KEY.PARAM) .void else .normal,
            's' => if (key == KEY.STYLE) .text_only else .normal,
            't' => if (key == KEY.TITLE) .text_only else if (key == KEY.TRACK) .void else .normal,
            else => .normal,
        },
        6 => if (first == 's') switch (key) {
            KEY.SCRIPT => .text_only,
            KEY.SOURCE => .void,
            else => .normal,
        } else .normal,
        8 => if (first == 't' and key == KEY.TEXTAREA) .text_only else .normal,
        9 => if (first == 'p' and key == KEY.PLAINTEXT and std.ascii.toLower(name[8]) == 't') .plaintext else .normal,
        else => .normal,
    };
}

/// Fast void-tag check with caller-provided key.
pub fn isVoidTagWithKey(name: []const u8, key: u64) bool {
    return switch (name.len) {
        2 => switch (key) {
            KEY.BR, KEY.HR => true,
            else => false,
        },
        3 => switch (key) {
            KEY.COL, KEY.IMG, KEY.WBR => true,
            else => false,
        },
        4 => switch (key) {
            KEY.AREA, KEY.BASE, KEY.LINK, KEY.META => true,
            else => false,
        },
        5 => switch (key) {
            KEY.EMBED, KEY.INPUT, KEY.PARAM, KEY.TRACK => true,
            else => false,
        },
        6 => switch (key) {
            KEY.SOURCE => true,
            else => false,
        },
        else => false,
    };
}

/// Returns whether tag content is raw text: tags and entities are both literal.
pub fn isRawTextTagWithKey(name: []const u8, key: u64) bool {
    return switch (name.len) {
        5 => key == KEY.STYLE,
        6 => key == KEY.SCRIPT,
        else => false,
    };
}

/// Returns whether tag content is escapable raw text: tags are literal but
/// character references are decoded.
pub fn isEscapableRawTextTagWithKey(name: []const u8, key: u64) bool {
    return switch (name.len) {
        5 => key == KEY.TITLE,
        8 => key == KEY.TEXTAREA,
        else => false,
    };
}

/// Returns whether tag content is consumed opaquely up to its matching close.
pub inline fn isTextOnlyTagWithKey(name: []const u8, key: u64) bool {
    return isRawTextTagWithKey(name, key) or isEscapableRawTextTagWithKey(name, key);
}

/// Fast check for `<plaintext>` by `(len,key)`.
pub fn isPlainTextTagWithKey(name: []const u8, key: u64) bool {
    return name.len == 9 and key == KEY.PLAINTEXT and std.ascii.toLower(name[8]) == 't';
}

const implicit_p: u8 = 1 << 0;
const implicit_li: u8 = 1 << 1;
const implicit_dt_dd: u8 = 1 << 2;
const implicit_tr: u8 = 1 << 3;
const implicit_td_th: u8 = 1 << 4;
const implicit_head: u8 = 1 << 5;
const implicit_option: u8 = 1 << 6;
const implicit_optgroup: u8 = 1 << 7;

/// Returns the single active-source bit for an optional-end-tag source, or 0.
pub inline fn implicitCloseSourceMask(tag_len: usize, key: u64) u8 {
    return switch (tag_len) {
        1 => if (key == KEY.P) implicit_p else 0,
        2 => switch (key) {
            KEY.LI => implicit_li,
            KEY.DT, KEY.DD => implicit_dt_dd,
            KEY.TR => implicit_tr,
            KEY.TD, KEY.TH => implicit_td_th,
            else => 0,
        },
        4 => if (key == KEY.HEAD) implicit_head else 0,
        6 => if (key == KEY.OPTION) implicit_option else 0,
        8 => if (key == KEY.OPTGROUP) implicit_optgroup else 0,
        else => 0,
    };
}

/// Returns the optional-end-tag source classes that `new_tag` can close.
/// A parser can intersect this with its currently-open source mask and avoid
/// any stack walk when no compatible source is open.
pub inline fn implicitCloseTriggerMask(new_tag: []const u8, new_key: u64) u8 {
    var mask: u8 = if (closesPWithKey(new_tag, new_key)) implicit_p else 0;
    switch (new_tag.len) {
        2 => switch (new_key) {
            KEY.LI => mask |= implicit_li,
            KEY.DT, KEY.DD => mask |= implicit_dt_dd,
            KEY.TR => mask |= implicit_tr,
            KEY.TD, KEY.TH => mask |= implicit_td_th,
            KEY.HR => mask |= implicit_option | implicit_optgroup,
            else => {},
        },
        4 => {
            if (new_key == KEY.BODY) mask |= implicit_head;
        },
        6 => {
            if (new_key == KEY.OPTION) mask |= implicit_option;
        },
        8 => {
            if (new_key == KEY.OPTGROUP) mask |= implicit_option | implicit_optgroup;
        },
        else => {},
    }
    return mask;
}

/// Returns true when `open_tag_len`/`open_key` represent an optional-close source tag.
pub inline fn isImplicitCloseSourceWithLenAndKey(open_tag_len: usize, open_key: u64) bool {
    return implicitCloseSourceMask(open_tag_len, open_key) != 0;
}

/// Optional-close predicate with precomputed `(len,key)` fast path.
pub fn shouldImplicitlyCloseWithKeys(open_tag: []const u8, open_key: u64, new_tag: []const u8, new_key: u64) bool {
    return shouldImplicitlyCloseWithLenAndKey(open_tag.len, open_key, new_tag, new_key);
}

/// Optional-close predicate with caller-provided open-tag length.
pub fn shouldImplicitlyCloseWithLenAndKey(open_tag_len: usize, open_key: u64, new_tag: []const u8, new_key: u64) bool {
    return switch (open_tag_len) {
        1 => open_key == KEY.P and closesPWithKey(new_tag, new_key),
        2 => switch (open_key) {
            KEY.LI => new_key == KEY.LI,
            KEY.DT, KEY.DD => new_key == KEY.DT or new_key == KEY.DD,
            KEY.TR => new_key == KEY.TR,
            KEY.TD, KEY.TH => new_key == KEY.TD or new_key == KEY.TH,
            else => false,
        },
        4 => switch (open_key) {
            KEY.HEAD => new_key == KEY.BODY,
            else => false,
        },
        6 => switch (open_key) {
            KEY.OPTION => new_key == KEY.OPTION or new_key == KEY.OPTGROUP or new_key == KEY.HR,
            else => false,
        },
        8 => switch (open_key) {
            KEY.OPTGROUP => new_key == KEY.OPTGROUP or new_key == KEY.HR,
            else => false,
        },
        else => false,
    };
}

/// Scope state accumulated while scanning open elements from the current node
/// toward the root for an optional-end-tag source. Different HTML algorithms
/// use different scope boundaries; keeping them separate prevents, for example,
/// a `<button>` from hiding an outer `<li>` while still hiding an outer `<p>`.
pub const ImplicitCloseScope = struct {
    regular: bool = false,
    button: bool = false,
    list_item: bool = false,
    table: bool = false,
    select: bool = false,

    /// Returns whether an optional-close source at the current scan position is
    /// still visible through the boundaries already encountered above it.
    pub fn permits(self: @This(), source_tag_len: usize, source_key: u64) bool {
        return switch (source_tag_len) {
            1 => source_key == KEY.P and !self.regular and !self.button,
            2 => switch (source_key) {
                KEY.LI => !self.regular and !self.list_item,
                KEY.DT, KEY.DD => !self.regular,
                KEY.TR, KEY.TD, KEY.TH => !self.table,
                else => true,
            },
            4 => if (source_key == KEY.HEAD) !self.regular else true,
            6 => if (source_key == KEY.OPTION) !self.select else true,
            8 => if (source_key == KEY.OPTGROUP) !self.select else true,
            else => true,
        };
    }

    /// Adds one open element above a potential source to the accumulated scope
    /// barriers. Call this after testing that element as a source itself.
    pub fn observe(self: *@This(), tag_len: usize, key: u64) void {
        if (isRegularScopeBoundary(tag_len, key)) self.regular = true;
        if (tag_len == 6 and key == KEY.BUTTON) self.button = true;
        if (tag_len == 2 and (key == KEY.OL or key == KEY.UL)) self.list_item = true;
        if ((tag_len == 4 and key == KEY.HTML) or
            (tag_len == 5 and key == KEY.TABLE) or
            (tag_len == 8 and key == KEY.TEMPLATE)) self.table = true;
        if ((tag_len == 6 and key == KEY.SELECT) or
            (tag_len == 8 and key == KEY.DATALIST)) self.select = true;
    }
};

fn isRegularScopeBoundary(tag_len: usize, key: u64) bool {
    return switch (tag_len) {
        2 => key == KEY.TD or key == KEY.TH,
        4 => key == KEY.HTML,
        5 => key == KEY.TABLE,
        6 => key == KEY.APPLET or key == KEY.OBJECT,
        7 => key == KEY.CAPTION or key == KEY.MARQUEE,
        8 => key == KEY.TEMPLATE,
        else => false,
    };
}

fn closesPWithKey(new_tag: []const u8, new_key: u64) bool {
    return switch (new_tag.len) {
        1 => new_key == KEY.P,
        2 => switch (new_key) {
            KEY.LI,
            KEY.DT,
            KEY.DD,
            KEY.HR,
            KEY.H1,
            KEY.H2,
            KEY.H3,
            KEY.H4,
            KEY.H5,
            KEY.H6,
            KEY.DL,
            KEY.OL,
            KEY.UL,
            => true,
            else => false,
        },
        3 => switch (new_key) {
            KEY.DIV,
            KEY.NAV,
            KEY.PRE,
            => true,
            else => false,
        },
        4 => switch (new_key) {
            KEY.FORM,
            KEY.MAIN,
            KEY.MENU,
            => true,
            else => false,
        },
        5 => switch (new_key) {
            KEY.ASIDE,
            KEY.TABLE,
            => true,
            else => false,
        },
        6 => switch (new_key) {
            KEY.DIALOG,
            KEY.FIGURE,
            KEY.FOOTER,
            KEY.HEADER,
            KEY.HGROUP,
            KEY.SEARCH,
            => true,
            else => false,
        },
        7 => switch (new_key) {
            KEY.ADDRESS,
            KEY.ARTICLE,
            KEY.DETAILS,
            KEY.SECTION,
            => true,
            else => false,
        },
        8 => switch (new_key) {
            KEY.FIELDSET => true,
            else => false,
        },
        9 => new_key == KEY.PLAINTEXT and std.ascii.toLower(new_tag[8]) == 't',
        10 => switch (new_key) {
            KEY.BLOCKQUOTE => std.ascii.toLower(new_tag[8]) == 't' and std.ascii.toLower(new_tag[9]) == 'e',
            KEY.FIGCAPTION => std.ascii.toLower(new_tag[8]) == 'o' and std.ascii.toLower(new_tag[9]) == 'n',
            else => false,
        },
        else => false,
    };
}

/// Fast check for `svg` tag by `(len,key)`.
pub inline fn isSvgWithKey(name: []const u8, key: u64) bool {
    return name.len == 3 and key == KEY.SVG;
}

/// Fast check for the MathML `math` integration root by `(len,key)`.
pub inline fn isMathWithKey(name: []const u8, key: u64) bool {
    return name.len == 4 and key == KEY.MATH;
}

test "tag helpers on canonical lowercase names" {
    try std.testing.expect(isVoidTagWithKey("img", first8Key("img")));
    try std.testing.expect(isRawTextTagWithKey("script", first8Key("script")));
    try std.testing.expect(isRawTextTagWithKey("style", first8Key("style")));
    try std.testing.expect(!isRawTextTagWithKey("title", first8Key("title")));
    try std.testing.expect(isEscapableRawTextTagWithKey("title", first8Key("title")));
    try std.testing.expect(isEscapableRawTextTagWithKey("textarea", first8Key("textarea")));
    try std.testing.expect(isTextOnlyTagWithKey("textarea", first8Key("textarea")));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "blockquote", KEY.BLOCKQUOTE));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "address", KEY.ADDRESS));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "article", KEY.ARTICLE));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "section", KEY.SECTION));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "fieldset", KEY.FIELDSET));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "details", KEY.DETAILS));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "dialog", KEY.DIALOG));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "figcaption", KEY.FIGCAPTION));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "figure", KEY.FIGURE));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "hgroup", KEY.HGROUP));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "menu", KEY.MENU));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "search", KEY.SEARCH));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("option", KEY.OPTION, "optgroup", KEY.OPTGROUP));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("option", KEY.OPTION, "hr", KEY.HR));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("optgroup", KEY.OPTGROUP, "optgroup", KEY.OPTGROUP));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("optgroup", KEY.OPTGROUP, "hr", KEY.HR));
    try std.testing.expect(shouldImplicitlyCloseWithKeys("p", KEY.P, "plaintext", KEY.PLAINTEXT));
}

test "first8KeyWithMode canonicalizes only in non-destructive mode" {
    try std.testing.expectEqual(first8Key("img"), first8KeyWithMode("img", false));
    try std.testing.expectEqual(first8Key("img"), first8KeyWithMode("IMG", true));
    try std.testing.expectEqual(first8Key("img"), first8KeyWithMode("ImG", true));
    try std.testing.expectEqual(first8Key("textarea"), first8KeyWithMode("TEXTAREA", true));
    try std.testing.expect(first8KeyWithMode("IMG", true) != first8Key("IMG"));
}

test "equalByLenAndKeyIgnoreCase handles long names with canonical keys" {
    const a = "blockquote";
    const b = "blockquote";
    try std.testing.expect(equalByLenAndKeyIgnoreCase(a, first8Key(a), b, first8Key(b)));
}
