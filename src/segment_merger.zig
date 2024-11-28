const std = @import("std");

const common = @import("common.zig");
const Item = common.Item;
const SegmentId = common.SegmentId;

const SharedPtr = @import("utils/smartptr.zig").SharedPtr;
const SegmentList = @import("segment_list2.zig").SegmentList;

pub const MergedSegmentInfo = struct {
    id: SegmentId,
    max_commit_id: u64,
    docs: std.AutoHashMap(u32, bool),
};

pub fn SegmentMerger(comptime Segment: type) type {
    return struct {
        const Self = @This();

        const Source = struct {
            reader: Segment.Reader,
            skip_docs: std.AutoHashMap(u32, void),

            pub fn read(self: *Source) !?Item {
                while (true) {
                    const item = try self.reader.read() orelse return null;
                    if (self.skip_docs.contains(item.id)) {
                        self.reader.advance();
                        continue;
                    }
                    return item;
                }
            }

            pub fn advance(self: *Source) void {
                self.reader.advance();
            }
        };

        allocator: std.mem.Allocator,
        sources: std.ArrayList(Source),
        collection: *SegmentList(Segment),
        segment: MergedSegmentInfo,
        estimated_size: usize = 0,

        current_item: ?Item = null,

        pub fn init(allocator: std.mem.Allocator, collection: *SegmentList(Segment)) Self {
            return .{
                .allocator = allocator,
                .sources = std.ArrayList(Source).init(allocator),
                .collection = collection,
                .segment = .{
                    .id = .{ .version = 0, .included_merges = 0 },
                    .docs = std.AutoHashMap(u32, bool).init(allocator),
                    .max_commit_id = 0,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.sources.items) |*source| {
                source.reader.close();
                source.skip_docs.deinit();
            }
            self.sources.deinit();
            self.segment.docs.deinit();
            self.* = undefined;
        }

        pub fn addSource(self: *Self, source: *Segment) !void {
            try self.sources.append(.{
                .reader = source.reader(),
                .skip_docs = std.AutoHashMap(u32, void).init(self.allocator),
            });
        }

        pub fn prepare(self: *Self) !void {
            const sources = self.sources.items;
            if (sources.len == 0) {
                return error.NoSources;
            }

            var total_docs: u32 = 0;
            for (sources, 0..) |source, i| {
                if (i == 0) {
                    self.segment.id = source.reader.segment.id;
                    self.segment.max_commit_id = source.reader.segment.max_commit_id;
                } else {
                    self.segment.id = SegmentId.merge(self.segment.id, source.reader.segment.id);
                    self.segment.max_commit_id = @max(self.segment.max_commit_id, source.reader.segment.max_commit_id);
                }
                total_docs += source.reader.segment.docs.count();
            }

            try self.segment.docs.ensureTotalCapacity(total_docs);
            for (sources) |*source| {
                const segment = source.reader.segment;
                var docs_added: usize = 0;
                var docs_found: usize = 0;
                var iter = segment.docs.iterator();
                while (iter.next()) |entry| {
                    docs_found += 1;
                    const doc_id = entry.key_ptr.*;
                    const doc_status = entry.value_ptr.*;
                    if (!self.collection.hasNewerVersion(doc_id, segment.id.version)) {
                        try self.segment.docs.put(doc_id, doc_status);
                        docs_added += 1;
                    } else {
                        try source.skip_docs.put(doc_id, {});
                    }
                }
                if (docs_found > 0) {
                    const ratio = (100 * docs_added) / docs_found;
                    self.estimated_size += segment.getSize() * @min(100, ratio + 10) / 100;
                }
            }
        }

        pub fn read(self: *Self) !?Item {
            if (self.current_item == null) {
                var min_item: ?Item = null;
                var min_item_index: usize = 0;

                for (self.sources.items, 0..) |*source, i| {
                    if (try source.read()) |item| {
                        if (min_item == null or Item.cmp({}, item, min_item.?)) {
                            min_item = item;
                            min_item_index = i;
                        }
                    }
                }

                if (min_item) |item| {
                    self.sources.items[min_item_index].advance();
                    self.current_item = item;
                }
            }
            return self.current_item;
        }

        pub fn advance(self: *Self) void {
            self.current_item = null;
        }
    };
}

test "merge segments" {
    const MemorySegment = @import("MemorySegment.zig");

    var collection = try SegmentList(MemorySegment).init(std.testing.allocator, 3);
    defer collection.deinit(std.testing.allocator);

    var merger = SegmentMerger(MemorySegment).init(std.testing.allocator, &collection);
    defer merger.deinit();

    var node1 = try SegmentList(MemorySegment).createSegment(std.testing.allocator, .{});
    collection.nodes.appendAssumeCapacity(node1);

    var node2 = try SegmentList(MemorySegment).createSegment(std.testing.allocator, .{});
    collection.nodes.appendAssumeCapacity(node2);

    var node3 = try SegmentList(MemorySegment).createSegment(std.testing.allocator, .{});
    collection.nodes.appendAssumeCapacity(node3);

    node1.value.id = SegmentId{ .version = 1, .included_merges = 0 };
    node1.value.max_commit_id = 11;

    node2.value.id = SegmentId{ .version = 2, .included_merges = 0 };
    node2.value.max_commit_id = 12;

    node3.value.id = SegmentId{ .version = 3, .included_merges = 0 };
    node3.value.max_commit_id = 13;

    try merger.addSource(node1.value);
    try merger.addSource(node2.value);
    try merger.addSource(node3.value);

    try merger.prepare();

    try std.testing.expectEqual(1, merger.segment.id.version);
    try std.testing.expectEqual(2, merger.segment.id.included_merges);
    try std.testing.expectEqual(13, merger.segment.max_commit_id);

    while (true) {
        const item = try merger.read();
        if (item == null) {
            break;
        }
    }
}
