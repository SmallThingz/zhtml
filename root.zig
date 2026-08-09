const impl = @import("src/root.zig");

test {
    _ = impl;
}

pub const ParseInt = impl.ParseInt;
pub const ParseOptions = impl.ParseOptions;
pub const TextOptions = impl.TextOptions;
pub const EntityEncoding = impl.EntityEncoding;
pub const EntityDecoding = impl.EntityDecoding;
pub const StreamingParser = impl.StreamingParser;
pub const StreamingEvent = impl.StreamingEvent;
pub const StreamingEventKind = impl.StreamingEventKind;
pub const StreamingAttribute = impl.StreamingAttribute;
pub const StreamingAttributeIterator = impl.StreamingAttributeIterator;
pub const Selector = impl.Selector;
pub const PreparedSelector = impl.PreparedSelector;
pub const QueryDebugReport = impl.QueryDebugReport;
pub const DebugFailureKind = impl.DebugFailureKind;
pub const NearMiss = impl.NearMiss;
pub const ParseInstrumentationStats = impl.ParseInstrumentationStats;
pub const QueryInstrumentationStats = impl.QueryInstrumentationStats;
pub const QueryInstrumentationKind = impl.QueryInstrumentationKind;
pub const queryWithHooks = impl.queryWithHooks;
pub const queryRuntimeWithHooks = impl.queryRuntimeWithHooks;
