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
