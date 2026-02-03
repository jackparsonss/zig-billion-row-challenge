const std = @import("std");

const BUCKET_COUNT = 1 << 15; // 32768 — ~27% load for ~8868 stations
const BUCKET_MASK = BUCKET_COUNT - 1;

const Bucket = struct {
    name: []const u8 = &.{},
    sum: i64 = 0,
    count: i32 = 0,
    min: i16 = 0,
    max: i16 = 0,
};

const StationMap = struct {
    buckets: [BUCKET_COUNT]Bucket = @splat(Bucket{}),

    inline fn hash(name: []const u8) u32 {
        var h: u64 = name.len;
        if (name.len >= 8) {
            h ^= @as(u64, @bitCast(name.ptr[0..8].*));
        } else if (name.len >= 4) {
            h ^= @as(u64, @as(u32, @bitCast(name.ptr[0..4].*)));
        } else {
            h ^= name[0];
        }
        h *%= 0x517cc1b727220a95;
        return @truncate(h >> 49); // top 15 bits → 0..32767
    }

    inline fn getOrPut(self: *StationMap, name: []const u8) *Bucket {
        return self.getOrPutWithIndex(name, hash(name));
    }

    inline fn getOrPutWithIndex(self: *StationMap, name: []const u8, idx_init: usize) *Bucket {
        var idx = idx_init;
        while (true) {
            const b = &self.buckets[idx];
            if (b.count == 0) return b;
            if (b.name.len == name.len and std.mem.eql(u8, b.name, name)) return b;
            idx = (idx + 1) & BUCKET_MASK;
        }
    }
};

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
    const two_digit: usize = @intFromBool(bytes[neg + 1] != '.');
    const ones_off = neg + two_digit;
    const tens: i16 = @as(i16, bytes[neg] - '0') * @as(i16, @intCast(two_digit));
    const ones: i16 = @as(i16, bytes[ones_off] - '0');
    const tenths: i16 = @as(i16, bytes[ones_off + 2] - '0');
    const val: i16 = tens * 100 + ones * 10 + tenths;
    const sign: i16 = 1 - @as(i16, @intCast(neg)) * 2;
    return .{ .temp = val * sign, .len = ones_off + 3 };
}

fn processChunk(chunk: []const u8, stats: *StationMap) void {
    var start: usize = 0;
    while (start < chunk.len) {
        const semi = findSemicolon(chunk, start);
        const name = chunk[start..semi];

        // Prefetch hash bucket before parsing temp to overlap cache miss with computation
        const idx = StationMap.hash(name);
        @prefetch(&stats.buckets[idx], .{ .rw = .read, .locality = 3 });

        const parsed = parseTempAndLen(chunk[semi + 1 ..]);
        const temp = parsed.temp;
        start = semi + 1 + parsed.len + 1;

        const b = stats.getOrPutWithIndex(name, idx);
        if (b.count != 0) {
            b.min = @min(b.min, temp);
            b.max = @max(b.max, temp);
            b.count += 1;
            b.sum += temp;
        } else {
            b.* = .{
                .name = name,
                .sum = temp,
                .count = 1,
                .min = temp,
                .max = temp,
            };
        }
    }
}

const ThreadContext = struct {
    chunk: []const u8,
    map: StationMap = .{},

    fn run(self: *ThreadContext) void {
        const page_size = 4096;
        const chunk_start = @intFromPtr(self.chunk.ptr);
        const aligned_start = chunk_start & ~@as(usize, page_size - 1);
        const aligned_end = (chunk_start + self.chunk.len + page_size - 1) & ~@as(usize, page_size - 1);
        const aligned_len = aligned_end - aligned_start;
        const aligned_ptr: [*]align(4096) u8 = @ptrFromInt(aligned_start);

        std.posix.madvise(aligned_ptr, aligned_len, std.c.MADV.SEQUENTIAL) catch {};
        std.posix.madvise(aligned_ptr, aligned_len, std.c.MADV.WILLNEED) catch {};

        processChunk(self.chunk, &self.map);
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

    try std.posix.madvise(data.ptr, data.len, std.c.MADV.HUGEPAGE);

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

    var final_map: StationMap = .{};
    for (contexts) |*ctx| {
        for (&ctx.map.buckets) |*bucket| {
            if (bucket.count != 0) {
                const b = final_map.getOrPut(bucket.name);
                if (b.count != 0) {
                    b.min = @min(b.min, bucket.min);
                    b.max = @max(b.max, bucket.max);
                    b.count += bucket.count;
                    b.sum += bucket.sum;
                } else {
                    b.* = bucket.*;
                }
            }
        }
    }

    var entries: [BUCKET_COUNT]Bucket = undefined;
    var entry_count: usize = 0;
    for (&final_map.buckets) |*bucket| {
        if (bucket.count != 0) {
            entries[entry_count] = bucket.*;
            entry_count += 1;
        }
    }

    const sorted = entries[0..entry_count];
    std.mem.sortUnstable(Bucket, sorted, {}, struct {
        fn cmp(_: void, a: Bucket, b: Bucket) bool {
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
    const first = sorted[0];
    const fminf = @as(f64, @floatFromInt(first.min)) / 10.0;
    const fmaxf = @as(f64, @floatFromInt(first.max)) / 10.0;
    const meanf = @as(f64, @floatFromInt(first.sum)) / @as(f64, @floatFromInt(first.count)) / 10.0;
    try w.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ first.name, fminf, meanf, fmaxf });

    for (sorted[1..]) |e| {
        try w.writeAll(", ");
        const fmin = @as(f64, @floatFromInt(e.min)) / 10.0;
        const fmax = @as(f64, @floatFromInt(e.max)) / 10.0;
        const mean = @as(f64, @floatFromInt(e.sum)) / @as(f64, @floatFromInt(e.count)) / 10.0;
        try w.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ e.name, fmin, mean, fmax });
    }
    try w.writeAll("}\n");
    try w.flush();
}
