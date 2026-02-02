const std = @import("std");

const Stats = struct {
    min: i16,
    max: i16,
    sum: i64,
    count: i32,
};

const Map = std.StringHashMap(Stats);

const vec_len = std.simd.suggestVectorLength(u8) orelse 1;
const Vec = @Vector(vec_len, u8);

inline fn findSemicolon(chunk: []const u8, start: usize) usize {
    if (vec_len > 1) {
        var pos = start;
        const splat: Vec = @splat(';');
        while (pos + vec_len <= chunk.len) {
            const block: Vec = chunk[pos..][0..vec_len].*;
            const matches = block == splat;
            if (@reduce(.Or, matches)) {
                return pos + std.simd.firstTrue(matches).?;
            }
            pos += vec_len;
        }
        while (pos < chunk.len) : (pos += 1) {
            if (chunk[pos] == ';') return pos;
        }
        unreachable;
    } else {
        return std.mem.indexOfScalarPos(u8, chunk, start, ';').?;
    }
}

inline fn parseTempAndLen(bytes: []const u8) struct { temp: i16, len: usize } {
    const neg: usize = @intFromBool(bytes[0] == '-');
    if (bytes[neg + 1] == '.') {
        const val: i16 = @as(i16, bytes[neg] - '0') * 10 + @as(i16, bytes[neg + 2] - '0');
        return .{ .temp = if (neg == 1) -val else val, .len = neg + 3 };
    } else {
        const val: i16 = @as(i16, bytes[neg] - '0') * 100 +
            @as(i16, bytes[neg + 1] - '0') * 10 +
            @as(i16, bytes[neg + 3] - '0');
        return .{ .temp = if (neg == 1) -val else val, .len = neg + 4 };
    }
}

fn processChunk(chunk: []const u8, allocator: std.mem.Allocator) !Map {
    var stats = Map.init(allocator);
    try stats.ensureTotalCapacity(8192);

    var start: usize = 0;
    while (start < chunk.len) {
        const semi = findSemicolon(chunk, start);
        const name = chunk[start..semi];
        const parsed = parseTempAndLen(chunk[semi + 1 ..]);
        const temp = parsed.temp;
        start = semi + 1 + parsed.len + 1; // +1 skips '\n'

        const gop = stats.getOrPutAssumeCapacity(name);
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

    var stx = std.mem.zeroes(std.os.linux.Statx);
    _ = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    const file_size: usize = @intCast(stx.size);

    const data = try std.posix.mmap(
        null,
        file_size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(data);

    try std.posix.madvise(data.ptr, data.len, std.c.MADV.WILLNEED);
    try std.posix.madvise(data.ptr, data.len, std.c.MADV.SEQUENTIAL);
    std.posix.madvise(data.ptr, data.len, std.c.MADV.HUGEPAGE) catch {};

    const cpu_count = try std.Thread.getCpuCount();
    const chunk_size = file_size / cpu_count;

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

    const threads = try allocator.alloc(std.Thread, cpu_count - 1);
    for (0..cpu_count - 1) |i| {
        threads[i] = try std.Thread.spawn(.{}, ThreadContext.run, .{&contexts[i + 1]});
    }
    contexts[0].run();

    for (threads) |t| {
        t.join();
    }

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

    const StationEntry = struct {
        name: []const u8,
        s: Stats,
    };

    const entries = try allocator.alloc(StationEntry, stats.unmanaged.size);
    var idx: usize = 0;
    var it = stats.iterator();
    while (it.next()) |entry| {
        entries[idx] = .{ .name = entry.key_ptr.*, .s = entry.value_ptr.* };
        idx += 1;
    }

    std.mem.sortUnstable(StationEntry, entries, {}, struct {
        fn cmp(_: void, a: StationEntry, b: StationEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.cmp);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.ioBasic();
    defer threaded.deinit();

    var write_buf: [2048]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &write_buf);
    const w = &fw.interface;
    try w.writeAll("{");
    const first = entries[0];
    const fminf = @as(f64, @floatFromInt(first.s.min)) / 10.0;
    const fmaxf = @as(f64, @floatFromInt(first.s.max)) / 10.0;
    const meanf = @as(f64, @floatFromInt(first.s.sum)) / @as(f64, @floatFromInt(first.s.count)) / 10.0;
    try w.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ first.name, fminf, meanf, fmaxf });

    for (entries[1..]) |e| {
        try w.writeAll(", ");
        const fmin = @as(f64, @floatFromInt(e.s.min)) / 10.0;
        const fmax = @as(f64, @floatFromInt(e.s.max)) / 10.0;
        const mean = @as(f64, @floatFromInt(e.s.sum)) / @as(f64, @floatFromInt(e.s.count)) / 10.0;
        try w.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ e.name, fmin, mean, fmax });
    }
    try w.writeAll("}\n");
    try w.flush();
}
