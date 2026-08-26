#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "rich",
#     "InquirerPy",
# ]
# ///
#
# whatsapp-diskusage.py - show which WhatsApp chats consume the most disk space.
#
# wd40: whatsapp-diskusage - show which WhatsApp chats consume the most disk space
#
# WhatsApp Mac stores media in per-chat directories named by JID (Jabber ID)
# under ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/.
# This script sums the size of each directory and resolves JIDs to human-readable
# names via the local ChatStorage.sqlite database.
#
# Requires: macOS (WhatsApp Mac), uv (https://docs.astral.sh/uv/), Python 3.10+
#
# Usage:
#   whatsapp-diskusage                     # top 10 chats by size
#   whatsapp-diskusage -n 20               # top 20
#   whatsapp-diskusage --video             # only video files (mp4)
#   whatsapp-diskusage --audio             # only audio files (opus)
#   whatsapp-diskusage --photos            # only photos (jpg, webp)
#   whatsapp-diskusage -t mp4,opus         # custom extension filter
#   whatsapp-diskusage --jids              # output JIDs only (for scripting)
#   whatsapp-diskusage --paths             # output paths only (for piping to rm)
#   whatsapp-diskusage -i                  # interactive: select chats and delete
#
#   whatsapp-diskusage search "maria"      # search chats by name (substring)
#   whatsapp-diskusage search "maria" --jids
#
#   whatsapp-diskusage files <JID>         # list files in a chat, largest first
#   whatsapp-diskusage files <JID> --video # only video files
#   whatsapp-diskusage files <JID> -i      # interactive: preview/delete files
#
# Exit codes: 0 = success, 1 = error (missing dir, wrong platform, etc.)

import argparse
import os
import platform
import shutil
import sqlite3
import subprocess
import sys

from rich.console import Console
from rich.table import Table
from rich.text import Text

BASE = os.path.expanduser(
    "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
)
MEDIA_DIR = os.path.join(BASE, "Message", "Media")
DB_PATH = os.path.join(BASE, "ChatStorage.sqlite")

TYPE_PRESETS = {
    "video": {"mp4"},
    "audio": {"opus"},
    "photos": {"jpg", "webp"},
    "images": {"jpg", "webp"},
    "docs": {"pdf", "docx"},
}


def dir_size(path, extensions=None):
    total = 0
    for dirpath, _, filenames in os.walk(path):
        for f in filenames:
            if extensions:
                ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
                if ext not in extensions:
                    continue
            fp = os.path.join(dirpath, f)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def human_size(nbytes):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(nbytes) < 1024:
            if unit in ("B", "KB"):
                return f"{nbytes:.0f} {unit}"
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} PB"


def resolve_names(jids):
    names = {}
    if not os.path.exists(DB_PATH):
        return names
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    cur = conn.cursor()
    placeholders = ",".join("?" * len(jids))
    cur.execute(
        f"SELECT ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION "
        f"WHERE ZCONTACTJID IN ({placeholders})",
        jids,
    )
    for jid, name in cur.fetchall():
        if name:
            names[jid] = name
    missing = [j for j in jids if j not in names]
    if missing:
        placeholders = ",".join("?" * len(missing))
        cur.execute(
            f"SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME "
            f"WHERE ZJID IN ({placeholders})",
            missing,
        )
        for jid, name in cur.fetchall():
            if name:
                names[jid] = name
    conn.close()
    return names


def size_color(ratio):
    r = int(255 * ratio)
    g = int(255 * (1 - ratio))
    return f"#{r:02x}{g:02x}00"


def make_bar(ratio, width):
    filled = int(ratio * width)
    empty = width - filled
    bar = "█" * filled + "░" * empty
    return bar


def print_table(entries, console, extensions=None, show_jid=False):
    term_width = shutil.get_terminal_size().columns
    bar_width = max(int(term_width * 0.20), 8)
    max_size = entries[0]["size"] if entries else 1

    subtitle = f"[dim]filter: {', '.join(sorted(extensions))}[/dim]" if extensions else None
    table = Table(
        title="WhatsApp Media Disk Usage",
        title_style="bold",
        caption=subtitle,
        show_lines=True,
    )
    table.add_column("#", justify="right", style="dim", no_wrap=True, min_width=3)
    table.add_column("Size", justify="right", no_wrap=True, min_width=9)
    table.add_column("Usage", no_wrap=True, width=bar_width)
    table.add_column("Chat", overflow="ellipsis", no_wrap=True, ratio=1)
    if show_jid:
        table.add_column("JID", style="dim", overflow="ellipsis", no_wrap=True, ratio=1)

    for i, e in enumerate(entries, 1):
        ratio = e["size"] / max_size if max_size > 0 else 0
        color = size_color(ratio)

        size_text = Text(e["size_str"], style=color)
        bar_text = Text(make_bar(ratio, bar_width), style=color)
        chat_text = Text(e["chat"])

        row = [str(i), size_text, bar_text, chat_text]
        if show_jid:
            row.append(Text(e["jid"], style="dim"))
        table.add_row(*row)

    console.print(table)


def print_files_table(files, console):
    term_width = shutil.get_terminal_size().columns
    bar_width = max(int(term_width * 0.15), 6)
    max_size = files[0]["size"] if files else 1

    table = Table(
        title="Files",
        title_style="bold",
        show_lines=True,
    )
    table.add_column("#", justify="right", style="dim", no_wrap=True, min_width=3)
    table.add_column("Size", justify="right", no_wrap=True, min_width=9)
    table.add_column("Usage", no_wrap=True, width=bar_width)
    table.add_column("File", overflow="ellipsis", no_wrap=True, ratio=1)

    for i, f in enumerate(files, 1):
        ratio = f["size"] / max_size if max_size > 0 else 0
        color = size_color(ratio)

        size_text = Text(f["size_str"], style=color)
        bar_text = Text(make_bar(ratio, bar_width), style=color)
        name_text = Text(f["name"])

        table.add_row(str(i), size_text, bar_text, name_text)

    console.print(table)


def interactive_delete(entries, force, console):
    from InquirerPy import inquirer

    choices = [
        {"name": f"{e['size_str']:>10}  {e['chat']}", "value": i}
        for i, e in enumerate(entries)
    ]

    selected = inquirer.checkbox(
        message="Select chats to delete media (ctrl+a=all, ctrl+r=toggle, ctrl+d=none):",
        choices=choices,
        keybindings={"toggle-all-false": [{"key": "c-d"}]},
    ).execute()

    if not selected:
        console.print("[dim]Nothing selected.[/dim]")
        return

    to_delete = [entries[i] for i in selected]
    total_bytes = sum(e["size"] for e in to_delete)

    console.print()
    for e in to_delete:
        console.print(f"  [red]✗[/red] {e['chat']} ({e['size_str']})")
    console.print()
    console.print(f"  [bold]Total: {human_size(total_bytes)}[/bold]")
    console.print()

    if not force:
        confirm = inquirer.confirm(
            message=f"Delete {human_size(total_bytes)}?",
            default=False,
        ).execute()
        if not confirm:
            console.print("[dim]Cancelled.[/dim]")
            return

    for e in to_delete:
        shutil.rmtree(e["path"], ignore_errors=True)
        console.print(f"  [green]✓[/green] Deleted: {e['chat']}")

    console.print(f"\n  [bold green]{human_size(total_bytes)} freed.[/bold green]")


def get_extensions(args):
    extensions = None
    if args.type_filter:
        extensions = {e.strip().lower().lstrip(".") for e in args.type_filter.split(",")}
    else:
        for preset in TYPE_PRESETS:
            if getattr(args, preset, False):
                extensions = extensions or set()
                extensions |= TYPE_PRESETS[preset]
    return extensions


def add_filter_args(parser):
    parser.add_argument("-t", "--type", dest="type_filter", help="filter by extensions (comma-separated, e.g. mp4,jpg)")
    parser.add_argument("--video", action="store_true", help="filter: video files (mp4)")
    parser.add_argument("--audio", action="store_true", help="filter: audio files (opus)")
    parser.add_argument("--photos", action="store_true", help="filter: photos (jpg, webp)")
    parser.add_argument("--images", action="store_true", help="filter: images (jpg, webp)")
    parser.add_argument("--docs", action="store_true", help="filter: documents (pdf, docx)")


def scan_chats(extensions=None):
    entries = []
    for name in os.listdir(MEDIA_DIR):
        path = os.path.join(MEDIA_DIR, name)
        if not os.path.isdir(path):
            continue
        size = dir_size(path, extensions)
        entries.append({"jid": name, "size": size, "path": path})
    entries.sort(key=lambda e: e["size"], reverse=True)
    if extensions:
        entries = [e for e in entries if e["size"] > 0]
    return entries


def enrich_entries(entries):
    jids = [e["jid"] for e in entries]
    names = resolve_names(jids)
    for e in entries:
        jid = e["jid"]
        if jid in names:
            e["chat"] = names[jid]
        elif jid.endswith("@lid.status"):
            e["chat"] = f"Status ({jid.split('@')[0]})"
        else:
            e["chat"] = jid
        e["size_str"] = human_size(e["size"])


def resolve_jid(jid_query):
    matches = []
    for name in os.listdir(MEDIA_DIR):
        path = os.path.join(MEDIA_DIR, name)
        if not os.path.isdir(path):
            continue
        if name == jid_query:
            return name, path
        if jid_query in name:
            matches.append((name, path))
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        print(f"Ambiguous JID '{jid_query}', matches:", file=sys.stderr)
        for m, _ in matches:
            print(f"  {m}", file=sys.stderr)
        sys.exit(1)
    return None, None


def cmd_top(args):
    if not os.path.isdir(MEDIA_DIR):
        print(f"Media directory not found: {MEDIA_DIR}", file=sys.stderr)
        sys.exit(1)

    console = Console(stderr=True) if (args.paths or args.jids) else Console()
    extensions = get_extensions(args)

    entries = scan_chats(extensions)
    entries = entries[: args.n]

    if not entries:
        print("No media directories found.", file=sys.stderr)
        sys.exit(0)

    enrich_entries(entries)

    if args.paths:
        for e in entries:
            print(e["path"])
    elif args.jids:
        for e in entries:
            print(e["jid"])
    elif args.interactive:
        print_table(entries, console, extensions, show_jid=True)
        console.print()
        interactive_delete(entries, args.force, console)
    else:
        print_table(entries, console, extensions, show_jid=True)


def fuzzy_match(pattern, text):
    if pattern == pattern.lower():
        text = text.lower()
    pi = 0
    for char in text:
        if pi < len(pattern) and char == pattern[pi]:
            pi += 1
    return pi == len(pattern)


def cmd_search(args):
    if not os.path.isdir(MEDIA_DIR):
        print(f"Media directory not found: {MEDIA_DIR}", file=sys.stderr)
        sys.exit(1)

    console = Console()
    extensions = get_extensions(args)
    entries = scan_chats(extensions)
    enrich_entries(entries)

    tokens = args.query.split()
    results = [
        e for e in entries
        if all(fuzzy_match(t, e["chat"]) or fuzzy_match(t, e["jid"]) for t in tokens)
    ]

    if not results:
        console.print(f"[dim]No match for '{args.query}'[/dim]")
        sys.exit(0)

    if args.jids:
        for e in results:
            print(e["jid"])
    else:
        print_table(results, console, extensions, show_jid=True)


def cmd_files(args):
    if not os.path.isdir(MEDIA_DIR):
        print(f"Media directory not found: {MEDIA_DIR}", file=sys.stderr)
        sys.exit(1)

    jid, path = resolve_jid(args.jid)
    if not jid:
        print(f"JID not found: '{args.jid}'", file=sys.stderr)
        sys.exit(1)

    console = Console()
    extensions = get_extensions(args)

    files = []
    for dirpath, _, filenames in os.walk(path):
        for f in filenames:
            if extensions:
                ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
                if ext not in extensions:
                    continue
            fp = os.path.join(dirpath, f)
            try:
                size = os.path.getsize(fp)
            except OSError:
                continue
            files.append({"name": f, "size": size, "path": fp})

    files.sort(key=lambda f: f["size"], reverse=True)
    files = files[: args.n]

    if not files:
        console.print("[dim]No files found.[/dim]")
        sys.exit(0)

    for f in files:
        f["size_str"] = human_size(f["size"])

    names = resolve_names([jid])
    chat_name = names.get(jid, jid)
    console.print(f"\n[bold]{chat_name}[/bold] [dim]({jid})[/dim]\n")

    if args.paths:
        for f in files:
            print(f["path"])
    elif args.interactive:
        print_files_table(files, console)
        console.print()
        interactive_files(files, args.force, console)
    else:
        print_files_table(files, console)


def open_file(path):
    opener = "open" if platform.system() == "Darwin" else "xdg-open"
    subprocess.Popen([opener, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def interactive_files(files, force, console):
    from InquirerPy import inquirer

    choices = [
        {"name": f"{f['size_str']:>10}  {f['name']}", "value": i}
        for i, f in enumerate(files)
    ]

    selected = inquirer.checkbox(
        message="Select files (ctrl+a=all, ctrl+r=toggle, ctrl+d=none):",
        choices=choices,
        keybindings={"toggle-all-false": [{"key": "c-d"}]},
    ).execute()

    if not selected:
        console.print("[dim]Nothing selected.[/dim]")
        return

    selected_files = [files[i] for i in selected]
    total_selected = sum(f["size"] for f in selected_files)

    while True:
        console.print(f"\n  [bold]{len(selected_files)} file(s) selected ({human_size(total_selected)})[/bold]\n")

        action = inquirer.select(
            message="Action:",
            choices=[
                {"name": "Preview (open files)", "value": "preview"},
                {"name": "Delete", "value": "delete"},
                {"name": "Quit", "value": "quit"},
            ],
        ).execute()

        if action is None or action == "quit":
            console.print("[dim]Done.[/dim]")
            return

        if action == "preview":
            for f in selected_files:
                open_file(f["path"])
            console.print(f"  [green]✓[/green] Opened {len(selected_files)} file(s)")

        elif action == "delete":
            console.print()
            for f in selected_files:
                console.print(f"  [red]✗[/red] {f['name']} ({f['size_str']})")
            console.print(f"\n  [bold]Total: {human_size(total_selected)}[/bold]\n")

            if not force:
                confirm = inquirer.confirm(
                    message=f"Delete {human_size(total_selected)}?",
                    default=False,
                ).execute()
                if not confirm:
                    console.print("[dim]Cancelled.[/dim]")
                    continue

            for f in selected_files:
                os.remove(f["path"])
                console.print(f"  [green]✓[/green] Deleted: {f['name']}")

            console.print(f"\n  [bold green]{human_size(total_selected)} freed.[/bold green]")
            return


def main():
    if platform.system() != "Darwin":
        print("Error: whatsapp-diskusage requires macOS (WhatsApp Mac media paths).", file=sys.stderr)
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="WhatsApp media disk usage per chat",
    )
    subparsers = parser.add_subparsers(dest="command")

    parser.add_argument("-n", type=int, default=10, help="number of top consumers (default: 10)")
    parser.add_argument("--paths", action="store_true", help="output only paths (for piping to rm)")
    parser.add_argument("--jids", action="store_true", help="output only JIDs")
    parser.add_argument("-i", "--interactive", action="store_true", help="interactive mode: select and delete")
    parser.add_argument("--force", action="store_true", help="skip confirmation in interactive mode")
    add_filter_args(parser)

    search_parser = subparsers.add_parser("search", help="search chats by name")
    search_parser.add_argument("query", help="search term (case-insensitive substring)")
    search_parser.add_argument("--jids", action="store_true", help="output only JIDs")
    add_filter_args(search_parser)

    files_parser = subparsers.add_parser("files", help="list files in a specific chat")
    files_parser.add_argument("jid", help="JID (or partial match) of the chat")
    files_parser.add_argument("-n", type=int, default=20, help="number of files to show (default: 20)")
    files_parser.add_argument("--paths", action="store_true", help="output only file paths")
    files_parser.add_argument("-i", "--interactive", action="store_true", help="interactive mode: select, preview, delete")
    files_parser.add_argument("--force", action="store_true", help="skip confirmation in interactive mode")
    add_filter_args(files_parser)

    args = parser.parse_args()

    if args.command == "search":
        cmd_search(args)
    elif args.command == "files":
        cmd_files(args)
    else:
        cmd_top(args)


if __name__ == "__main__":
    main()
