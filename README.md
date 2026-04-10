# td

Task manager for ICS files synced by vdirsyncer. A drop-in replacement for [todoman](https://github.com/pimutils/todoman) — fuller featured, no interactive prompts, just CLI flags. Works directly with your CalDAV-synced `.ics` files, no database.

Note: new, but used by the author every day.

## Install

```
nimble install td
```

Requires [vdirsyncer](https://github.com/pimutils/vdirsyncer) (or any tool that syncs ICS files to a local directory).

## Quick Start

```sh
td                          # list actionable tasks
td add "Buy milk"
td add -d tomorrow -p high "Ship feature"
td done 3                   # mark task 3 complete
td 3                        # show details for task 3
```

## Commands

`list` (or just `td`) — list tasks. `add` / `edit` / `done` / `cancel` / `delete` / `show` / `find` do what you'd expect. Most have short aliases (`ls`, `new`, `mod`, `do`, `rm`, etc.). A bare number is shorthand for show: `td 7` = `td show 7`.

## Options

Adding and editing:

```
-d, --due DATE        today, tomorrow, monday, +3d, +1w, -2d, 2026-04-01
-p, --priority P      high, medium, low, none (or 1, 5, 9, 0)
-n, --note TEXT       description / notes
-t, --tag TAG         category (repeatable)
-a, --alarm MIN       alarm N minutes before due (repeatable)
-c, --calendar CAL    calendar name
```

Listing and filtering:

```
-a, --all             show all tasks including completed
-d, --due DATE        filter by due date
-p, --priority P      filter by minimum priority
-c, --calendar CAL    filter by calendar
-t, --tag TAG         filter by category
-s, --sort FIELD      sort by: due/d, prio/p, created/c
    --done            show completed/cancelled tasks
```

By default, `td` shows active tasks that are due today, overdue, or have no due date, at medium priority or higher. Use `-a` to see everything.

## Editing and Clearing Fields

Edit only changes what you specify:

```sh
td edit 3 -d tomorrow       # change due date
td edit 3 "New summary"     # change summary
td edit 3 -d ""             # clear due date
td edit 3 -n ""             # clear notes
```

## Configuration

Create a `.env` file (see `.env.example`):

```
TD_PATH=~/.local/var/lib/vdirsyncer/calendars
TD_CALENDAR=default
```

`TD_PATH` defaults to `~/.local/var/lib/vdirsyncer/calendars`. `TD_CALENDAR` sets which calendar gets new tasks.

## Internals

td reads and writes standard RFC 5545 VTODO entries in `.ics` files. Short numeric IDs are mapped in `~/.local/share/td/idmap` so you don't have to deal with UUIDs. Deleted tasks go to a `.trash` folder under your calendar path.

The ICS parser is round-trip safe — preserves timezone data, unknown properties, and anything else your CalDAV server puts in there.

## License

MIT
