# wd40

> If it moves and it shouldn't: duct tape.
> If it doesn't move and it should: **WD-40**.

A collection of small utility scripts that unstick things.
Each script does one job, does it well, and gets out of the way.

## Scripts

| Script | What it unsticks |
|---|---|
| [`smem-groups.sh`](scripts/smem-groups.sh) | Aggregates `smem -tk` output by process group. Sums Swap/USS/PSS/RSS per category and shows the real memory footprint (PSS+Swap) instead of 100+ per-process lines. |

## Install

```sh
git clone https://github.com/jeffujioka/wd40.git
cd wd40
./install.sh
```

This symlinks every script into `~/.local/sbin`, dropping the extension,
so `scripts/smem-groups.sh` becomes the command `smem-groups`.

`~/.local/sbin` is not on `PATH` by default on macOS or Linux. If it's
missing, the installer adds it to your `~/.bashrc` or `~/.zshrc`
automatically (a guarded block, like rustup/cargo append — safe to
re-source, never duplicated on re-run). For any other shell, or if the rc
file doesn't exist yet, it prints the exact line to add instead. Restart
your shell (or `source` the rc file) afterwards.

### Options

```
-d, --dir DIR    directory to place symlinks in (default: ~/.local/sbin)
-n, --dry-run    print what would happen; change nothing
-f, --force      overwrite existing files that are not ours
-u, --uninstall  remove this repository's symlinks
-h, --help       show help
```

Directory precedence: `--dir` > `$WD40_BIN_DIR` > `~/.local/sbin`.

Existing files and symlinks that the installer does not own are skipped
with a warning rather than overwritten. `--uninstall` removes a link only
when it resolves back into this repository, so an unrelated tool sharing
a name is safe.

Symlinks are absolute, so the installed commands keep working no matter
where the target directory sits relative to the clone.

## Windows

No installer yet. Invoke scripts directly. The POSIX installer already
skips `.ps1`, `.bat`, and `.cmd` files, so Windows scripts can be added
here before a Windows installer exists.

## Tests

```sh
./test/smoke.sh
```

Plain bash, no framework. Runs unchanged on macOS and Linux.

## Compatibility

`install.sh` and the scripts target bash 3.2 and BSD userland, because
macOS still ships bash 3.2 as `/bin/bash`.

## License

MIT
