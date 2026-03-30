## Comprehensive test suite for td

import std/[os, osproc, strutils, sequtils, times, unittest, tempfiles, strtabs]

const TdBin = currentSourcePath().parentDir / "../td"

# --- Test Helpers ---

type TestEnv = object
  dir: string
  calDir: string
  dataDir: string
  trashDir: string

proc setup(): TestEnv =
  let dir = createTempDir("td_test_", "")
  let calDir = dir / "calendars" / "default"
  let dataDir = dir / "data"
  createDir(calDir)
  createDir(dataDir)
  TestEnv(dir: dir, calDir: calDir, dataDir: dataDir, trashDir: dir / "calendars" / ".trash")

proc teardown(env: TestEnv) =
  removeDir(env.dir)

proc run(env: TestEnv, args: varargs[string]): tuple[output: string, exitCode: int] =
  let cmdArgs = @args
  let cmd = TdBin & " " & cmdArgs.mapIt(quoteShell(it)).join(" ")
  let (output, exitCode) = execCmdEx(cmd, env = {
    "TD_PATH": env.dir / "calendars",
    "TD_CALENDAR": "default",
    "XDG_DATA_HOME": env.dataDir,
    "NO_COLOR": "1",
    "HOME": env.dir,
  }.newStringTable)
  (output.strip, exitCode)

proc addTask(env: TestEnv, summary: string, extraArgs: varargs[string]): int =
  let args = @["add", summary] & @extraArgs
  let (output, code) = env.run(args)
  doAssert code == 0, "add failed: " & output
  parseInt(output.strip)

proc icsFiles(env: TestEnv): seq[string] =
  result = @[]
  for f in walkFiles(env.calDir / "*.ics"):
    result.add(f)

proc readIcs(env: TestEnv, id: int): string =
  let (output, code) = env.run("show", $id)
  doAssert code == 0
  output

# --- Tests ---

suite "version and help":
  test "version flag":
    let (output, code) = execCmdEx(TdBin & " --version", env = {"NO_COLOR": "1"}.newStringTable)
    check code == 0
    check output.strip.startsWith("td ")
    check output.strip.contains("0.1.0")

  test "short version flag":
    let (output, code) = execCmdEx(TdBin & " -v", env = {"NO_COLOR": "1"}.newStringTable)
    check code == 0
    check output.strip.startsWith("td ")

  test "help flag":
    let (output, code) = execCmdEx(TdBin & " --help", env = {"NO_COLOR": "1"}.newStringTable)
    check code == 0
    check "Usage:" in output
    check "Commands:" in output

  test "short help flag":
    let (output, code) = execCmdEx(TdBin & " -h", env = {"NO_COLOR": "1"}.newStringTable)
    check code == 0
    check "Usage:" in output

suite "add command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "basic add":
    let id = env.addTask("Buy groceries")
    check id == 1
    check env.icsFiles().len == 1

  test "add prints id":
    let (output, code) = env.run("add", "Task one")
    check code == 0
    check output.strip == "1"

  test "sequential ids":
    let id1 = env.addTask("First")
    let id2 = env.addTask("Second")
    let id3 = env.addTask("Third")
    check id1 == 1
    check id2 == 2
    check id3 == 3

  test "add with due date":
    let id = env.addTask("Due task", "-d", "tomorrow")
    let (output, _) = env.run("show", $id)
    check "tomorrow" in output

  test "add with absolute due date":
    let id = env.addTask("Abs due", "-d", "2026-12-25")
    let (output, _) = env.run("show", $id)
    check "2026-12-25" in output

  test "add with compact date":
    let id = env.addTask("Compact due", "-d", "20261225")
    let (output, _) = env.run("show", $id)
    check "2026-12-25" in output

  test "add with priority":
    let id = env.addTask("Urgent", "-p", "high")
    let (output, _) = env.run("show", $id)
    check "high" in output

  test "add with numeric priority":
    let id = env.addTask("Prio 5", "-p", "5")
    let (output, _) = env.run("show", $id)
    check "medium" in output

  test "add with description":
    let id = env.addTask("Described", "-n", "This is a note")
    let (output, _) = env.run("show", $id)
    check "This is a note" in output

  test "add with tag":
    let id = env.addTask("Tagged", "-t", "work")
    let (output, _) = env.run("show", $id)
    check "work" in output

  test "add with multiple tags":
    let id = env.addTask("Multi-tag", "-t", "work", "-t", "urgent")
    let (output, _) = env.run("show", $id)
    check "work" in output
    check "urgent" in output

  test "add with attachment":
    let id = env.addTask("With file", "-f", "http://example.com/doc.pdf")
    let (output, _) = env.run("show", $id)
    check "example.com/doc.pdf" in output

  test "add with alarm":
    let id = env.addTask("Alarmed", "-a", "15")
    let (output, _) = env.run("show", $id)
    check "15m before" in output

  test "add with multiple alarms":
    let id = env.addTask("Multi alarm", "-a", "5", "-a", "30")
    let (output, _) = env.run("show", $id)
    check "5m before" in output
    check "30m before" in output

  test "add with recurrence daily":
    let id = env.addTask("Daily", "--every", "daily", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every day" in output

  test "add with recurrence weekly":
    let id = env.addTask("Weekly", "--every", "weekly", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every week" in output

  test "add with recurrence interval":
    let id = env.addTask("Bi-weekly", "--every", "2w", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every 2 weeks" in output

  test "add with weekday recurrence":
    let id = env.addTask("MWF", "--every", "weekly", "--on", "mo,we,fr", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "MO" in output
    check "WE" in output
    check "FR" in output

  test "add with combined options":
    let id = env.addTask("Full task", "-d", "tomorrow", "-p", "high", "-n", "Details here", "-t", "work")
    let (output, _) = env.run("show", $id)
    check "tomorrow" in output
    check "high" in output
    check "Details here" in output
    check "work" in output

  test "add no summary fails":
    let (_, code) = env.run("add")
    check code != 0

  test "add alias new":
    let (output, code) = env.run("new", "Via alias")
    check code == 0
    check output.strip == "1"

  test "add alias create":
    let (output, code) = env.run("create", "Via create")
    check code == 0
    check output.strip == "1"

suite "show command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "show basic":
    let id = env.addTask("Show me")
    let (output, code) = env.run("show", $id)
    check code == 0
    check "Show me" in output
    check "NEEDS-ACTION" in output
    check "default" in output

  test "show nonexistent":
    let (_, code) = env.run("show", "999")
    check code != 0

  test "show invalid id":
    let (_, code) = env.run("show", "abc")
    check code != 0

  test "bare number shortcut":
    let id = env.addTask("Shortcut task")
    let (output, code) = env.run($id)
    check code == 0
    check "Shortcut task" in output

  test "show alias view":
    let id = env.addTask("Viewable")
    let (output, code) = env.run("view", $id)
    check code == 0
    check "Viewable" in output

suite "list command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "empty list exits 1":
    let (output, code) = env.run("list")
    check code == 1
    check output == ""

  test "list shows tasks":
    discard env.addTask("Task A", "-d", "today")
    discard env.addTask("Task B", "-d", "today")
    let (output, code) = env.run("list")
    check code == 0
    check "Task A" in output
    check "Task B" in output

  test "default list hides future tasks":
    discard env.addTask("Today task", "-d", "today")
    discard env.addTask("Future task", "-d", "+30d")
    let (output, _) = env.run("list")
    check "Today task" in output
    check "Future task" notin output

  test "list -a shows all":
    discard env.addTask("Today task", "-d", "today")
    discard env.addTask("Future task", "-d", "+30d")
    let (output, code) = env.run("list", "-a")
    check code == 0
    check "Today task" in output
    check "Future task" in output

  test "list --all shows all":
    discard env.addTask("Nearby", "-d", "today")
    discard env.addTask("Far away", "-d", "+60d")
    let (output, _) = env.run("list", "--all")
    check "Nearby" in output
    check "Far away" in output

  test "list hides low priority by default":
    discard env.addTask("High prio", "-p", "high", "-d", "today")
    discard env.addTask("Low prio", "-p", "low", "-d", "today")
    let (output, _) = env.run("list")
    check "High prio" in output
    check "Low prio" notin output

  test "list -p 9 shows low priority":
    discard env.addTask("High prio", "-p", "high", "-d", "today")
    discard env.addTask("Low prio", "-p", "low", "-d", "today")
    let (output, _) = env.run("list", "-a", "-p", "9")
    check "High prio" in output
    check "Low prio" in output

  test "list shows no-due-date tasks":
    discard env.addTask("No due")
    let (output, code) = env.run("list")
    check code == 0
    check "No due" in output

  test "list shows overdue":
    discard env.addTask("Overdue", "-d", "-1d")
    let (output, _) = env.run("list")
    check "Overdue" in output

  test "list filter by tag":
    discard env.addTask("Work task", "-t", "work", "-d", "today")
    discard env.addTask("Personal task", "-t", "personal", "-d", "today")
    let (output, _) = env.run("list", "-t", "work")
    check "Work task" in output
    check "Personal task" notin output

  test "list sort by due":
    discard env.addTask("Later", "-d", "+2d")
    discard env.addTask("Sooner", "-d", "today")
    let (output, _) = env.run("list", "-a", "-s", "due")
    let lines = output.splitLines.filterIt(it.strip.len > 0)
    check lines.len == 2
    # Sooner should be first (earlier due)
    check "Sooner" in lines[0]
    check "Later" in lines[1]

  test "list sort by priority":
    discard env.addTask("Low", "-p", "medium")
    discard env.addTask("High", "-p", "high")
    let (output, _) = env.run("list", "-a", "-s", "prio")
    let lines = output.splitLines.filterIt(it.strip.len > 0)
    check lines.len == 2
    check "High" in lines[0]
    check "Low" in lines[1]

  test "list --done shows completed":
    let id = env.addTask("Finish this", "-d", "today")
    discard env.run("done", $id)
    let (output, code) = env.run("list", "--done")
    check code == 0
    check "Finish this" in output

  test "list alias ls":
    discard env.addTask("Listed", "-d", "today")
    let (output, code) = env.run("ls")
    check code == 0
    check "Listed" in output

  test "bare td is list":
    discard env.addTask("Default list", "-d", "today")
    let (output, code) = env.run()
    check code == 0
    check "Default list" in output

suite "edit command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "edit summary":
    let id = env.addTask("Old name")
    discard env.run("edit", $id, "New name")
    let (output, _) = env.run("show", $id)
    check "New name" in output
    check "Old name" notin output

  test "edit due date":
    let id = env.addTask("Task", "-d", "today")
    discard env.run("edit", $id, "-d", "tomorrow")
    let (output, _) = env.run("show", $id)
    check "tomorrow" in output

  test "edit clear due":
    let id = env.addTask("Task", "-d", "tomorrow")
    discard env.run("edit", $id, "-d", "")
    let (output, _) = env.run("show", $id)
    check "Due:" notin output

  test "edit priority":
    let id = env.addTask("Task")
    discard env.run("edit", $id, "-p", "high")
    let (output, _) = env.run("show", $id)
    check "high" in output

  test "edit clear priority":
    let id = env.addTask("Task", "-p", "high")
    discard env.run("edit", $id, "-p", "none")
    let (output, _) = env.run("show", $id)
    check "Priority:" notin output

  test "edit description":
    let id = env.addTask("Task")
    discard env.run("edit", $id, "-n", "New description")
    let (output, _) = env.run("show", $id)
    check "New description" in output

  test "edit clear description":
    let id = env.addTask("Task", "-n", "Old desc")
    discard env.run("edit", $id, "-n", "")
    let (output, _) = env.run("show", $id)
    check "Old desc" notin output
    check "Desc:" notin output

  test "edit tags":
    let id = env.addTask("Task", "-t", "old")
    discard env.run("edit", $id, "-t", "new")
    let (output, _) = env.run("show", $id)
    check "new" in output
    check "old" notin output

  test "edit clear tags":
    let id = env.addTask("Task", "-t", "work")
    discard env.run("edit", $id, "-t", "")
    let (output, _) = env.run("show", $id)
    check "Tags:" notin output

  test "edit add attachment":
    let id = env.addTask("Task", "-f", "http://a.com/1.pdf")
    discard env.run("edit", $id, "-f", "http://b.com/2.pdf")
    let (output, _) = env.run("show", $id)
    check "1.pdf" in output
    check "2.pdf" in output

  test "edit detach specific":
    let id = env.addTask("Task", "-f", "http://a.com/keep.pdf", "-f", "http://b.com/remove.pdf")
    discard env.run("edit", $id, "--detach", "remove")
    let (output, _) = env.run("show", $id)
    check "keep.pdf" in output
    check "remove.pdf" notin output

  test "edit detach all":
    let id = env.addTask("Task", "-f", "http://a.com/1.pdf", "-f", "http://b.com/2.pdf")
    discard env.run("edit", $id, "--detach", "")
    let (output, _) = env.run("show", $id)
    check "Attach:" notin output

  test "edit alarms":
    let id = env.addTask("Task")
    discard env.run("edit", $id, "-a", "10")
    let (output, _) = env.run("show", $id)
    check "10m before" in output

  test "edit clear alarms":
    let id = env.addTask("Task", "-a", "15")
    discard env.run("edit", $id, "-a", "")
    let (output, _) = env.run("show", $id)
    check "Alarms:" notin output

  test "edit add recurrence":
    let id = env.addTask("Task", "-d", "today")
    discard env.run("edit", $id, "--every", "daily")
    let (output, _) = env.run("show", $id)
    check "every day" in output

  test "edit clear recurrence":
    let id = env.addTask("Task", "-d", "today", "--every", "daily")
    discard env.run("edit", $id, "--every", "")
    let (output, _) = env.run("show", $id)
    check "Recur:" notin output

  test "edit bumps sequence":
    let id = env.addTask("Task")
    # Read ICS before edit
    let files = env.icsFiles()
    let before = readFile(files[0])
    discard env.run("edit", $id, "Updated")
    let after = readFile(files[0])
    check "SEQUENCE:1" in after

  test "edit nonexistent":
    let (_, code) = env.run("edit", "999", "Nope")
    check code != 0

  test "edit alias mod":
    let id = env.addTask("Original")
    let (_, code) = env.run("mod", $id, "Modified")
    check code == 0
    let (output, _) = env.run("show", $id)
    check "Modified" in output

  test "edit alias modify":
    let id = env.addTask("Original")
    let (_, code) = env.run("modify", $id, "Modified2")
    check code == 0

suite "done command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "done marks completed":
    let id = env.addTask("Finish me", "-d", "today")
    let (_, code) = env.run("done", $id)
    check code == 0
    let (output, _) = env.run("show", $id)
    check "COMPLETED" in output

  test "done multiple":
    let id1 = env.addTask("One", "-d", "today")
    let id2 = env.addTask("Two", "-d", "today")
    let (_, code) = env.run("done", $id1, $id2)
    check code == 0
    let (o1, _) = env.run("show", $id1)
    let (o2, _) = env.run("show", $id2)
    check "COMPLETED" in o1
    check "COMPLETED" in o2

  test "done recurring advances":
    let id = env.addTask("Recur", "-d", "today", "--every", "daily")
    discard env.run("done", $id)
    let (output, _) = env.run("show", $id)
    check "NEEDS-ACTION" in output
    check "tomorrow" in output
    check "every day" in output

  test "done recurring --all completes series":
    let id = env.addTask("Recur", "-d", "today", "--every", "daily")
    discard env.run("done", $id, "--all")
    let (output, _) = env.run("show", $id)
    check "COMPLETED" in output
    check "Recur:" notin output

  test "done no output on success":
    let id = env.addTask("Silent", "-d", "today")
    let (output, code) = env.run("done", $id)
    check code == 0
    check output == ""

  test "done nonexistent shows error":
    let (output, code) = env.run("done", "999")
    check code == 0  # doesn't fail hard, just stderr warning
    check "Task not found" in output  # stderr mixed in with execCmdEx

  test "done alias did":
    let id = env.addTask("Did it", "-d", "today")
    let (_, code) = env.run("did", $id)
    check code == 0
    let (output, _) = env.run("show", $id)
    check "COMPLETED" in output

suite "cancel command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "cancel marks cancelled":
    let id = env.addTask("Cancel me", "-d", "today")
    let (_, code) = env.run("cancel", $id)
    check code == 0
    let (output, _) = env.run("show", $id)
    check "CANCELLED" in output

  test "cancel multiple":
    let id1 = env.addTask("C1", "-d", "today")
    let id2 = env.addTask("C2", "-d", "today")
    discard env.run("cancel", $id1, $id2)
    let (o1, _) = env.run("show", $id1)
    let (o2, _) = env.run("show", $id2)
    check "CANCELLED" in o1
    check "CANCELLED" in o2

  test "cancel no output":
    let id = env.addTask("Quiet cancel", "-d", "today")
    let (output, _) = env.run("cancel", $id)
    check output == ""

suite "delete command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "delete moves to trash":
    let id = env.addTask("Delete me")
    let filesBefore = env.icsFiles().len
    discard env.run("delete", $id)
    let filesAfter = env.icsFiles().len
    check filesAfter == filesBefore - 1
    check dirExists(env.trashDir)
    var trashFiles: seq[string]
    for f in walkFiles(env.trashDir / "*.ics"):
      trashFiles.add(f)
    check trashFiles.len == 1

  test "delete multiple":
    let id1 = env.addTask("Del1")
    let id2 = env.addTask("Del2")
    discard env.run("delete", $id1, $id2)
    check env.icsFiles().len == 0

  test "delete alias rm":
    let id = env.addTask("Rm me")
    let (_, code) = env.run("rm", $id)
    check code == 0
    check env.icsFiles().len == 0

  test "delete alias del":
    let id = env.addTask("Del me")
    let (_, code) = env.run("del", $id)
    check code == 0

  test "delete alias remove":
    let id = env.addTask("Remove me")
    let (_, code) = env.run("remove", $id)
    check code == 0

suite "find command":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "find by summary":
    discard env.addTask("Buy milk")
    discard env.addTask("Walk dog")
    let (output, code) = env.run("find", "milk")
    check code == 0
    check "Buy milk" in output
    check "Walk dog" notin output

  test "find by description":
    discard env.addTask("Task", "-n", "Contains keyword xyz")
    let (output, code) = env.run("find", "xyz")
    check code == 0
    check "Task" in output

  test "find by tag":
    discard env.addTask("Tagged task", "-t", "searchable")
    let (output, code) = env.run("find", "searchable")
    check code == 0
    check "Tagged task" in output

  test "find case insensitive":
    discard env.addTask("UPPERCASE task")
    let (output, code) = env.run("find", "uppercase")
    check code == 0
    check "UPPERCASE" in output

  test "find no results exits 1":
    discard env.addTask("Something")
    let (output, code) = env.run("find", "nonexistent")
    check code == 1
    check output == ""

  test "find alias search":
    discard env.addTask("Findable")
    let (output, code) = env.run("search", "Findable")
    check code == 0
    check "Findable" in output

suite "id gap filling":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "gap filling reuses ids":
    let id1 = env.addTask("One")
    let id2 = env.addTask("Two")
    let id3 = env.addTask("Three")
    check id1 == 1
    check id2 == 2
    check id3 == 3
    # Delete id 2
    discard env.run("delete", "2")
    # New task should get id 2
    let id4 = env.addTask("Four")
    check id4 == 2

suite "ICS round-trip":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "ics file structure":
    discard env.addTask("Roundtrip")
    let files = env.icsFiles()
    check files.len == 1
    let content = readFile(files[0])
    check "BEGIN:VCALENDAR" in content
    check "END:VCALENDAR" in content
    check "BEGIN:VTODO" in content
    check "END:VTODO" in content
    check "SUMMARY:Roundtrip" in content
    check "STATUS:NEEDS-ACTION" in content

  test "ics has uid":
    discard env.addTask("UID test")
    let content = readFile(env.icsFiles()[0])
    check "UID:" in content

  test "ics has dtstamp":
    discard env.addTask("Stamp test")
    let content = readFile(env.icsFiles()[0])
    check "DTSTAMP:" in content

  test "ics has created":
    discard env.addTask("Created test")
    let content = readFile(env.icsFiles()[0])
    check "CREATED:" in content

  test "ics due date-only":
    discard env.addTask("Date only", "-d", "2026-12-25")
    let content = readFile(env.icsFiles()[0])
    check "DUE;VALUE=DATE:20261225" in content

  test "ics priority":
    discard env.addTask("Prio task", "-p", "high")
    let content = readFile(env.icsFiles()[0])
    check "PRIORITY:1" in content

  test "ics categories":
    discard env.addTask("Cat task", "-t", "work", "-t", "urgent")
    let content = readFile(env.icsFiles()[0])
    check "CATEGORIES:work,urgent" in content

  test "ics alarm":
    discard env.addTask("Alarm task", "-a", "15")
    let content = readFile(env.icsFiles()[0])
    check "BEGIN:VALARM" in content
    check "TRIGGER:-PT15M" in content
    check "END:VALARM" in content

  test "ics rrule":
    discard env.addTask("Recur task", "--every", "daily")
    let content = readFile(env.icsFiles()[0])
    check "RRULE:FREQ=DAILY" in content

  test "ics rrule with interval":
    discard env.addTask("Bi-weekly", "--every", "2w")
    let content = readFile(env.icsFiles()[0])
    check "RRULE:FREQ=WEEKLY;INTERVAL=2" in content

  test "ics rrule with byday":
    discard env.addTask("MWF", "--every", "weekly", "--on", "mo,we,fr")
    let content = readFile(env.icsFiles()[0])
    check "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR" in content

  test "ics attachment":
    discard env.addTask("Attach", "-f", "http://example.com/file.pdf")
    let content = readFile(env.icsFiles()[0])
    check "ATTACH:http://example.com/file.pdf" in content

  test "ics completed task":
    let id = env.addTask("Complete me")
    discard env.run("done", $id)
    let content = readFile(env.icsFiles()[0])
    check "STATUS:COMPLETED" in content
    check "COMPLETED:" in content
    check "PERCENT-COMPLETE:100" in content

  test "ics cancelled task":
    let id = env.addTask("Cancel me")
    discard env.run("cancel", $id)
    let content = readFile(env.icsFiles()[0])
    check "STATUS:CANCELLED" in content

  test "ics escape special characters":
    discard env.addTask("Task with, comma; semicolon")
    let content = readFile(env.icsFiles()[0])
    check "\\," in content
    check "\\;" in content

  test "edit preserves pre/post vtodo":
    # Write an ICS with extra content before VTODO
    let uid = "test-roundtrip-uid-1234"
    let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:test\nX-WR-CALNAME:TestCal\nBEGIN:VTODO\nDTSTAMP:20260101T000000Z\nUID:" & uid & "\nSUMMARY:Preserve me\nSTATUS:NEEDS-ACTION\nEND:VTODO\nEND:VCALENDAR\n"
    writeFile(env.calDir / uid & ".ics", ics)
    # Load to get ID
    var tasks = env.run("list", "-a")
    let (listOut, _) = tasks
    # Find the task and edit it
    let (findOut, _) = env.run("find", "Preserve")
    # Extract id from the list line
    let line = findOut.splitLines[0].strip
    let id = line.split(" ")[0].strip
    discard env.run("edit", id, "-p", "high")
    let content = readFile(env.calDir / uid & ".ics")
    check "X-WR-CALNAME:TestCal" in content
    check "PRIORITY:1" in content

suite "multiple calendars":
  var env: TestEnv
  var workDir: string

  setup:
    env = setup()
    workDir = env.dir / "calendars" / "work"
    createDir(workDir)
  teardown:
    env.teardown()

  test "add to specific calendar":
    let (output, code) = env.run("add", "-c", "work", "Work task")
    check code == 0
    var workFiles: seq[string]
    for f in walkFiles(workDir / "*.ics"):
      workFiles.add(f)
    check workFiles.len == 1

  test "list filter by calendar":
    discard env.addTask("Default task", "-d", "today")
    discard env.run("add", "-c", "work", "Work task", "-d", "today")
    let (output, _) = env.run("list", "-a", "-c", "work")
    check "Work task" in output
    check "Default task" notin output

  test "show displays calendar":
    let id = env.addTask("Cal task")
    let (output, _) = env.run("show", $id)
    check "default" in output

suite "date input parsing":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "today":
    let id = env.addTask("Today", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "today" in output

  test "tomorrow":
    let id = env.addTask("Tomorrow", "-d", "tomorrow")
    let (output, _) = env.run("show", $id)
    check "tomorrow" in output

  test "relative days forward":
    let id = env.addTask("Plus 3", "-d", "+3d")
    let (output, _) = env.run("show", $id)
    let expected = (now() + 3.days).format("yyyy-MM-dd")
    check expected in output

  test "relative days backward":
    let id = env.addTask("Minus 1", "-d", "-1d")
    let (output, _) = env.run("show", $id)
    check "yesterday" in output

  test "relative weeks":
    let id = env.addTask("Plus 1w", "-d", "+1w")
    let (output, _) = env.run("show", $id)
    let expected = (now() + 7.days).format("yyyy-MM-dd")
    check expected in output

  test "relative negative weeks":
    let id = env.addTask("Minus 1w", "-d", "-1w")
    let (output, _) = env.run("show", $id)
    let expected = (now() - 7.days).format("yyyy-MM-dd")
    check expected in output

  test "weekday names":
    let id = env.addTask("Monday", "-d", "monday")
    let (output, _) = env.run("show", $id)
    check "Due:" in output

  test "short weekday names":
    let id = env.addTask("Fri", "-d", "fri")
    let (output, _) = env.run("show", $id)
    check "Due:" in output

  test "time word morning":
    let id = env.addTask("Morning", "-d", "morning")
    let (output, _) = env.run("show", $id)
    check "Due:" in output

  test "time word eod":
    let id = env.addTask("EOD", "-d", "eod")
    let (output, _) = env.run("show", $id)
    check "Due:" in output

  test "combined date and time":
    let id = env.addTask("Tomorrow noon", "-d", "tomorrow noon")
    let (output, _) = env.run("show", $id)
    check "Due:" in output

  test "absolute date with dashes":
    let id = env.addTask("Xmas", "-d", "2026-12-25")
    let (output, _) = env.run("show", $id)
    check "2026-12-25" in output

  test "absolute date compact":
    let id = env.addTask("Compact", "-d", "20261225")
    let (output, _) = env.run("show", $id)
    check "2026-12-25" in output

suite "priority input parsing":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "high":
    let id = env.addTask("H", "-p", "high")
    let (output, _) = env.run("show", $id)
    check "high (1)" in output

  test "h shortcut":
    let id = env.addTask("H2", "-p", "h")
    let (output, _) = env.run("show", $id)
    check "high (1)" in output

  test "medium":
    let id = env.addTask("M", "-p", "medium")
    let (output, _) = env.run("show", $id)
    check "medium (5)" in output

  test "med shortcut":
    let id = env.addTask("M2", "-p", "med")
    let (output, _) = env.run("show", $id)
    check "medium (5)" in output

  test "low":
    let id = env.addTask("L", "-p", "low")
    let (output, _) = env.run("show", $id)
    check "low (9)" in output

  test "l shortcut":
    let id = env.addTask("L2", "-p", "l")
    let (output, _) = env.run("show", $id)
    check "low (9)" in output

  test "none":
    let id = env.addTask("N", "-p", "none")
    let (output, _) = env.run("show", $id)
    check "Priority:" notin output

  test "numeric 1":
    let id = env.addTask("N1", "-p", "1")
    let (output, _) = env.run("show", $id)
    check "high (1)" in output

  test "numeric 5":
    let id = env.addTask("N5", "-p", "5")
    let (output, _) = env.run("show", $id)
    check "medium (5)" in output

  test "numeric 9":
    let id = env.addTask("N9", "-p", "9")
    let (output, _) = env.run("show", $id)
    check "low (9)" in output

suite "recurrence":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "daily recurrence label":
    let id = env.addTask("Daily", "--every", "daily", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every day" in output

  test "weekly recurrence label":
    let id = env.addTask("Weekly", "--every", "weekly", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every week" in output

  test "monthly recurrence label":
    let id = env.addTask("Monthly", "--every", "monthly", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every month" in output

  test "yearly recurrence label":
    let id = env.addTask("Yearly", "--every", "yearly", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every year" in output

  test "interval recurrence 3d":
    let id = env.addTask("3d", "--every", "3d", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every 3 days" in output

  test "interval recurrence 2m":
    let id = env.addTask("2m", "--every", "2m", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every 2 months" in output

  test "word form day":
    let id = env.addTask("Day", "--every", "day", "-d", "today")
    let (output, _) = env.run("show", $id)
    check "every day" in output

  test "list shows recur marker":
    discard env.addTask("Recurring", "--every", "daily", "-d", "today")
    let (output, _) = env.run("list")
    check "~" in output

  test "done on recurring advances due":
    let id = env.addTask("Recur", "--every", "1w", "-d", "today")
    discard env.run("done", $id)
    let (output, _) = env.run("show", $id)
    check "NEEDS-ACTION" in output
    # Should be 7 days from today
    let expected = (now() + 7.days).format("yyyy-MM-dd")
    check expected in output

suite "alarm ring modes":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "alarm defaults to once":
    let id = env.addTask("Once", "-a", "15")
    let (output, _) = env.run("show", $id)
    check "15m before" in output
    check "(5x)" notin output
    check "(nag)" notin output
    let content = readFile(env.icsFiles()[0])
    check "REPEAT" notin content

  test "alarm 5x mode":
    let id = env.addTask("Five", "-a", "15:5x")
    let (output, _) = env.run("show", $id)
    check "15m before (5x)" in output
    let content = readFile(env.icsFiles()[0])
    check "REPEAT:4" in content
    check "DURATION:PT5M" in content

  test "alarm nag mode":
    let id = env.addTask("Nag", "-a", "10:nag")
    let (output, _) = env.run("show", $id)
    check "10m before (nag)" in output
    let content = readFile(env.icsFiles()[0])
    check "REPEAT:60" in content
    check "DURATION:PT1M" in content

  test "alarm 5x shortcut with just 5":
    let id = env.addTask("Short", "-a", "15:5")
    let (output, _) = env.run("show", $id)
    check "15m before (5x)" in output

  test "alarm persistent alias":
    let id = env.addTask("Persist", "-a", "15:persistent")
    let (output, _) = env.run("show", $id)
    check "15m before (nag)" in output

  test "alarm always alias":
    let id = env.addTask("Always", "-a", "15:always")
    let (output, _) = env.run("show", $id)
    check "15m before (nag)" in output

  test "alarm once explicit":
    let id = env.addTask("Explicit", "-a", "15:once")
    let (output, _) = env.run("show", $id)
    check "15m before" in output
    check "(5x)" notin output

  test "multiple alarms mixed modes":
    let id = env.addTask("Mixed", "-a", "5", "-a", "15:5x", "-a", "30:nag")
    let (output, _) = env.run("show", $id)
    check "5m before" in output
    check "15m before (5x)" in output
    check "30m before (nag)" in output

  test "invalid ring mode fails":
    let (_, code) = env.run("add", "Bad", "-a", "15:bogus")
    check code != 0

  test "edit alarm with ring mode":
    let id = env.addTask("Task")
    discard env.run("edit", $id, "-a", "10:nag")
    let (output, _) = env.run("show", $id)
    check "10m before (nag)" in output

  test "round-trip preserves ring mode":
    let id = env.addTask("RT", "-a", "20:5x")
    # Edit something else, alarm should be preserved
    discard env.run("edit", $id, "-p", "high")
    let (output, _) = env.run("show", $id)
    check "20m before (5x)" in output

  test "ics round-trip reads repeat":
    # Write ICS with REPEAT/DURATION manually
    let uid = "test-alarm-ring-uid"
    let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:test\nBEGIN:VTODO\nDTSTAMP:20260101T000000Z\nUID:" & uid & "\nSUMMARY:Ext alarm\nSTATUS:NEEDS-ACTION\nBEGIN:VALARM\nTRIGGER:-PT25M\nACTION:DISPLAY\nDESCRIPTION:Ext alarm\nREPEAT:4\nDURATION:PT5M\nEND:VALARM\nEND:VTODO\nEND:VCALENDAR\n"
    writeFile(env.calDir / uid & ".ics", ics)
    let (findOut, _) = env.run("find", "Ext alarm")
    let line = findOut.splitLines[0].strip
    let id = line.split(" ")[0].strip
    let (output, _) = env.run("show", id)
    check "25m before (5x)" in output

  test "ics round-trip reads nag repeat":
    let uid = "test-alarm-nag-uid"
    let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:test\nBEGIN:VTODO\nDTSTAMP:20260101T000000Z\nUID:" & uid & "\nSUMMARY:Nag alarm\nSTATUS:NEEDS-ACTION\nBEGIN:VALARM\nTRIGGER:-PT5M\nACTION:DISPLAY\nDESCRIPTION:Nag alarm\nREPEAT:60\nDURATION:PT1M\nEND:VALARM\nEND:VTODO\nEND:VCALENDAR\n"
    writeFile(env.calDir / uid & ".ics", ics)
    let (findOut, _) = env.run("find", "Nag alarm")
    let line = findOut.splitLines[0].strip
    let id = line.split(" ")[0].strip
    let (output, _) = env.run("show", id)
    check "5m before (nag)" in output

suite "edge cases":
  var env: TestEnv

  setup:
    env = setup()
  teardown:
    env.teardown()

  test "multi-word summary":
    let id = env.addTask("This is a long summary with many words")
    let (output, _) = env.run("show", $id)
    check "This is a long summary with many words" in output

  test "special chars in summary":
    let id = env.addTask("Task with, comma")
    let (output, _) = env.run("show", $id)
    check "Task with, comma" in output

  test "semicolon in summary":
    let id = env.addTask("Task; with; semicolons")
    let (output, _) = env.run("show", $id)
    check "Task; with; semicolons" in output

  test "unknown option fails":
    let (_, code) = env.run("add", "--bogus", "test")
    check code != 0

  test "no args shows list":
    discard env.addTask("Listed task", "-d", "today")
    let (output, code) = env.run()
    check code == 0
    check "Listed task" in output

  test "delete then add reuses id":
    discard env.addTask("First")
    discard env.addTask("Second")
    discard env.run("delete", "1")
    let newId = env.addTask("Third")
    check newId == 1
