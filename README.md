# td

Task manager for ICS files synced by vdirsyncer.

> Note: This tool is new but used by the author every day.

A drop-in replacement for [todoman](https://github.com/pimutils/todoman). Fuller featured, no interactive prompts, just straightforward CLI flags. Works directly with your CalDAV-synced `.ics` files — no database, no lock-in.

## Install

```
nimble install td
```

Requires [vdirsyncer](https://github.com/pimutils/vdirsyncer) (or any tool that syncs ICS files to a local directory).

## Quick Start

```sh
td                          # list actionable tasks
td add "Buy milk"           # add a task
td add -d tomorrow -p high "Ship feature"
td done 3                   # mark task 3 complete
td 3                        # show details for task 3
```

## Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `list`  | `ls` | List tasks (default when you just type `td`) |
| `add`   | `new` | Add a new task |
| `edit`  | `mod`, `modify` | Edit an existing task |
| `done`  | `do` | Mark task(s) as completed |
| `cancel` | | Mark task(s) as cancelled |
| `find`  | `search` | Full text search across all tasks |
| `delete` | `del`, `rm`, `remove` | Delete task(s) (moves to trash) |
| `show`  | `view` | Show full task details |

A bare number is a shortcut for show: `td 7` is the same as `td show 7`.

## Options

**Add and edit:**

```
-d, --due DATE        today, tomorrow, monday, +3d, +1w, -2d, 2026-04-01
-p, --priority P      high, medium, low, none (or 1, 5, 9, 0)
-n, --note TEXT       description / notes
-t, --tag TAG         category (repeatable)
-a, --alarm MIN       alarm N minutes before due (repeatable)
-c, --calendar CAL    calendar name
```

**List and filter:**

```
-a, --all             show all tasks including completed
-d, --due DATE        filter by due date
-p, --priority P      filter by minimum priority
-c, --calendar CAL    filter by calendar
-t, --tag TAG         filter by category
-s, --sort FIELD      sort by: due/d, prio/p, created/c
    --done            show completed/cancelled tasks
```

## Defaults

`td` with no arguments shows tasks that are:

- Active (not completed or cancelled)
- Due today, overdue, or with no due date
- Medium priority or higher (low-priority tasks are hidden)

Use `-a` to see everything, or `--done` to see completed tasks.

## Editing and Clearing Fields

Edit only changes what you specify:

```sh
td edit 3 -d tomorrow       # change due date
td edit 3 "New summary"     # change summary
td edit 3 -d ""             # clear due date
td edit 3 -n ""             # clear notes
td edit 3 -t ""             # clear all tags
```

## Configuration

Create a `.env` file (see `.env.example`):

```
TD_PATH=~/.local/var/lib/vdirsyncer/calendars
TD_CALENDAR=default
```

`TD_PATH` defaults to `~/.local/var/lib/vdirsyncer/calendars`. If you have multiple calendars, `TD_CALENDAR` sets which one gets new tasks. Without it, td auto-detects.

## How It Works

td reads and writes standard RFC 5545 VTODO entries in `.ics` files. It assigns stable short numeric IDs (stored in `~/.local/share/td/idmap`) so you don't have to deal with UUIDs. Deleted tasks are moved to a `.trash` folder under your calendar path rather than permanently removed.

The ICS parser is round-trip safe — it preserves timezone data, unknown properties, and anything else your CalDAV server or other clients put in the files.

## Exit Codes

- `0` — success (for `list` and `find`: results found)
- `1` — error, or no results

## License

MIT
