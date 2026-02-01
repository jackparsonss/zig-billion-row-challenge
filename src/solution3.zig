const std = @import("std");

const Stats = struct {
    min: i16,
    max: i16,
    sum: i64,
    count: i32,
};

const Map = std.StringHashMap(Stats);
const Array = std.ArrayList([]const u8);

inline fn parseTemp(bytes: []const u8) i16 {
    var idx: usize = 0;
    const neg = bytes[0] == '-';
    if (neg) idx = 1;

    var result: i16 = bytes[idx] - '0';
    idx += 1;

    if (bytes[idx] != '.') {
        result = result * 10 + @as(i16, bytes[idx] - '0');
        idx += 1;
    }

    idx += 1;
    result = result * 10 + @as(i16, bytes[idx] - '0');

    return if (neg) -result else result;
}

fn processChunk(chunk: []const u8, allocator: std.mem.Allocator) !Map {
    var stats = Map.init(allocator);
    try stats.ensureTotalCapacity(8192);

    var start: usize = 0;
    while (start < chunk.len) {
        const semi = std.mem.indexOfScalarPos(u8, chunk, start, ';') orelse break;
        const name = chunk[start..semi];
        const end = std.mem.indexOfScalarPos(u8, chunk, semi + 1, '\n') orelse chunk.len;
        const value = chunk[semi + 1 .. end];
        const temp = parseTemp(value);
        start = end + 1;

        const gop = try stats.getOrPut(name);
        if (gop.found_existing) {
            gop.value_ptr.min = @min(gop.value_ptr.min, temp);
            gop.value_ptr.max = @max(gop.value_ptr.max, temp);
            gop.value_ptr.count += 1;
            gop.value_ptr.sum += temp;
        } else {
            gop.value_ptr.* = .{
                .min = temp,
                .max = temp,
                .count = 1,
                .sum = temp,
            };
        }
    }

    return stats;
}

const ThreadContext = struct {
    chunk: []const u8,
    result: Map = Map.init(undefined),
    arena: std.heap.ArenaAllocator,

    fn run(self: *ThreadContext) void {
        self.result = processChunk(self.chunk, self.arena.allocator()) catch unreachable;
    }
};

pub fn solution() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fd = try std.posix.openat(std.posix.AT.FDCWD, "data/measurements.txt", .{}, 0);
    defer std.posix.close(fd);

    const stat = try std.posix.fstat(fd);
    const file_size: usize = @intCast(stat.size);

    const data = try std.posix.mmap(
        null,
        file_size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(data);

    // Pre-fault pages and hint sequential access
    std.posix.madvise(data.ptr, data.len, std.c.MADV.WILLNEED) catch {};
    std.posix.madvise(data.ptr, data.len, std.c.MADV.SEQUENTIAL) catch {};

    const cpu_count = try std.Thread.getCpuCount();
    const chunk_size = file_size / cpu_count;

    // Split into chunks aligned to newlines
    const contexts = try allocator.alloc(ThreadContext, cpu_count);
    var offset: usize = 0;
    for (0..cpu_count) |i| {
        var end: usize = if (i == cpu_count - 1) file_size else offset + chunk_size;

        if (end < file_size) {
            while (end < file_size and data[end] != '\n') {
                end += 1;
            }
            if (end < file_size) end += 1;
        }

        contexts[i] = .{
            .chunk = data[offset..end],
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        offset = end;
    }

    // Spawn workers — process chunk 0 on main thread to save one thread spawn
    const threads = try allocator.alloc(std.Thread, cpu_count - 1);
    for (0..cpu_count - 1) |i| {
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[i + 1]});
    }
    contexts[0].run();

    for (threads) |t| {
        t.join();
    }

    // Merge per-thread results
    var stats = Map.init(allocator);
    for (contexts) |*ctx| {
        var iter = ctx.result.iterator();
        while (iter.next()) |entry| {
            const gop = try stats.getOrPut(entry.key_ptr.*);
            if (gop.found_existing) {
                gop.value_ptr.min = @min(gop.value_ptr.min, entry.value_ptr.min);
                gop.value_ptr.max = @max(gop.value_ptr.max, entry.value_ptr.max);
                gop.value_ptr.count += entry.value_ptr.count;
                gop.value_ptr.sum += entry.value_ptr.sum;
            } else {
                gop.value_ptr.* = entry.value_ptr.*;
            }
        }
        ctx.arena.deinit();
    }

    // Sort and print
    var stations = try Array.initCapacity(allocator, stats.unmanaged.size);
    var it = stats.keyIterator();
    while (it.next()) |station_name| {
        try stations.append(allocator, station_name.*);
    }

    std.mem.sortUnstable([]const u8, stations.items, {}, lessThan);

    std.debug.print("{{", .{});
    for (stations.items, 0..) |station, i| {
        if (i > 0) {
            std.debug.print(", ", .{});
        }
        const s = stats.get(station).?;
        const fmin = @as(f64, @floatFromInt(s.min)) / 10.0;
        const fmax = @as(f64, @floatFromInt(s.max)) / 10.0;
        const mean = @as(f64, @floatFromInt(s.sum)) / @as(f64, @floatFromInt(s.count)) / 10.0;
        std.debug.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ station, fmin, mean, fmax });
    }

    std.debug.print("}}\n", .{});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == std.math.Order.lt;
}
