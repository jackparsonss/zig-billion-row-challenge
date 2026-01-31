const std = @import("std");

const Stats = struct {
    min: i16,
    max: i16,
    sum: i64,
    count: i32,
};

const map = std.StringHashMap(Stats);
const array = std.ArrayList(*[]const u8);

/// Parses a temperature string in the format -?[0-9]{1,2}\.[0-9]
/// into a fixed-point integer (value * 10). E.g. "13.5" -> 135, "-7.2" -> -72.
/// No loops — directly indexes the known positions.
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

    idx += 1; // skip '.'
    result = result * 10 + @as(i16, bytes[idx] - '0');

    return if (neg) -result else result;
}

pub fn solution2() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stats = map.init(allocator);
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
        const temp = parseTemp(value[0 .. value.len - 1]);

        const gop = try stats.getOrPut(name);
        if (gop.found_existing) {
            gop.value_ptr.min = @min(gop.value_ptr.min, temp);
            gop.value_ptr.max = @max(gop.value_ptr.max, temp);
            gop.value_ptr.count += 1;
            gop.value_ptr.sum += temp;
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            gop.value_ptr.* = .{
                .min = temp,
                .max = temp,
                .count = 1,
                .sum = temp,
            };
        }
    }

    var stations = try array.initCapacity(allocator, stats.unmanaged.size);
    var it = stats.keyIterator();
    while (it.next()) |station_name| {
        try stations.append(allocator, station_name);
    }

    std.mem.sort(*[]const u8, stations.items, {}, struct {
        fn lessThan(_: void, a: *[]const u8, b: *[]const u8) bool {
            return std.mem.order(u8, a.*, b.*) == .lt;
        }
    }.lessThan);

    std.debug.print("{{", .{});
    for (stations.items, 0..) |station, i| {
        if (i > 0) {
            std.debug.print(", ", .{});
        }
        const s = stats.get(station.*).?;
        const fmin = @as(f64, @floatFromInt(s.min)) / 10.0;
        const fmax = @as(f64, @floatFromInt(s.max)) / 10.0;
        const mean = @as(f64, @floatFromInt(s.sum)) / @as(f64, @floatFromInt(s.count)) / 10.0;
        std.debug.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ station.*, fmin, mean, fmax });
    }

    std.debug.print("}}\n", .{});
}
