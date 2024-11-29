const std = @import("std");
const Allocator = std.mem.Allocator;

const SearchResults = @import("common.zig").SearchResults;

const Change = @import("change.zig").Change;
const SegmentId = @import("common.zig").SegmentId;

const Deadline = @import("utils/Deadline.zig");

const SharedPtr = @import("utils/smartptr.zig").SharedPtr;
const TieredMergePolicy = @import("segment_merge_policy.zig").TieredMergePolicy;
const SegmentMerger = @import("segment_merger.zig").SegmentMerger;

pub fn SegmentList(Segment: type) type {
    return struct {
        pub const Self = @This();

        pub const Node = SharedPtr(Segment);
        pub const List = std.ArrayListUnmanaged(Node);

        nodes: List,

        pub fn initEmpty() Self {
            const nodes = List.initBuffer(&.{});
            return .{
                .nodes = nodes,
            };
        }

        pub fn init(allocator: Allocator, num: usize) Allocator.Error!Self {
            const nodes = try List.initCapacity(allocator, num);
            errdefer nodes.deinit(allocator);

            return .{
                .nodes = nodes,
            };
        }

        pub fn createSharedEmpty(allocator: Allocator) Allocator.Error!SharedPtr(Self) {
            return try SharedPtr(Self).create(allocator, Self.initEmpty());
        }

        pub fn createShared(allocator: Allocator, capacity: anytype) Allocator.Error!SharedPtr(Self) {
            var self = try Self.init(allocator, capacity);
            errdefer self.deinit(allocator);

            return try SharedPtr(Self).create(allocator, self);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.nodes.items) |*node| {
                destroySegment(allocator, node);
            }
            self.nodes.deinit(allocator);
        }

        pub fn createSegment(allocator: Allocator, options: Segment.Options) Allocator.Error!Node {
            return Node.create(allocator, @call(.auto, Segment.init, .{ allocator, options }));
        }

        pub fn destroySegment(allocator: Allocator, node: *Node) void {
            node.release(allocator, .{});
        }

        pub fn appendSegmentInto(self: Self, copy: *Self, node: Node) void {
            copy.nodes.clearRetainingCapacity();
            for (self.nodes.items) |n| {
                copy.nodes.appendAssumeCapacity(n.acquire());
            }
            copy.nodes.appendAssumeCapacity(node.acquire());
        }

        pub fn removeSegmentInto(self: Self, copy: *Self, node: Node) void {
            copy.nodes.clearRetainingCapacity();
            for (self.nodes.items) |n| {
                if (n.value != node.value) {
                    copy.nodes.appendAssumeCapacity(n.acquire());
                }
            }
        }

        pub fn replaceMergedSegmentInto(self: *Self, copy: *Self, node: Node) Self {
            copy.nodes.clearRetainingCapacity();
            var inserted_merged = false;
            for (self.nodes.items) |n| {
                if (node.value.id.contains(n.value.id)) {
                    if (!inserted_merged) {
                        copy.nodes.appendAssumeCapacity(node);
                        inserted_merged = true;
                    }
                } else {
                    copy.nodes.appendAssumeCapacity(n.acquire());
                }
            }
            return copy;
        }

        pub fn getIds(self: Self, allocator: Allocator) Allocator.Error!std.ArrayListUnmanaged(SegmentId) {
            var ids = try std.ArrayListUnmanaged(SegmentId).initCapacity(allocator, self.nodes.items.len);
            for (self.nodes.items) |node| {
                ids.appendAssumeCapacity(node.value.id);
            }
            return ids;
        }

        pub fn search(self: Self, hashes: []const u32, results: *SearchResults, deadline: Deadline) !void {
            for (self.nodes.items) |node| {
                if (deadline.isExpired()) {
                    return error.Timeout;
                }
                try node.value.search(hashes, results);
            }
        }

        pub fn getMaxCommitId(self: Self) u64 {
            var max_commit_id: u64 = 0;
            for (self.nodes.items) |node| {
                max_commit_id = @max(max_commit_id, node.value.max_commit_id);
            }
            return max_commit_id;
        }

        fn compareByVersion(_: void, lhs: u32, rhs: Node) bool {
            return lhs < rhs.value.id.version;
        }

        pub fn hasNewerVersion(self: *const Self, doc_id: u32, version: u32) bool {
            var i = self.nodes.items.len;
            while (i > 0) {
                i -= 1;
                const node = self.nodes.items[i];
                if (node.value.id.version > version) {
                    if (node.value.docs.contains(doc_id)) {
                        return true;
                    }
                } else {
                    break;
                }
            }
            return false;
        }

        pub fn count(self: Self) usize {
            return self.nodes.items.len;
        }

        pub fn getFirst(self: Self) ?Node {
            return if (self.nodes.items.len > 0) self.nodes.items[0] else null;
        }

        pub fn getLast(self: Self) ?Node {
            return self.nodes.getLastOrNull();
        }
    };
}

fn getSegmentSize(comptime T: type) fn (SharedPtr(T)) usize {
    const tmp = struct {
        fn getSize(segment: SharedPtr(T)) usize {
            return segment.value.getSize();
        }
    };
    return tmp.getSize;
}

pub fn SegmentListManager(Segment: type) type {
    return struct {
        pub const Self = @This();
        pub const List = SegmentList(Segment);
        pub const MergePolicy = TieredMergePolicy(List.Node, getSegmentSize(Segment));

        allocator: Allocator,
        options: Segment.Options,
        segments: SharedPtr(List),
        merge_policy: MergePolicy,
        num_allowed_segments: std.atomic.Value(usize),
        update_lock: std.Thread.Mutex,

        pub fn init(allocator: Allocator, options: Segment.Options, merge_policy: MergePolicy) !Self {
            const segments = try SharedPtr(List).create(allocator, List.initEmpty());
            return Self{
                .allocator = allocator,
                .options = options,
                .segments = segments,
                .merge_policy = merge_policy,
                .num_allowed_segments = std.atomic.Value(usize).init(0),
                .update_lock = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            releaseSegments(&self.segments);
        }

        pub fn count(self: Self) usize {
            return self.segments.value.nodes.items.len;
        }

        fn acquireSegments(self: Self, lock: *std.Thread.RwLock) SharedPtr(List) {
            lock.lockShared();
            defer lock.unlockShared();

            return self.segments.acquire();
        }

        fn releaseSegments(self: *Self, segments: *SharedPtr(List)) void {
            segments.release(self.allocator, .{self.allocator});
        }

        pub fn needsMerge(self: Self) bool {
            return self.segments.value.nodes.items.len > self.num_allowed_segments.load(.acquire);
        }

        pub fn merge(self: *Self, lock: *std.Thread.RwLock, preCommitFn: anytype, ctx: anytype) !bool {
            var segments = self.acquireSegments(lock);
            defer self.releaseSegments(&segments);

            self.num_allowed_segments.store(self.merge_policy.calculateBudget(segments.value.nodes.items), .release);
            if (!self.needsMerge()) {
                return false;
            }

            const candidate = self.merge_policy.findSegmentsToMerge(segments.value.nodes.items) orelse return false;

            var new_segment = try List.createSegment(self.allocator, self.options);
            defer List.destroySegment(self.allocator, &new_segment);

            var merger = SegmentMerger(Segment).init(self.allocator, segments.value);
            defer merger.deinit();

            for (segments.value.nodes.items[candidate.start..candidate.end]) |segment| {
                try merger.addSource(segment.value);
            }
            try merger.prepare();

            try new_segment.value.merge(&merger);
            errdefer new_segment.value.cleanup();

            var update = try self.beginUpdate();
            defer self.cleanupAfterUpdate(&update);

            try @call(.auto, preCommitFn, .{ ctx, update.segments.value });

            lock.lock();
            defer lock.unlock();

            self.commitUpdate(&update);

            return true;
        }

        pub const Update = struct {
            manager: *Self,
            segments: SharedPtr(List),
            committed: bool = false,

            pub fn removeSegment(self: *@This(), node: List.Node) void {
                self.manager.segments.value.removeSegmentInto(self.segments.value, node);
            }

            pub fn appendSegment(self: *@This(), node: List.Node) void {
                self.manager.segments.value.appendSegmentInto(self.segments.value, node);
            }

            pub fn replaceMergedSegment(self: *@This(), node: List.Node) void {
                self.manager.segments.value.replaceMergedSegmentInto(self.segments.value, node);
            }
        };

        pub fn beginUpdate(self: *Self) !Update {
            self.update_lock.lock();
            errdefer self.update_lock.unlock();

            var segments = try SharedPtr(List).create(self.allocator, List.initEmpty());
            errdefer self.releaseSegments(&segments);

            // allocate memory for one extra segment, if it's going to be unused, it's going to be unused, but we need to have it ready
            try segments.value.nodes.ensureTotalCapacity(self.allocator, self.count() + 1);

            return .{
                .manager = self,
                .segments = segments,
            };
        }

        pub fn commitUpdate(self: *Self, update: *Update) void {
            self.segments.swap(&update.segments);
            self.update_lock.unlock();
            update.committed = true;
        }

        pub fn cleanupAfterUpdate(self: *Self, update: *Update) void {
            if (!update.committed) {
                self.update_lock.unlock();
            }
            self.destroySegments(&update.segments);
        }

        pub fn destroySegments(self: *Self, segments: *SharedPtr(List)) void {
            // we also call cleanup on these segments, to ensure that unused segments will get deleted from disk
            segments.releaseWithCleanup(self.allocator, destroySegmentList, .{self.allocator});
        }

        fn destroySegmentList(segments: *List, allocator: Allocator) void {
            while (segments.nodes.items.len > 0) {
                var node = segments.nodes.pop();
                node.releaseWithCleanup(allocator, destroySegment, .{});
            }
            segments.deinit(allocator);
        }

        fn destroySegment(segment: *Segment) void {
            segment.cleanup();
            segment.deinit();
        }
    };
}
