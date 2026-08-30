const std = @import("std");
const html = @import("html");

fn contains(comptime names: []const []const u8, comptime needle: []const u8) bool {
    inline for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

fn assertPublicFunctions(comptime T: type, comptime expected: []const []const u8) void {
    @setEvalBranchQuota(1000_000);
    comptime {
        for (std.meta.declarations(T)) |decl| {
            const value = @field(T, decl.name);
            if (@typeInfo(@TypeOf(value)) == .@"fn" and !contains(expected, decl.name)) {
                @compileError("public API function lacks explicit coverage: " ++ @typeName(T) ++ "." ++ decl.name);
            }
        }
        for (expected) |name| {
            if (!@hasDecl(T, name)) @compileError("expected public API function disappeared: " ++ @typeName(T) ++ "." ++ name);
            if (@typeInfo(@TypeOf(@field(T, name))) != .@"fn") @compileError("expected public API function is not a function: " ++ @typeName(T) ++ "." ++ name);
        }
    }
}

fn sliceChild(comptime T: type) type {
    const info = @typeInfo(T).pointer;
    if (info.size != .slice) @compileError("expected slice type");
    return info.child;
}

fn formatDirect(value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try value.format(&out.writer);
}

fn exerciseWriterApis(node: anytype, doc: anytype) !void {
    inline for (.{ html.EntityEncoding.never, html.EntityEncoding.auto, html.EntityEncoding.force }) |encoding| {
        var node_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer node_out.deinit();
        try node.writeHtml(&node_out.writer, encoding);

        var self_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer self_out.deinit();
        try node.writeSelfHtml(&self_out.writer, encoding);

        var doc_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer doc_out.deinit();
        try doc.writeHtml(&doc_out.writer, encoding);
    }
}

fn exerciseOptionTypes(comptime opts: html.ParseOptions) void {
    _ = opts.Input();
    _ = opts.Node();
    _ = opts.QueryIter();
    _ = opts.ChildrenIter();
    _ = opts.Document();
}

fn exerciseDocument(comptime opts: html.ParseOptions, source_input: opts.Input()) !void {
    const alloc = std.testing.allocator;
    const Node = opts.Node();
    const QueryIter = opts.QueryIter();
    const ChildrenIter = opts.ChildrenIter();
    const Document = opts.Document();
    const RawNode = @typeInfo(@TypeOf(@as(Node, undefined).raw())).pointer.child;

    comptime {
        assertPublicFunctions(Node, &.{
            "WriterError",          "raw",                       "isDocument",        "isText",               "isElement",   "tagName",        "text",
            "innerTextWithOptions", "innerTextOwnedWithOptions", "getAttributeValue", "getAttributeValueRaw", "nextSibling", "prevSibling",    "parentNode",
            "children",             "writeHtml",                 "writeSelfHtml",     "format",               "matches",     "matchesRuntime", "matchesPrepared",
            "query",                "queryRuntime",              "queryPrepared",
        });
        assertPublicFunctions(Node.TextOptions, &.{"format"});
        assertPublicFunctions(Node.TextResult, &.{"free"});
        assertPublicFunctions(Node.AttributeValueResult, &.{"free"});
        assertPublicFunctions(RawNode, &.{ "isDocument", "isText", "isElement" });
        assertPublicFunctions(QueryIter, &.{ "deinit", "next", "format", "collect" });
        assertPublicFunctions(ChildrenIter, &.{ "next", "last", "collect", "format" });
        assertPublicFunctions(Document, &.{
            "init",         "deinit", "clear",     "root",   "query", "queryRuntime", "queryPrepared", "html", "head", "body",
            "findFirstTag", "nodeAt", "writeHtml", "format",
        });
    }

    var doc = try opts.parse(alloc, source_input);
    defer doc.deinit();

    const root = doc.root();
    try std.testing.expect(root.isDocument());
    try std.testing.expect(root.raw().isDocument(root.index));
    try std.testing.expect(!root.isText());
    try std.testing.expect(!root.isElement());
    try formatDirect(root);
    try formatDirect(doc);
    try formatDirect(Node.TextOptions{});

    const html_node = doc.html() orelse return error.TestUnexpectedResult;
    _ = doc.head() orelse return error.TestUnexpectedResult;
    _ = doc.body() orelse return error.TestUnexpectedResult;
    const div = doc.findFirstTag("DIV") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", div.tagName());
    try std.testing.expect(div.isElement());
    try std.testing.expect(div.raw().isElement(div.index));
    try std.testing.expect(div.parentNode() != null);
    _ = html_node;

    const text_node = doc.nodeAt(div.index + 1);
    try std.testing.expect(text_node.isText());
    try std.testing.expect(text_node.raw().isText(text_node.index));
    _ = text_node.text();

    var attr_value = (try div.getAttributeValue(alloc, "data-x")) orelse return error.TestUnexpectedResult;
    defer attr_value.free(alloc);
    _ = div.getAttributeValueRaw("data-x") orelse return error.TestUnexpectedResult;

    inline for (.{
        html.TextOptions{},
        html.TextOptions{ .normalize_whitespace = false },
        html.TextOptions{ .unescape = false },
        html.TextOptions{ .normalize_whitespace = false, .unescape = false },
    }) |text_opts| {
        var result = try div.innerTextWithOptions(alloc, text_opts);
        result.free(alloc);
        const owned = try div.innerTextOwnedWithOptions(alloc, text_opts);
        alloc.free(owned);
    }

    const section = doc.findFirstTag("section") orelse return error.TestUnexpectedResult;
    var first_children = section.children();
    const first_child = first_children.next() orelse return error.TestUnexpectedResult;
    _ = first_child.nextSibling();
    _ = first_child.prevSibling();

    var children = section.children();
    try formatDirect(children);
    _ = children.next();

    if (comptime opts.store_last_child) {
        var last_children = section.children();
        _ = last_children.last() orelse return error.TestUnexpectedResult;
    }

    var collect_children = section.children();
    const collected_children = try collect_children.collect(alloc);
    defer alloc.free(collected_children);

    const comptime_selector = html.Selector.compile("section > div.a");
    var runtime_selector = try html.Selector.compileRuntime(alloc, "section > div.a");
    defer runtime_selector.deinit(alloc);
    var prepared = try html.PreparedSelector.compile(alloc, "section > div.a");
    defer prepared.deinit();

    try std.testing.expect(try div.matches("div.a[data-x]"));
    try std.testing.expect(try div.matchesRuntime(runtime_selector));
    try std.testing.expect(try div.matchesPrepared(&prepared));

    var node_q = section.query("div.a");
    defer node_q.deinit();
    _ = try node_q.next();
    try formatDirect(node_q);

    var node_q_runtime = section.queryRuntime(runtime_selector);
    defer node_q_runtime.deinit();
    _ = try node_q_runtime.next();

    var node_q_prepared = section.queryPrepared(&prepared);
    defer node_q_prepared.deinit();
    _ = try node_q_prepared.next();

    var q = doc.query("div.a");
    defer q.deinit();
    _ = try q.next();
    try formatDirect(q);

    var q_collect = doc.query("span, p");
    const collected = try q_collect.collect(alloc);
    defer alloc.free(collected);

    var q_runtime = doc.queryRuntime(runtime_selector);
    defer q_runtime.deinit();
    _ = try q_runtime.next();

    var q_prepared = doc.queryPrepared(&prepared);
    defer q_prepared.deinit();
    _ = try q_prepared.next();

    _ = comptime_selector;
    _ = Node.WriterError(*std.Io.Writer);
    try exerciseWriterApis(div, &doc);

    var empty = Document.init(alloc);
    empty.clear();
    empty.deinit();
}

const StreamCtx = struct {
    events: usize = 0,
    attributes: usize = 0,

    fn onEvent(self: *@This(), event: html.StreamingParser.Event) !bool {
        self.events += 1;
        _ = event.nameSlice();
        _ = event.valueSlice();
        var attrs = event.attributes();
        while (attrs.next()) |attribute| {
            self.attributes += 1;
            _ = attribute.nameSlice();
            _ = attribute.valueRaw();
        }
        return true;
    }
};

test "public API declaration coverage guard" {
    const Node = (html.ParseOptions{}).Node();
    const SliceResult = Node.TextResult;
    const Event = html.StreamingParser.Event;
    const Attribute = html.StreamingParser.Attribute;
    const AttributeIterator = html.StreamingParser.AttributeIterator;
    const Span = @FieldType(Event, "name");

    const Selector = html.Selector;
    const Group = sliceChild(@FieldType(Selector, "groups"));
    const Compound = sliceChild(@FieldType(Selector, "compounds"));
    const Range = sliceChild(@FieldType(Selector, "classes"));
    const AttrSelector = sliceChild(@FieldType(Selector, "attrs"));
    const Pseudo = sliceChild(@FieldType(Selector, "pseudos"));
    const NotSimple = sliceChild(@FieldType(Selector, "not_items"));
    const Combinator = @FieldType(Compound, "combinator");
    const AttrOp = @FieldType(AttrSelector, "op");
    const AttrCase = @FieldType(AttrSelector, "case");
    const NthExpr = @FieldType(Pseudo, "nth");
    const PseudoKind = @FieldType(Pseudo, "kind");
    const NotKind = @FieldType(NotSimple, "kind");
    const PreparedPlan = @FieldType(html.PreparedSelector, "execution_plan");
    const PreparedCompactPlan = @FieldType(html.PreparedSelector, "compact_plan");
    const PredicatePlan = @FieldType(PreparedPlan, "predicates");
    const TagDispatch = @FieldType(PreparedPlan, "tag_dispatch");

    comptime {
        assertPublicFunctions(html.ParseOptions, &.{ "Input", "Node", "QueryIter", "ChildrenIter", "parse", "Document", "format" });
        assertPublicFunctions(html.ParseOptions.WhitespaceText, &.{});
        assertPublicFunctions(html.EntityEncoding, &.{});
        assertPublicFunctions(html.EntityDecoding, &.{});
        assertPublicFunctions(html.TextOptions, &.{"format"});
        assertPublicFunctions(SliceResult, &.{"free"});
        assertPublicFunctions(html.StreamingParser, &.{"parse"});
        assertPublicFunctions(html.StreamingParser.Options, &.{});
        assertPublicFunctions(html.StreamingParser.EventKind, &.{});
        assertPublicFunctions(Event, &.{ "nameSlice", "valueSlice", "attributes" });
        assertPublicFunctions(Attribute, &.{ "nameSlice", "valueRaw" });
        assertPublicFunctions(AttributeIterator, &.{"next"});
        assertPublicFunctions(Span, &.{ "end", "setEnd", "slice", "sliceMut", "format" });
        assertPublicFunctions(Selector, &.{ "compile", "compileRuntime", "deinit", "format" });
        assertPublicFunctions(Group, &.{"format"});
        assertPublicFunctions(Compound, &.{ "hasTag", "hasId", "format" });
        assertPublicFunctions(Range, &.{ "empty", "from", "isEmpty", "slice", "format" });
        assertPublicFunctions(AttrSelector, &.{"format"});
        assertPublicFunctions(Pseudo, &.{"format"});
        assertPublicFunctions(NotSimple, &.{"format"});
        assertPublicFunctions(Combinator, &.{"format"});
        assertPublicFunctions(AttrOp, &.{"format"});
        assertPublicFunctions(AttrCase, &.{"format"});
        assertPublicFunctions(NthExpr, &.{ "matches", "format" });
        assertPublicFunctions(PseudoKind, &.{"format"});
        assertPublicFunctions(NotKind, &.{"format"});
        assertPublicFunctions(html.PreparedSelector, &.{ "compile", "deinit" });
        assertPublicFunctions(PreparedCompactPlan, &.{});
        assertPublicFunctions(PreparedPlan, &.{ "init", "deinit", "mask", "maskMut", "predicateStateUsesFor", "densePredicateStateMask", "stateIndexForCompound" });
        assertPublicFunctions(PredicatePlan, &.{ "init", "deinit", "usesFor" });
        assertPublicFunctions(TagDispatch, &.{ "find", "stateUses", "simpleIndices" });
    }
}

test "public ParseOptions and DOM API methods instantiate and run" {
    comptime {
        exerciseOptionTypes(.{});
        exerciseOptionTypes(.{
            .drop_whitespace_text_nodes = .none,
            .non_destructive = true,
            .entity_decoding = .full,
            .store_last_child = true,
            .store_prev_sibling = true,
        });
    }

    try formatDirect(html.ParseOptions{});
    try formatDirect(html.TextOptions{});

    const destructive_source = try std.testing.allocator.dupe(u8, "<!doctype html><html><head><title>T</title></head><body><section><div id='x' class='a' data-x='v&amp;x'>hello<span>world</span></div><p>tail</p></section></body></html>");
    defer std.testing.allocator.free(destructive_source);
    try exerciseDocument(.{}, destructive_source);

    const FullOptions: html.ParseOptions = .{
        .drop_whitespace_text_nodes = .none,
        .non_destructive = true,
        .entity_decoding = .full,
        .store_last_child = true,
        .store_prev_sibling = true,
    };
    const read_only_source = "<!doctype html><html><head><title>T</title></head><body><section><div id='x' class='a' data-x='v&amp;x'>hello<span>world</span></div><p>tail</p></section></body></html>";
    try exerciseDocument(FullOptions, read_only_source);
}

test "public selector value API methods instantiate and run" {
    const alloc = std.testing.allocator;
    const selector = html.Selector.compile("div#id.cls[attr^=x]:first-child, span + a");
    try formatDirect(selector);

    const group = selector.groups[0];
    try formatDirect(group);
    const compound = selector.compounds[selector.compounds.len - 1];
    _ = compound.hasTag();
    _ = compound.hasId();
    try formatDirect(compound);
    try formatDirect(compound.combinator);

    const Range = @TypeOf(compound.tag);
    const empty = Range.empty();
    _ = empty.isEmpty();
    const range = Range.from(0, 7);
    _ = range.slice("section");
    try formatDirect(range);

    const attr = selector.attrs[0];
    try formatDirect(attr);
    try formatDirect(attr.op);
    try formatDirect(attr.case);
    const insensitive = html.Selector.compile("div[b=y i]");
    try formatDirect(insensitive.attrs[0].case);

    const pseudo = selector.pseudos[0];
    try formatDirect(pseudo);
    try formatDirect(pseudo.kind);
    const nth_selector = html.Selector.compile(":nth-child(2n+1)");
    _ = nth_selector.pseudos[0].nth.matches(3);
    try formatDirect(nth_selector.pseudos[0].nth);

    const not_selector = html.Selector.compile("div:not(.b)");
    const not_item = not_selector.not_items[0];
    try formatDirect(not_item);
    try formatDirect(not_item.kind);

    var runtime = try html.Selector.compileRuntime(alloc, "div.a[data-x]");
    try formatDirect(runtime);
    runtime.deinit(alloc);

    var prepared = try html.PreparedSelector.compile(alloc, "div.a[data-x]");

    const PreparedPlan = @TypeOf(prepared.execution_plan);
    var direct_plan = try PreparedPlan.init(alloc, prepared.selector);
    defer direct_plan.deinit(alloc);
    _ = direct_plan.mask(.start_none);
    _ = direct_plan.maskMut(.start_none);
    _ = direct_plan.stateIndexForCompound(0);
    if (direct_plan.predicates.count != 0) {
        _ = direct_plan.predicateStateUsesFor(0);
        _ = direct_plan.predicates.usesFor(0);
        if (direct_plan.dense_predicate_state_masks.len != 0) _ = direct_plan.densePredicateStateMask(0);
    }

    const TagEntry = sliceChild(@FieldType(@TypeOf(direct_plan.tag_dispatch), "entries"));
    const TagSig = @FieldType(TagEntry, "sig");
    const sig: TagSig = .{ .key = 0, .len = 0 };
    if (direct_plan.tag_dispatch.find(sig)) |entry| {
        _ = direct_plan.tag_dispatch.stateUses(entry);
        _ = direct_plan.tag_dispatch.simpleIndices(entry);
    }

    prepared.deinit();
}

test "public streaming API methods instantiate and run" {
    const alloc = std.testing.allocator;
    const source = "<!doctype html><!--c--><?pi?><div a='1' disabled>text</div>";
    var ctx: StreamCtx = .{};
    const parser: html.StreamingParser = .{ .options = .{
        .include_comments = true,
        .include_doctype = true,
        .include_processing_instructions = true,
    } };
    try parser.parse(alloc, source, &ctx, StreamCtx.onEvent);
    try std.testing.expect(ctx.events != 0);
    try std.testing.expect(ctx.attributes != 0);

    const Span = @FieldType(html.StreamingParser.Event, "name");
    var span: Span = .{ .start = 1, .len = 2 };
    _ = span.end();
    span.setEnd(4);
    _ = span.slice("abcde");
    var mutable = "abcde".*;
    _ = span.sliceMut(&mutable);
    try formatDirect(span);
}
