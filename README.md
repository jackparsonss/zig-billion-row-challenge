# zig-billion-row-challenge

### Generating Data
```
cd data
python3 create_measurements.py 1_000_000_000
```

### Running Experiment
```
zig build run -Doptimize=ReleaseFast
```

### Solution 1(base solution)
Runs in 64.26 Seconds

### Solution 2(Parse floats as ints)
Runs in 42.64 Seconds

### Solution 3(mmap + concurrency)
Runs in 4.34 Seconds

### Solution 4(printing)
Runs in 4.13 Seconds
