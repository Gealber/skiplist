const std = @import("std");
const Allocator = std.mem.Allocator;

const maxLevel: usize = 32;
const p: f32 = 0.5;

fn randomLvl(rng: std.Random) usize {
    var lvl: usize = 1;
    while (rng.float(f32) < p and lvl < maxLevel) {
        lvl += 1;
    }
    return lvl;
}

// SkipList implementation
//
//  L3: head ─────────────────────────────────────────────────► [50] ──► nil
//                                                               │
//  L2: head ───────────────► [10] ────────────────────────────► [50] ──► nil
//                             │                                 │
//  L1: head ───────────────► [10] ──────────► [30] ───────────► [50] ──► nil
//                             │               │                 │
//  L0: head ──► [5] ────────► [10] ──► [20] ──► [30] ──► [40] ──► [50] ──► [55] ──► nil

pub fn SkipList(
    comptime K: type,
    comptime V: type,
    comptime compareFn: fn (K, K) std.math.Order,
) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            next: []?*Node,
        };

        head: *Node,
        length: usize,
        level: usize,
        allocator: Allocator,
        prng: std.Random.DefaultPrng,
        rw: std.Io.RwLock = .init,
        io: std.Io,

        pub fn init(allocator: Allocator, io: std.Io, seed: u64) !Self {
            const head = try allocator.create(Node);
            head.next = try allocator.alloc(?*Node, maxLevel);
            @memset(head.next, null);
            head.key = undefined;
            head.value = undefined;

            return Self{
                .head = head,
                .level = 1,
                .length = 0,
                .allocator = allocator,
                .prng = std.Random.DefaultPrng.init(seed),
                .io = io,
            };
        }

        pub fn deinit(sl: *Self) void {
            var cur = sl.head.next[0];
            while (cur) |n| {
                const next = n.next[0];
                sl.allocator.free(n.next);
                sl.allocator.destroy(n);
                cur = next;
            }
            sl.allocator.free(sl.head.next);
            sl.allocator.destroy(sl.head);
        }

        // put upserts a key on the skip list.
        // Returns the displaced value on update, null on insert.
        pub fn put(sl: *Self, key: K, value: V) !?V {
            try sl.rw.lock(sl.io);
            defer sl.rw.unlock(sl.io);

            var update: [maxLevel]*Node = undefined;
            // try to find element, and keep track of levels boundaries
            // inside the update list
            var cur = sl.head;
            for (0..sl.level) |j| {
                const i = sl.level - j - 1;
                while (cur.next[i] != null and compareFn(cur.next[i].?.key, key) == .lt) {
                    cur = cur.next[i].?;
                }
                update[i] = cur;
            }

            // if the key is already present we just update its value
            const candidate = cur.next[0];
            if (candidate != null and compareFn(candidate.?.key, key) == .eq) {
                const old = candidate.?.value;
                candidate.?.value = value;
                return old;
            }

            const newLvl = randomLvl(sl.prng.random());
            if (newLvl > sl.level) {
                // initialize non existing levels
                for (sl.level..newLvl) |i| {
                    update[i] = sl.head;
                }
                // update skip-list level to new value
                sl.level = newLvl;
            }

            const new_node = try sl.allocator.create(Node);
            errdefer sl.allocator.destroy(new_node);

            new_node.key = key;
            new_node.value = value;
            new_node.next = try sl.allocator.alloc(?*Node, newLvl);
            // set the current node on each of the levels
            // from 0 to its maximum level(newLvl)
            for (0..newLvl) |i| {
                new_node.next[i] = update[i].next[i];
                update[i].next[i] = new_node;
            }
            sl.length += 1;
            return null;
        }

        // get performs search of a single key returning its value or KeyNotFound.
        pub fn get(sl: *Self, key: K) !V {
            try sl.rw.lockShared(sl.io);
            defer sl.rw.unlockShared(sl.io);

            var cur = sl.head;
            for (0..sl.level) |j| {
                const i = sl.level - j - 1;
                while (cur.next[i] != null and compareFn(cur.next[i].?.key, key) == .lt) {
                    cur = cur.next[i].?;
                }
            }

            const candidate = cur.next[0];
            if (candidate != null and compareFn(candidate.?.key, key) == .eq) {
                return candidate.?.value;
            }

            return error.KeyNotFound;
        }

        // delete removes a key from the skip list, freeing its node.
        // Does nothing if the key is not present.
        pub fn delete(sl: *Self, key: K) !void {
            try sl.rw.lock(sl.io);
            defer sl.rw.unlock(sl.io);

            var update: [maxLevel]*Node = undefined;
            // try to find element, and keep track of levels boundaries
            // inside the update list
            var cur = sl.head;
            for (0..sl.level) |j| {
                const i = sl.level - j - 1;
                while (cur.next[i] != null and compareFn(cur.next[i].?.key, key) == .lt) {
                    cur = cur.next[i].?;
                }
                update[i] = cur;
            }

            const candidate = cur.next[0] orelse return;
            if (compareFn(candidate.key, key) != .eq) return;

            // splice the node out of every level where it appears
            for (0..sl.level) |i| {
                if (update[i].next[i] != candidate) break;
                update[i].next[i] = candidate.next[i];
            }

            // shrink the list level if top levels are now empty
            while (sl.level > 1 and sl.head.next[sl.level - 1] == null) {
                sl.level -= 1;
            }

            sl.allocator.free(candidate.next);
            sl.allocator.destroy(candidate);
            sl.length -= 1;
        }

        pub const Iterator = struct {
            cur: ?*Node,
            rw: *std.Io.RwLock,
            io: std.Io,

            pub fn next(it: *Iterator) ?struct { key: K, value: V } {
                const n = it.cur orelse return null;
                it.cur = n.next[0];
                return .{ .key = n.key, .value = n.value };
            }

            // Must be called when done iterating, even if not fully exhausted.
            pub fn deinit(it: *Iterator) void {
                it.rw.unlockShared(it.io);
            }
        };

        // iterate returns an Iterator starting at the first key >= start.
        // The caller must call it.deinit() when done to release the read lock.
        pub fn iterate(sl: *Self, start: K) !Iterator {
            try sl.rw.lockShared(sl.io);

            var cur = sl.head;
            for (0..sl.level) |j| {
                const i = sl.level - j - 1;
                while (cur.next[i] != null and compareFn(cur.next[i].?.key, start) == .lt) {
                    cur = cur.next[i].?;
                }
            }

            return Iterator{ .cur = cur.next[0], .rw = &sl.rw, .io = sl.io };
        }
    };
}

fn compareStr(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

const StringSkipList = SkipList([]const u8, []const u8, compareStr);

test "put and get" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("hello", "world");
    try std.testing.expectEqualStrings("world", try sl.get("hello"));
}

test "update existing key" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("key", "first");
    const old = try sl.put("key", "second");
    try std.testing.expectEqualStrings("first", old.?);
    try std.testing.expectEqualStrings("second", try sl.get("key"));
}

test "key not found" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    try std.testing.expectError(error.KeyNotFound, sl.get("missing"));
}

test "multiple keys inserted out of order" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("c", "3");
    _ = try sl.put("a", "1");
    _ = try sl.put("b", "2");

    try std.testing.expectEqualStrings("1", try sl.get("a"));
    try std.testing.expectEqualStrings("2", try sl.get("b"));
    try std.testing.expectEqualStrings("3", try sl.get("c"));
    try std.testing.expectError(error.KeyNotFound, sl.get("d"));
}

test "delete existing key" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("a", "1");
    _ = try sl.put("b", "2");
    _ = try sl.put("c", "3");

    try sl.delete("b");

    try std.testing.expectEqualStrings("1", try sl.get("a"));
    try std.testing.expectError(error.KeyNotFound, sl.get("b"));
    try std.testing.expectEqualStrings("3", try sl.get("c"));
    try std.testing.expectEqual(2, sl.length);
}

test "delete missing key does nothing" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("a", "1");
    try sl.delete("z");
    try std.testing.expectEqualStrings("1", try sl.get("a"));
    try std.testing.expectEqual(1, sl.length);
}

test "iterate from start key" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("a", "1");
    _ = try sl.put("b", "2");
    _ = try sl.put("c", "3");

    var it = try sl.iterate("b");
    defer it.deinit();
    const first = it.next().?;
    try std.testing.expectEqualStrings("b", first.key);
    try std.testing.expectEqualStrings("2", first.value);
    const second = it.next().?;
    try std.testing.expectEqualStrings("c", second.key);
    try std.testing.expectEqualStrings("3", second.value);
    try std.testing.expect(it.next() == null);
}

test "iterate past end returns empty" {
    var sl = try StringSkipList.init(std.testing.allocator, std.testing.io, 42);
    defer sl.deinit();

    _ = try sl.put("a", "1");

    var it = try sl.iterate("z");
    defer it.deinit();
    try std.testing.expect(it.next() == null);
}
