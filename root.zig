const impl = @import("src/root.zig");
const declaration_testing = @import("src/testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

pub const ParseInt = impl.ParseInt;
pub const ParseOptions = impl.ParseOptions;
pub const TextOptions = impl.TextOptions;
pub const EntityEncoding = impl.EntityEncoding;
pub const EntityDecoding = impl.EntityDecoding;
pub const StreamingParser = impl.StreamingParser;
pub const Selector = impl.Selector;
pub const PreparedSelector = impl.PreparedSelector;
