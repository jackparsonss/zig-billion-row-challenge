# The Billion Row Challenge in Zig — From 64 Seconds to 2.3

## INTRO [~1:30]

**[HOOK — 0:00-0:15]**

> "What if I told you we could make this program 28 times faster — and all it takes is about 200 lines of Zig? Let me show you how."

**[Show a terminal: run the final solution, 2.32s result flashes on screen. Cut.]**

**[CONTEXT — 0:15-1:30]**

> "This is the Billion Row Challenge. The task is simple: you've got a text file with one billion lines. Each line is a weather station name, a semicolon, and a temperature. That's it. Your job: calculate the min, max, and mean temperature for every station, then print them alphabetically."

**[Animate/show a few sample lines of the data file:]**
```
Hamburg;12.0
Bulawayo;8.9
Palembang;38.8
Hamburg;-1.2
```

> "Simple problem. But the file is 14 gigabytes. And my naive solution takes over a minute. So let's fix that — step by step — until we're under 2.5 seconds."

**[Flash the benchmark table on screen — all 8 solutions with times. This is the roadmap viewers will mentally track throughout.]**

---

## SOLUTION 1: THE NAIVE BASELINE [~2:30]

**[Animate the full Solution 1 on screen. This is the one place to show the complete code since it's the foundation everything builds on.]**

> "Here's the starting point. And honestly, it's pretty clean Zig. We open the file, read it line by line with a 64K buffer, split each line on the semicolon, parse the temperature as a float, and shove it into a hash map."

**[Highlight these key parts as you narrate:]**

1. **The Stats struct** — `min: f16, max: f16, sum: f64, count: i32`
2. **The parsing** — `std.fmt.parseFloat(f16, value)` — "This is doing a *lot* of work for every single line"
3. **The hash map** — `StringHashMap` — "Zig's standard library hash map. It works, but it's general-purpose."
4. **The output** — `std.debug.print` — "We'll come back to this one."

> "64 seconds. Not terrible for a billion rows, but we can do a *lot* better. The question is: where's the time going?"

**[Show pie chart or bar graphic: rough breakdown — parsing, I/O, hashing, output]**

---

## SOLUTION 2: STOP PARSING FLOATS [~2:00]

> "The first optimization is almost embarrassingly obvious once you see it. Every temperature in this file looks like this:"

**[Show: `-12.3`, `8.5`, `42.1`]**

> "It's always one or two digits, a decimal point, and exactly one digit after. So why are we calling a full float parser? We can just... do integer math."

**[Animate the `parseTemp` function appearing — this is a great one to TYPE OUT live since it's short and satisfying:]**

```zig
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
```

> "We store 13.5 degrees as the integer 135. Negative sign? Check the first byte. One digit or two before the decimal? Check if byte two is a dot. That's it. No allocation, no parsing library, just raw byte math."

> "This gets us from 64 seconds down to 42. A 1.5x speedup just from not parsing floats. But honestly? We're still leaving *massive* performance on the table. Because we're still single-threaded."

**[Flash: 64.26s → 42.64s | 1.5x]**

---

## SOLUTION 3: THE BIG ONE — MMAP + THREADS [~3:30]

> "This is the jump that matters. This is where we go from 42 seconds to 4. And it comes down to two ideas."

**[Beat.]**

> "Idea one: stop *reading* the file. Instead, memory-map it."

**[Animate the mmap call:]**
```zig
const data = try std.posix.mmap(
    null, file_size,
    .{ .READ = true },
    .{ .TYPE = .SHARED },
    fd, 0,
);
```

> "Memory mapping tells the operating system: 'treat this file like it's already in memory.' No read calls, no copying into buffers. The OS handles paging data in and out as we access it. For a 14 gig file, this is a *massive* win."

> "But the real speedup is idea two: threads. We figure out how many CPU cores we have, divide the file into that many chunks, and let each core chew through its section independently."

**[Animate the thread spawning — show the conceptual split of the file into N chunks:]**

> "Each thread gets its own hash map, processes its chunk, and when they're all done, we merge the results. The key detail? When we split the file, we can't just cut at arbitrary byte offsets — we'd slice a line in half. So we scan forward to the next newline to find clean boundaries."

**[Show the boundary-finding logic briefly]**

> "42 seconds down to 4.3. That's a 10x jump in one step. This is why people say 'the biggest optimization is doing less work' — or in this case, doing the work in parallel."

**[Flash: 42.64s → 4.34s | 14.8x total]**

---

## SOLUTION 4: THE SNEAKY ONE — PRINTING [~1:00]

> "This one's funny. We went from 64 seconds to 4 seconds with clever algorithms... and then shaved off another 200 milliseconds by changing how we *print the answer*."

> "Solution 3 uses `std.debug.print`. That writes to stderr, unbuffered. Every single station triggers a write syscall. Solution 4 switches to a buffered stdout writer — batch everything into a 2K buffer, flush once."

**[Show the diff — just the output section changing. Quick animation, no need to type.]**

> "Is this the most exciting optimization? No. But it's a good reminder: profile everything. Even your output code."

**[Flash: 4.34s → 4.13s | 15.6x total]**

---

## SOLUTION 5: SIMD — LET THE CPU CHEAT [~3:00]

> "Now we get into the fun stuff. SIMD — Single Instruction, Multiple Data. Instead of scanning for a semicolon one byte at a time, we load 16 or 32 bytes at once and check them all simultaneously."

**[Animate the SIMD concept visually — show a vector of 16 bytes being compared against `;` all at once, with matches lighting up]**

> "Zig makes this surprisingly clean:"

**[Animate the key SIMD code:]**
```zig
const vec_len = std.simd.suggestVectorLength(u8) orelse 1;
const Vec = @Vector(vec_len, u8);

const splat: Vec = @splat(';');
const block: Vec = chunk[pos..][0..vec_len].*;
const matches = block == splat;
```

> "We ask Zig for the optimal vector width for our CPU. Then we splat the semicolon across every lane, load a chunk of input, and compare — all in one or two instructions. If there's a match anywhere in the vector, we find exactly which position with `firstTrue`."

> "This also gets applied to finding newlines. And the temperature parser gets a small facelift too — fewer branches, more direct byte math."

**[Flash: 4.13s → 3.48s | 18.5x total]**

---

## SOLUTION 6: [BRIEF MENTION — ~0:20]

> "Solution 6 reorganizes how we collect station data for sorting — using a struct array instead of separate arrays. It's cleaner code, but the benchmarks show the same 3.48 seconds. So let's skip to where the next real speedup happens."

**[Flash: 3.48s → 3.48s | Same]**

---

## SOLUTION 7: THROW AWAY THE STANDARD LIBRARY [~3:30]

> "The standard library hash map is good. It handles resizing, arbitrary key types, collision resolution — all the things a general-purpose hash map needs. But we don't need general-purpose. We know exactly what we're dealing with: around 9,000 unique station names, short strings, and we never delete entries."

> "So we build our own."

**[Animate the custom hash table — this is worth showing in detail:]**

```zig
const BUCKET_COUNT = 1 << 15; // 32,768 buckets
const Bucket = struct {
    name: []const u8 = &.{},
    sum: i64 = 0,
    count: i32 = 0,
    min: i16 = 0,
    max: i16 = 0,
};
```

> "32,768 buckets for ~9,000 stations. That's roughly 27% load factor — lots of empty space means fewer collisions. And the hash function?"

**[Animate the hash function — TYPE THIS ONE OUT, it's short and interesting:]**

```zig
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
    return @truncate(h >> 49);
}
```

> "We XOR the name length with the first 4 or 8 bytes of the name — reinterpreted as an integer. Multiply by a magic constant. Take the top bits. That's our bucket index. No allocations, no hashing library, no overhead."

> "Collision resolution? Linear probing. Just check the next slot. With a 27% load factor, we almost never need to."

> "The big win here isn't just a faster hash — it's that the entire hash table is a flat array on the stack. No heap allocations in the hot loop. No pointer chasing. The CPU's cache is *happy*."

**[Flash: 3.48s → 2.53s | 25.4x total — this is the second biggest jump]**

---

## SOLUTION 8: THE FINAL POLISH [~2:00]

> "We're at 2.5 seconds. The last solution squeezes out another 200 milliseconds with three micro-optimizations."

> "First: the temperature parser goes fully branchless."

**[Show the branchless version — animate side-by-side with Solution 5's version:]**

```zig
const neg: usize = @intFromBool(bytes[0] == '-');
const two_digit: usize = @intFromBool(bytes[neg + 1] != '.');
const tens: i16 = @as(i16, bytes[neg] - '0') * @as(i16, @intCast(two_digit));
// No if statements. The CPU never has to guess.
```

> "No if-statements. `@intFromBool` converts true/false to 1/0, and we multiply by it. The CPU never mispredicts a branch because there are no branches."

> "Second: prefetching. Before we parse the temperature, we already know the station name and its hash bucket. So we tell the CPU: 'start loading that bucket into cache *now*, while I'm busy parsing the temperature.'"

**[Show the prefetch call:]**
```zig
@prefetch(&stats.buckets[idx], .{ .rw = .read, .locality = 3 });
```

> "By the time we need the bucket, it's already warm in L1 cache."

> "Third: huge pages. We ask the OS to use 2MB memory pages instead of 4KB ones. Fewer entries in the page table, fewer TLB misses."

> "Each of these alone is tiny. Together: 2.53 down to 2.32."

**[Flash: 2.53s → 2.32s | 27.7x total]**

---

## OUTRO [~1:30]

**[Show the full benchmark table one final time, with a bar chart animating each solution's time]**

> "64 seconds to 2.3. A 28x speedup. And here's what I think is interesting about this progression:"

> "The biggest wins weren't the clever low-level tricks. Threading gave us 10x. The custom hash table gave us another big jump. SIMD and prefetching? They helped, but they were incremental."

> "The lesson is: optimize the *architecture* first — how you read data, how you parallelize, how you structure your data. Then, and only then, go micro. The sexy SIMD stuff only works if the foundation is already solid."

> "And honestly, Zig is kind of perfect for this. It gives you SIMD vectors as a language primitive. `@prefetch` is a builtin. `mmap` is in the standard library. You get C-level control without writing C."

**[Beat.]**

> "If you want to try this yourself, all the code is linked below. And if you learned something — well, you know what to do."

**[End card.]**

---

## PRODUCTION NOTES

**Where to type code live vs. animate:**
- **TYPE live:** Solution 2's `parseTemp` function (satisfying, short, teaches byte math) and Solution 7's `hash` function (interesting, generates curiosity about the magic constant)
- **Animate everything else** — especially Solution 1 (it's the longest), the mmap/threading setup in Solution 3, and the SIMD code in Solution 5

**Pacing targets:**

| Section | Target Time |
|---------|-------------|
| Intro | 1:30 |
| Solution 1 (base) | 2:30 |
| Solution 2 (int parsing) | 2:00 |
| Solution 3 (mmap + threads) | 3:30 |
| Solution 4 (printing) | 1:00 |
| Solution 5 (SIMD) | 3:00 |
| Solution 6 (skip) | 0:20 |
| Solution 7 (custom hash) | 3:30 |
| Solution 8 (final polish) | 2:00 |
| Outro | 1:30 |
| **Total** | **~20:50** |

You're slightly over 20 min on paper, but real delivery is always tighter than scripted — you'll land right around 18-20 minutes. If you need to trim, Solution 4 (printing) can be condensed to 30 seconds, and Solution 8's huge pages explanation can be cut to one sentence.
