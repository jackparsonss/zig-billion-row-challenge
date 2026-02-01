const std = @import("std");

const Stats = struct {
    min: f16,
    max: f16,
    sum: f64,
    count: i32,
};

const map = std.StringHashMap(Stats);
const array = std.ArrayList([]const u8);

pub fn solution() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stats = map.init(allocator);
    try stats.ensureTotalCapacity(8192);
    defer stats.deinit();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.ioBasic();
    defer threaded.deinit();

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, "data/measurements.txt", .{
        .mode = .read_only,
    });
    defer file.close(io);

    var read_buffer: [65536]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    var reader = &fr.interface;

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        var it = std.mem.splitScalar(u8, line, ';');
        const name = it.next().?;
        const value = it.next().?;
        const f = try std.fmt.parseFloat(f16, value[0 .. value.len - 1]);

        const gop = try stats.getOrPut(name);
        if (gop.found_existing) {
            gop.value_ptr.min = @min(gop.value_ptr.min, f);
            gop.value_ptr.max = @max(gop.value_ptr.max, f);
            gop.value_ptr.count += 1;
            gop.value_ptr.sum += f;
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            gop.value_ptr.* = .{
                .min = f,
                .max = f,
                .count = 1,
                .sum = f,
            };
        }
    }

    var stations = try array.initCapacity(allocator, stats.unmanaged.size);
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
        const mean = s.sum / @as(f64, @floatFromInt(s.count));
        std.debug.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ station, s.min, mean, s.max });
    }

    std.debug.print("}}\n", .{});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == std.math.Order.lt;
}
