# wd40

> If it moves and it shouldn't: duct tape.
> If it doesn't move and it should: **WD-40**.

A collection of small utility scripts that unstick things.
Each script does one job, does it well, and gets out of the way.

## Scripts

| Script | What it unsticks |
|---|---|
| [`smem-groups.sh`](smem-groups.sh) | Aggregates `smem -tk` output by process group. Sums Swap/USS/PSS/RSS per category and shows the real memory footprint (PSS+Swap) instead of 100+ per-process lines. |

## Usage

Each script is self-contained and documents itself:

```sh
./smem-groups.sh -h
```

## License

MIT
