# skiplist

A generic, thread-safe skip list implemented in Zig (requires 0.16.0+).

A skip list is a probabilistic data structure that keeps keys sorted and supports O(log n) average-case search, insert, and delete — similar to a balanced BST but simpler to implement.

## Features

- Generic over key and value types via a user-supplied `compareFn`
- Upsert (`put`), lookup (`get`), deletion (`delete`), and range iteration (`iterate`)
- Thread-safe: a readers-writer lock (`std.Io.RwLock`) allows concurrent reads; the iterator holds a shared read lock until `deinit` is called
- Up to 32 levels, promotion probability p = 0.5

## Usage

```zig
const std = @import("std");
const SkipList = @import("skiplist").SkipList;

fn compareI32(a: i32, b: i32) std.math.Order {
    return std.math.order(a, b);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var prng = std.Random.DefaultPrng.init(0);
    var sl = try SkipList(i32, []const u8, compareI32).init(init.gpa, io, prng.random());
    defer sl.deinit();

    try sl.put(1, "one");
    try sl.put(2, "two");
    try sl.put(3, "three");

    const v = try sl.get(2); // "two"
    _ = v;

    try sl.delete(1);

    // Iterate from key 2 onward
    var it = try sl.iterate(2);
    defer it.deinit(); // releases the read lock
    while (it.next()) |entry| {
        _ = entry.key;
        _ = entry.value;
    }
}
```

## API

| Function | Description |
|---|---|
| `init(allocator, io, rng)` | Create a new skip list. The `rng` must outlive the list. |
| `deinit()` | Free all nodes. Caller must ensure no concurrent access. |
| `put(key, value) !void` | Insert or update a key. |
| `get(key) !V` | Return the value or `error.KeyNotFound`. |
| `delete(key) !void` | Remove a key; no-op if absent. |
| `iterate(start) !Iterator` | Return an `Iterator` starting at the first key >= `start`. Call `it.deinit()` when done to release the read lock. |

## Running tests

```sh
zig build test
```
