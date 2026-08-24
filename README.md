# wd40

> If it moves and it shouldn't: duct tape.
> If it doesn't move and it should: **WD-40**.

A collection of small utilities that unstick things.
Each one does one job, does it well, and gets out of the way.

There are two kinds. `scripts/` holds files that are executed. `shell/`
holds files that are sourced by an interactive shell, because something
that only earns its keep as one word at a prompt cannot be an executable.

## Scripts

| Script | What it unsticks |
|---|---|
| [`smem-groups.sh`](scripts/smem-groups.sh) | Aggregates `smem -tk` output by process group. Sums Swap/USS/PSS/RSS per category and shows the real memory footprint (PSS+Swap) instead of 100+ per-process lines. |
| [`wd40.sh`](scripts/wd40.sh) | Says what this repository provides, and whether it is installed here. |

## Shell functions

| Function | What it unsticks |
|---|---|
| [`fp`](shell/wd40-paths.sh) | Prints the absolute path of a file or directory and puts it on the clipboard, so a path you can already see is a path you can paste. |
| [`fpr`](shell/wd40-paths.sh) | `fp --relative`: the same path with the current directory taken off the front. |
| [`fpn`](shell/wd40-paths.sh) | `fp --no-clipboard`: printed and not copied. |
| [`fpnr`](shell/wd40-paths.sh) | Both at once. |

## wd40

`wd40 list` prints one line per command, grouped by kind:

```
$ wd40 list
scripts
  smem-groups   aggregate `smem -tk` output by process group
  wd40          list the commands this repository provides

shell functions
  fp            print the absolute path of a file or directory, and copy it to the clipboard
  fpr           fp --relative, for a path relative to the current directory
  fpn           fp --no-clipboard, for a path that is printed and not copied
  fpnr          fp --no-clipboard --relative, for both at once
```

`list` describes **the repository**, not the machine. The names and
descriptions are read out of the repository's own files, so the answer is
the same wherever it is read from. Whether a command is *installed* is a
question about **the machine**, and that is what the mark answers:

```
$ wd40 list
scripts
  smem-groups   aggregate `smem -tk` output by process group
  wd40          list the commands this repository provides

shell functions
! fp            print the absolute path of a file or directory, and copy it to the clipboard
! fpr           fp --relative, for a path relative to the current directory
! fpn           fp --no-clipboard, for a path that is printed and not copied
! fpnr          fp --no-clipboard --relative, for both at once

! not installed in /tmp/wd40-demo/aliases.d
```

A leading `!` means the symlink that would make that command available is
not there. The legend appears only when something is missing, and it names
the directory, because "not installed" without a "where" is half an answer
on a machine where `$WD40_BIN_DIR` points somewhere unexpected. Both are on
stdout, with the marks they explain, so `wd40 list > commands.txt` keeps
the key — and the mark sits in the first of the two columns the names are
indented by, so an installed line is exactly the line it would have been
and a missing one is greppable:

```
$ wd40 list | grep '^!'
! fp            print the absolute path of a file or directory, and copy it to the clipboard
! fpr           fp --relative, for a path relative to the current directory
! fpn           fp --no-clipboard, for a path that is printed and not copied
! fpnr          fp --no-clipboard --relative, for both at once
! not installed in /tmp/wd40-demo/aliases.d
```

Ownership is resolved, not guessed. A `smem-groups` of your own already on
your `PATH` is not this repository's install, and is marked `!` like
anything else that is missing. A checkout that has never been installed is
an ordinary thing to be standing in: every line is marked and the exit
status is 0.

A bare `wd40` prints the usage on stdout and exits 0 — this is a discovery
command, and typing its name with nothing after it is a question rather
than a mistake. `wd40 help`, `wd40 -h` and `wd40 --help` print the same
bytes. An unknown subcommand, or an argument to a command that takes none,
goes to stderr and exits 1.

```
Usage: wd40 <command>

  list                list every command this repository provides
  help, -h, --help    show this help

list describes this repository and not this machine: the commands are
read from the repository's own files, so the answer is the same wherever
it is read from. Whether each one is installed does depend on the
machine, and a command whose symlink is missing is marked with a leading
`!` and the directory it is missing from.

Script directory precedence: $WD40_BIN_DIR > ~/.local/sbin
Shell directory precedence:  $WD40_SHELL_DIR > ~/.zsh_aliases.d
```

`wd40` holds meta-commands only and never runs another command for you.
`wd40 smem-groups` was considered and rejected: a namespace by
implementation forces you to know whether a thing is a script or a shell
function before you can call it, which is the one distinction the two
halves of this repository exist to keep out of your way.

## Adding a command

Put the file in `scripts/` or `shell/` and declare what it provides in its
own header:

```sh
# wd40: fp - print the absolute path of a file or directory, and copy it to the clipboard
# wd40: fpr - fp --relative, for a path relative to the current directory
```

One line per **command**, not per file — `shell/wd40-paths.sh` is four
commands, and you think in commands. The line goes in the header: the run
of blank and comment lines before the first line of code. A description
that lives next to its code is a description that gets edited with it,
which a table inside `wd40.sh` would not be. Only the first ` - `
separates, so a description may hold as many more hyphens as it likes.

Two rules keep the listing honest, and both refuse the whole thing rather
than printing half of one. A file that declares nothing would be a command
that exists and is not listed:

```
$ wd40 list
Error: /tmp/wd40-demo/badclone/scripts/quiet.sh declares no command; add a header line reading: wd40: NAME - DESCRIPTION
```

A name that is not the name the command is installed under would be a
listing nobody can act on. Both names are printed, because either of them
could be the wrong one:

```
$ wd40 list
Error: /tmp/wd40-demo/badclone/scripts/tool.sh declares 'tolo', but install.sh installs it as 'tool'
```

A script gets exactly one declaration, because it is installed under
exactly one name. A shell file may declare as many commands as it defines.

Nothing else is needed: `install.sh` links everything under `scripts/`
that its allowlist accepts, so a new command is named in its own file and
nowhere else.

### fp

```
$ cd /tmp/demo
$ fp
/tmp/demo
$ fp build/app.bin
/tmp/demo/build/app.bin
$ fp ./src/main.c
/tmp/demo/src/main.c
$ fp ../notes.md
/tmp/demo/../notes.md
$ fp /etc/hosts
/etc/hosts
```

With no argument the answer is `$PWD`. With one, the argument is joined
onto `$PWD` as text.

Joined as text is the whole of it. The result is not resolved, `..` is not
collapsed, symlinks are not followed, and nothing has to exist. That is
deliberate: the common use is handing a path to another person or another
machine, and a build output that is not there yet is a perfectly good
argument. `realpath` answers a different question, and answers it only
where GNU coreutils is installed.

A bare `.` and one leading `./` are stripped, because `$PWD/./foo` is
nobody's intent. An argument that is already absolute comes back
unchanged, which makes `fp` idempotent.

The path goes to **stdout**, always, and the clipboard gets a copy of it
unless you said not to. There is no second stream and no receipt line, so
`fp foo > file` and `fpn foo > file` capture the same bytes — what you see
on the terminal *is* the confirmation. The clipboard's copy has **no
trailing newline**: a path with a newline on the end, pasted at a shell
prompt, runs immediately. Stdout keeps its newline, because that side is a
filter and behaves like one.

### fpr, and `--relative`

```
$ cd /tmp/demo
$ fpr src/main.c
src/main.c
$ fpr /tmp/demo/build/app.bin
build/app.bin
$ fpr
.
$ fpr /etc/hosts
/etc/hosts
```

`--relative` takes the current directory off the front and does nothing
else. `$PWD` itself comes back as `.`, because that is how a shell spells
"here".

A target that is **not** under `$PWD` keeps its absolute spelling rather
than growing a `../../` walk. Such a walk is the only version of this flag
that appears to work in every case, and it is the only one that can be
*wrong*: it is correct only once `..` has been collapsed and symlinks
resolved, and `fp` refuses to do either. Handing back a relative path that
does not reach the file is a worse answer than handing back an absolute
one that does.

### Options

`--relative`, `--no-clipboard`, `-h`, `--help`, and `--`. They may come in
any order, repeating one means nothing, and **every other argument is a
path** — including one that starts with `-`, which is what keeps a file
named `-x` reachable. `--` ends the options, for the four files this list
would otherwise have made unaddressable:

```
$ fp -- --relative
/tmp/demo/--relative
```

Repetition means nothing on purpose. The shorthands are functions that
prepend a flag, so `fpnr --no-clipboard x` sends `--no-clipboard` twice
without you ever seeing it twice; refusing that would be an error message
naming a word you did not type.

`fp` takes at most one path and exits 2 otherwise. The shorthands are
ordinary functions and not aliases — bash expands an alias only in an
interactive shell, and this file promises to behave the same in every one
— so `fpr --no-clipboard x` composes and reads as it looks.

### Clipboard

`fp` uses the first of these it can find: `$WD40_CLIP`, `pbcopy`,
`wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`. The
list is walked on every call rather than once at startup, so a shell that
outlives a change in its environment — an SSH session starting, Wayland
replacing X11 — notices. If none exists it says so and exits 1:

```
$ fp foo
/tmp/demo/foo
wd40: no clipboard command found (tried pbcopy, wl-copy, xclip, xsel)
wd40: set WD40_CLIP to the name of a command that reads stdin
```

A command that *does* exist and then fails says so too, naming itself and
the status it exited with. A `pbcopy` shim forwarding over SSH to a
listener that isn't running is the usual way to meet this one:

```
$ fp foo
/tmp/demo/foo
wd40: /tmp/wd40-demo/bin/badpbcopy failed (exit 1); nothing was copied
```

The path is on stdout in both, and the diagnostic on stderr. A clipboard
that failed does not cost you the answer: on a machine with no clipboard
at all, `fp` is `fpn` with a complaint attached, which is a usable command
rather than a broken one. Every way of failing prints something, so you
never have to work out that a silence was the error.

`$WD40_CLIP` holds a **command name, not a command line**. It is invoked
quoted, so this does not work:

```
$ WD40_CLIP="xclip -selection clipboard" fp foo
/tmp/demo/foo
wd40: WD40_CLIP names "xclip -selection clipboard", which is not a command
```

Splitting it into words would need `eval`, because bash splits an unquoted
expansion and zsh does not. Point it at a wrapper script when you need
arguments:

```sh
#!/bin/sh
exec xclip -selection clipboard
```

A `$WD40_CLIP` that names something which is not a command is an error
rather than a reason to fall back to the rest of the list. You said what
you wanted.

## Install

```sh
git clone https://github.com/jeffujioka/wd40.git
cd wd40
./install.sh
```

One run installs both kinds.

`scripts/` is symlinked into `~/.local/sbin` with the extension
**stripped**, so `scripts/smem-groups.sh` becomes the command
`smem-groups`. `shell/` is symlinked into `~/.zsh_aliases.d` with the
extension **kept**, so `shell/wd40-paths.sh` stays `wd40-paths.sh`: that
directory is read by a loader that globs `*.sh`, and a symlink named
`wd40-paths` would be passed over in silence. Same reasoning, opposite
conclusion.

`shell/` also has a narrower allowlist than `scripts/` — `.sh` and nothing
else, because there is no reading of `. foo.py` that works.

`~/.local/sbin` is not on `PATH` by default on macOS or Linux. If it's
missing, the installer adds a guarded block (like rustup/cargo append —
safe to re-source, never duplicated on re-run) to **every** startup file it
knows about that exists: `~/.bashrc` and `~/.zshrc`.

It writes to both because it used to guess, and the guess was wrong. It
picked one rc file from `$SHELL` — which is the **login** shell out of the
password database, not the shell you are typing in. Log in with bash and
work in zsh, as this repository's author does, and `$SHELL` says `bash`,
the installer wires up `~/.bashrc`, and your zsh — which never reads that
file — is left without half the install. Measured on that machine before
the change:

| shell | `~/.local/sbin` on `PATH` | `wd40` | `fp` |
|---|---|---|---|
| zsh (the one in use) | **no** | not found | defined |
| bash | yes | found | **not defined** |

Both halves reported success. So there is no longer a choice to get wrong:
each known rc file that exists is written to, and on a machine with both
shells both shells end up working.

A file that does not exist is not created to become a target — a `~/.zshrc`
on a machine with no zsh is litter — and for that case the installer prints
the exact block to paste instead.

### Which file counts as "already configured"

The check that stops a re-run growing your files is asked **per shell**,
against that shell's own startup chain:

| target | chain searched |
|---|---|
| `~/.bashrc` | `~/.bashrc`, `~/.bash_profile`, `~/.bash_aliases`, `~/.profile` |
| `~/.zshrc` | `~/.zshrc`, `~/.zprofile`, `~/.zsh_aliases` |

It has to be per shell, and that is the second half of the same bug. The
author's `~/.zsh_aliases` sources his aliases directory, and a single
machine-wide search finds it and concludes "already handled" — so bash,
which never reads `~/.zsh_aliases`, would never get the loader. A file one
shell reads is not evidence about another.

Each chain is searched for [every spelling of the
directory](#loading-the-shell-functions), so a line you wrote yourself as
`$HOME/.local/sbin` counts.

`~/.profile` is on bash's chain and not on zsh's, because zsh does not read
it outside sh-emulation.

The report names every file and what happened to it:

```
$ ./install.sh --dry-run
!  /tmp/wd40-demo2/home/.local/sbin is not in every shell's startup files.
!     bash: /tmp/wd40-demo2/home/.bashrc already mentions it
!     zsh: a PATH block would be added to /tmp/wd40-demo2/home/.zshrc
!  After a real run: restart your shell, or run: source /tmp/wd40-demo2/home/.zshrc

!  /tmp/wd40-demo2/home/.zsh_aliases.d is not sourced by every shell's startup files.
!     bash: a loader would be added to /tmp/wd40-demo2/home/.bashrc
!     zsh: /tmp/wd40-demo2/home/.zsh_aliases already mentions /tmp/wd40-demo2/home/.zsh_aliases.d - nothing to do
!  After a real run: restart your shell, or run: source /tmp/wd40-demo2/home/.bashrc
```

That is the author's own machine, and the two blocks go to opposite files.

### The closing line

The last line of each block is the only one that asks you to do something,
so it names the files that make the difference — the files this run
**wrote to**, and nothing else. Above, the PATH block went to `~/.zshrc`
and the loader went to `~/.bashrc`, so the two closing lines name different
files in the same run. `~/.bashrc` needed no PATH block and is not offered
for one: sourcing a file that did not change appears to work and changes
nothing.

When both files are written, both are named, each tagged with the shell
whose line it is — a real `~/.zshrc` read by bash is a page of syntax
errors, so the tag is what makes the alternative safe to pick from:

```
$ ./install.sh --dry-run
!  /tmp/wd40-demo3/home/.local/sbin is not in any shell's startup files.
!     bash: a PATH block would be added to /tmp/wd40-demo3/home/.bashrc
!     zsh: a PATH block would be added to /tmp/wd40-demo3/home/.zshrc
!  After a real run: restart your shell, or run: source /tmp/wd40-demo3/home/.bashrc (bash) or source /tmp/wd40-demo3/home/.zshrc (zsh)
```

If nothing was written because every chain already names the directory, the
line falls back to naming the files that already do the job — all of them,
not a guess at which one is yours. If nothing was written and nothing
already handles it, there is no closing line, and a run with nothing to do
prints nothing at all.

`After a real run:` is what a dry run says instead of `Restart your shell,`.
A dry run changed no file, so telling you to source one would be advice you
cannot act on; the line is still printed, because needing to source a file
afterwards is part of the answer to "what would this do?". It only changes
tense over files that *would* have been written — a file that already
handles it is described in the present tense in both modes, because it
really does hold what it needs to, today.

Parent-shell detection — `ps -o comm= -p $PPID`, because that *is* the
shell you are sitting in — is still what names a shell in the one sentence
that has to name one: `I found no startup file for zsh`, printed when there
is no rc file to write to at all. If the parent is not a shell (`make`, a
CI runner), or `ps` is missing or restricted, it falls back to `$SHELL` and
then to `your shell`. It is only ever used for a sentence, never to decide
what to write — and no longer to decide which file to suggest sourcing,
which is a question the run's own record of what it wrote answers exactly.

### Options

```
Usage: install.sh [options]

  -d, --dir DIR        directory for script symlinks (default: ~/.local/sbin)
  -s, --shell-dir DIR  directory for shell files (default: ~/.zsh_aliases.d)
      --rc FILE        startup file to configure; repeatable, replaces the
                       default set of ~/.bashrc and ~/.zshrc. A FILE this
                       installer does not recognise is searched only for
                       itself, not as part of any shell's startup chain
  -n, --dry-run        print what would happen; change nothing
  -f, --force          overwrite existing files that are not ours
  -u, --uninstall      remove this repository's symlinks
  -h, --help           show this help

Script directory precedence: --dir > $WD40_BIN_DIR > ~/.local/sbin
Shell directory precedence:  --shell-dir > $WD40_SHELL_DIR > ~/.zsh_aliases.d
Startup files: every one of ~/.bashrc and ~/.zshrc that exists, unless --rc
```

`--rc` replaces the default set rather than adding to it, so this run
touches `other-rc` and neither `~/.bashrc` nor `~/.zshrc`:

```
$ ./install.sh --dry-run --rc ~/other-rc
!  /tmp/wd40-demo2/home/.local/sbin is not in any shell's startup files.
!     a PATH block would be added to /tmp/wd40-demo2/home/other-rc
!  After a real run: restart your shell, or run: source /tmp/wd40-demo2/home/other-rc
```

A file it does not recognise is searched only for itself — no startup chain
is assumed for it, because inferring one from a path like
`~/.config/fish/config.fish` would be the same guessing that has just been
removed from the common path. A `--rc` naming a file with a known name,
such as `--rc ~/.bashrc`, is scoped exactly as that default target would
be. The file must already exist:

```
$ ./install.sh --rc ~/nope
Error: --rc file does not exist: /tmp/wd40-demo2/home/nope
```

A trailing slash on either directory is taken off before anything reads
it, so `--shell-dir ~/.zsh_aliases.d/` — which is what tab-completion
hands you for free — is the same request as without it. An empty value is
refused rather than treated as a directory:

```
$ ./install.sh --dir=
Error: --dir requires an argument
```

Existing files and symlinks that the installer does not own are skipped
with a warning rather than overwritten. `--uninstall` cleans both
directories under one rule: a link goes only when it resolves back into
this repository. An unrelated tool sharing a name is safe, and so is your
own `git.sh` sitting in your aliases directory.

Symlinks are absolute, so the installed commands keep working no matter
where the target directory sits relative to the clone.

### When a run cannot do what it was asked

An install that cannot create a destination fails, and says which one,
instead of printing links it did not make:

```
$ ./install.sh --dir /tmp/wd40-demo/ro/sbin --shell-dir /tmp/wd40-demo/aliases.d
mkdir: cannot create directory ‘/tmp/wd40-demo/ro/sbin’: Permission denied
!  cannot create the script directory /tmp/wd40-demo/ro/sbin
   link /tmp/wd40-demo/aliases.d/wd40-paths.sh -> /tmp/wd40-demo/wd40/shell/wd40-paths.sh
Error: not everything could be installed
```

The two kinds stay independent, so the half that could be installed still
was. The exit status is 1 either way.

An uninstall that cannot remove a link fails the same way, rather than
printing `remove` for something that is still there:

```
$ ./install.sh --dir /tmp/wd40-demo/locked --shell-dir /tmp/wd40-demo/al --uninstall
rm: cannot remove '/tmp/wd40-demo/locked/smem-groups': Permission denied
Error: could not remove /tmp/wd40-demo/locked/smem-groups
```

Running with no `HOME` at all — cron, a systemd unit, `env -i`, a Docker
layer — works when both directories are given explicitly, because nothing
else here needs a home directory. When they are not given, the default has
no `~` to expand, and that is what you are told:

```
$ env -u HOME ./install.sh
!  HOME is not set, so the default install directory has no ~ to expand.
Error: pass --dir DIR and --shell-dir DIR (or set WD40_BIN_DIR and WD40_SHELL_DIR)
```

Both directories are named in one breath, because supplying one and being
stopped again by the other is two round trips for one condition. Finding
your startup files is the one step that genuinely needs `HOME`, and it is
the one step that says so; everything it would have written is still
printed for you to paste. `--rc` names its files outright, so a run that
uses it needs no home directory for that step either.

### What is refused outright

A file name containing a newline. Discovery is `find | while read`, and
`read` splits on newlines, so such a name arrives as two half-paths and
neither of them is the file — which produced a dangling symlink on `PATH`
that the uninstaller then refused to take away again:

```
$ ./install.sh --dir /tmp/wd40-demo/sbin3 --shell-dir /tmp/wd40-demo/al3
!  a file name contains a newline:
/tmp/wd40-demo/withnewline/scripts/two
lines.sh
Error: rename it; a newline splits the path in two and neither half is the file
```

A symlink under `scripts/` or `shell/` is not installed, and — unlike
before — is reported rather than silently passed over:

```
$ ./install.sh --dir /tmp/wd40-demo/sbin2 --shell-dir /tmp/wd40-demo/al2
!  these are symlinks, and are not installed:
/tmp/wd40-demo/withlink/scripts/linked.sh
!  a symlink's target is not resolved, so it could name a file outside this repository
   link /tmp/wd40-demo/sbin2/real -> /tmp/wd40-demo/withlink/scripts/real.sh
```

Its target is not resolved, so it could name a file outside this
repository — which would be installed under a name claiming otherwise, and
then be un-removable for exactly that reason.

### Loading the shell functions

A symlink in `~/.zsh_aliases.d` does nothing on its own; something has to
source it. Unlike a missing `PATH` entry, the failure is silent — no
"command not found", just functions that were never defined.

So the installer looks for that directory in the startup chain of each
shell it is about to write to — bash's `~/.bashrc`, `~/.bash_profile`,
`~/.bash_aliases` and `~/.profile`; zsh's `~/.zshrc`, `~/.zprofile` and
`~/.zsh_aliases`. It looks for every way of writing it, not just the
expanded path — for a directory under your home directory, all four of
`/home/you/.zsh_aliases.d`, `~/.zsh_aliases.d`, `$HOME/.zsh_aliases.d` and
`${HOME}/.zsh_aliases.d` count. If it finds any of them, it changes that
shell's rc file not at all and tells you which file already handles it.

Both halves of that are there because being narrow in either one
produces the same wrong answer. The file list is wider than the rc file
because a setup where `.zshrc` sources `.zsh_aliases`, and it is *that*
file which names the directory, is common. The spelling list is wider
than the expanded path because that same `.zsh_aliases` is far more
likely to say `~/.zsh_aliases.d` than to write your home directory out in
full. Either way the answer would be "nothing loads it", and appending a
second loader to a configuration that already works would be worse than
doing nothing.

But the list is scoped to one shell rather than searched as a whole, and
that matters just as much in the other direction. A single machine-wide
search finds `~/.zsh_aliases`, answers "already handled" for the machine,
and leaves bash — which never reads that file — with a directory full of
symlinks nothing sources. One run can now write the loader to `~/.bashrc`
and leave `~/.zshrc` alone in the same breath, which is what the author's
machine actually needs.

What gets *written* is unaffected: the block the installer appends
contains the expanded path, because a tilde does not expand inside the
quotes it uses. It reads whatever you wrote and writes the one form that
cannot be misread.

If nothing on a shell's chain mentions it, a guarded block is appended to
that shell's rc file, the same way `PATH` is already handled. The block
defines a function that sources every `*.sh` in the directory, calls it,
and unsets it again. It is a function so that zsh's `NO_MATCH` can be
turned off across the glob — under zsh an unmatched glob aborts the
enclosing file, so an empty aliases directory would otherwise stop the rest
of your `.zshrc` from running. When no rc file exists at all, the block is
printed for you to paste. Run `./install.sh --dry-run` to read it; it is
not reproduced here because it embeds an absolute path and would go out of
date.

Either way, `fp` and its shorthands do not exist until you start a new
shell or `source` the file.

### Dry run

`--dry-run` writes nothing at all: no directory created, no symlink
created, no rc file created or appended to. It is how to see exactly what
would be written before agreeing to it.

Both generated blocks — the `PATH` one and the loader one — go to
**stdout**, because they are content you copy rather than diagnostics. So
this captures them:

```sh
./install.sh --dry-run > preview.txt
```

Warnings still go to stderr, and one of them is particular to a dry run: a
run that creates nothing runs no `mkdir`, so no `mkdir` fails, and the
preview would otherwise promise links into a directory it could never have
made.

```
$ ./install.sh --dry-run --dir /tmp/wd40-demo/ro/sbin --shell-dir /tmp/wd40-demo/aliases.d
Dry run. Nothing will be changed.
!  the script directory /tmp/wd40-demo/ro/sbin cannot be created: /tmp/wd40-demo/ro is not writable
   link /tmp/wd40-demo/ro/sbin/smem-groups -> /tmp/wd40-demo/wd40/scripts/smem-groups.sh
   link /tmp/wd40-demo/ro/sbin/wd40 -> /tmp/wd40-demo/wd40/scripts/wd40.sh
   link /tmp/wd40-demo/aliases.d/wd40-paths.sh -> /tmp/wd40-demo/wd40/shell/wd40-paths.sh
```

That is advice and not a verdict — a full disk, an immutable bit or a
read-only mount are all invisible from here — so the exit status is what
it would have been anyway.

## Windows

No installer yet. Invoke scripts directly. The POSIX installer already
skips `.ps1`, `.bat`, and `.cmd` files, so Windows scripts can be added
here before a Windows installer exists. `shell/` has no Windows
counterpart to make room for.

## Tests

```sh
./test/smoke.sh
```

Plain bash, no framework. Runs unchanged on macOS and Linux. The summary
reads `N passed, N failed, N skipped`, and the skip count is the point:
the assertions about `shell/wd40-paths.sh` and about the generated loader
run twice, once under bash and once under zsh, and a machine without zsh
skips them rather than quietly reporting a shorter run as a full one.

One section runs no commands at all. Every file here that claims bash 3.2
— `install.sh`, both scripts, `shell/wd40-paths.sh` and the suite itself —
makes a claim the suite cannot test by running anything, because it
resolves `bash` through `PATH`, which is bash 5 here and usually a
Homebrew build on macOS: the one version the claim is about is the one
version that never runs. It is guarded statically instead. Those files are
scanned for the constructs their headers forbid, and the interpreter that
did run is reported rather than assumed.

## Compatibility

`install.sh` and the scripts target bash 3.2 and BSD userland, because
macOS still ships bash 3.2 as `/bin/bash`.

`shell/wd40-paths.sh` targets bash 3.2 and zsh and must behave identically
in both. It is sourced into a live interactive shell, so it sets no shell
option, leaves no variable behind, and every name in it is local and
prefixed.

## License

MIT
