## td - Task manager for ICS/vdirsyncer

import std/[os, times, strutils, sequtils, algorithm, tables, parseopt,
            envvars, options, terminal, sysrand, sets]

# --- Version ---

const NimbleFile = staticRead("../td.nimble")
const Version = block:
  var v = "dev"
  for line in NimbleFile.splitLines:
    let s = line.strip
    if s.startsWith("version"):
      v = s.split("=", 1)[1].strip.strip(chars = {'"'})
      break
  v

# --- ANSI Colors ---

var useColor = false

proc red(s: string): string =
  if useColor: "\e[31m" & s & "\e[0m" else: s

proc yellow(s: string): string =
  if useColor: "\e[33m" & s & "\e[0m" else: s

proc green(s: string): string =
  if useColor: "\e[32m" & s & "\e[0m" else: s

proc bold(s: string): string =
  if useColor: "\e[1m" & s & "\e[0m" else: s

proc dim(s: string): string =
  if useColor: "\e[2m" & s & "\e[0m" else: s

# --- Configuration ---

var tdPath = ""
var defaultCal = ""
var dataDir = ""

# --- Types ---

type
  TaskStatus = enum
    tsNeedsAction = "NEEDS-ACTION"
    tsInProcess = "IN-PROCESS"
    tsCompleted = "COMPLETED"
    tsCancelled = "CANCELLED"

  DueDate = object
    dt*: DateTime
    isDateOnly*: bool
    tzid*: string

  Task = object
    id*: int
    uid*: string
    summary*: string
    description*: string
    due*: Option[DueDate]
    priority*: int
    status*: TaskStatus
    categories*: seq[string]
    alarms*: seq[int]  # minutes before due
    created*: Option[DateTime]
    lastModified*: Option[DateTime]
    completed*: Option[DateTime]
    dtstamp*: Option[DateTime]
    sequence*: int
    percentComplete*: int
    calendarName*: string
    filePath*: string
    preVtodo*: seq[string]
    postVtodo*: seq[string]
    extraProps*: seq[string]

# --- Helpers ---

proc findTask(tasks: seq[Task], id: int): int =
  for i in 0 ..< tasks.len:
    if tasks[i].id == id: return i
  return -1

proc priorityName(p: int): string =
  case p
  of 1: "high"
  of 2, 3, 4: "medium-high"
  of 5: "medium"
  of 6, 7, 8: "medium-low"
  of 9: "low"
  else: "none"

proc priorityIcon(p: int): string =
  case p
  of 1: "!!!"
  of 2, 3, 4, 5: "!! "
  of 6, 7, 8, 9: "!  "
  else: "   "

proc priorityIconColored(p: int): string =
  case p
  of 1: red("!!!")
  of 2, 3, 4, 5: yellow("!! ")
  of 6, 7, 8, 9: "!  "
  else: "   "

proc sortPriority(p: int): int =
  if p == 0: 6 else: p

# --- .env Loading ---

proc loadEnvFile(path: string) =
  if not fileExists(path): return
  for line in lines(path):
    let stripped = line.strip
    if stripped.len == 0 or stripped[0] == '#': continue
    let parts = stripped.split("=", 1)
    if parts.len == 2:
      let key = parts[0].strip
      var val = parts[1].strip
      if val.len >= 2 and val[0] == '"' and val[^1] == '"':
        val = val[1 ..^ 2]
      putEnv(key, val)

# --- UUID ---

proc generateUuid(): string =
  var bytes: array[16, byte]
  doAssert urandom(bytes)
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  var hex = ""
  for b in bytes:
    hex.add(b.toHex(2))
  hex = hex.toLowerAscii
  hex[0 .. 7] & "-" & hex[8 .. 11] & "-" & hex[12 .. 15] & "-" &
    hex[16 .. 19] & "-" & hex[20 .. 31]

# --- ICS Text Helpers ---

proc escapeIcsText(s: string): string =
  result = s
  result = result.replace("\\", "\\\\")
  result = result.replace(",", "\\,")
  result = result.replace(";", "\\;")
  result = result.replace("\n", "\\n")
  result = result.replace("\r", "")

proc unescapeIcsText(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '\\':
      case s[i + 1]
      of 'n', 'N': result.add('\n')
      of ',': result.add(',')
      of ';': result.add(';')
      of '\\': result.add('\\')
      else: result.add(s[i]); result.add(s[i + 1])
      i += 2
    else:
      result.add(s[i])
      i += 1

proc unfoldLines(content: string): seq[string] =
  result = @[]
  for line in content.splitLines:
    if line.len > 0 and line[0] in {' ', '\t'} and result.len > 0:
      result[^1].add(line[1 ..^ 1])
    else:
      result.add(line)
  while result.len > 0 and result[^1].strip == "":
    result.setLen(result.len - 1)

proc foldLine(line: string, maxLen = 75): string =
  if line.len <= maxLen:
    return line
  result = line[0 ..< maxLen]
  var i = maxLen
  while i < line.len:
    let endIdx = min(i + maxLen - 1, line.len)
    result.add("\n " & line[i ..< endIdx])
    i += maxLen - 1

proc parsePropLine(line: string): tuple[name, params, value: string] =
  let colonPos = line.find(':')
  if colonPos < 0:
    return (line, "", "")
  let left = line[0 ..< colonPos]
  let value = line[colonPos + 1 ..^ 1]
  let semiPos = left.find(';')
  if semiPos < 0:
    (left, "", value)
  else:
    (left[0 ..< semiPos], left[semiPos + 1 ..^ 1], value)

# --- ICS DateTime Parsing ---

proc parseIcsUtcDt(value: string): DateTime =
  let v = value.strip
  if v.endsWith("Z"):
    parse(v, "yyyyMMdd'T'HHmmss'Z'", utc())
  else:
    parse(v, "yyyyMMdd'T'HHmmss", utc())

proc parseIcsDue(params, value: string): DueDate =
  var tzid = ""
  var isDate = false
  for param in params.split(';'):
    let kv = param.split('=', 1)
    if kv.len == 2:
      if kv[0].toUpperAscii == "VALUE" and kv[1].toUpperAscii == "DATE":
        isDate = true
      elif kv[0].toUpperAscii == "TZID":
        tzid = kv[1]
  if isDate or value.strip.len == 8:
    DueDate(dt: parse(value.strip, "yyyyMMdd"), isDateOnly: true, tzid: "")
  elif value.strip.endsWith("Z"):
    DueDate(dt: parse(value.strip, "yyyyMMdd'T'HHmmss'Z'", utc()),
            isDateOnly: false, tzid: "UTC")
  else:
    DueDate(dt: parse(value.strip, "yyyyMMdd'T'HHmmss"),
            isDateOnly: false, tzid: tzid)

proc formatIcsDue(d: DueDate): string =
  if d.isDateOnly:
    "DUE;VALUE=DATE:" & d.dt.format("yyyyMMdd")
  elif d.tzid != "" and d.tzid != "UTC":
    "DUE;TZID=" & d.tzid & ":" & d.dt.format("yyyyMMdd'T'HHmmss")
  else:
    "DUE:" & d.dt.format("yyyyMMdd'T'HHmmss'Z'")

# --- Alarm Trigger Parsing ---

proc parseAlarmMinutes(value: string): int =
  var s = value.strip
  var negative = s.startsWith("-")
  if negative: s = s[1 ..^ 1]
  elif s.startsWith("+"): s = s[1 ..^ 1]
  if s.startsWith("P"): s = s[1 ..^ 1]
  var minutes = 0
  var numStr = ""
  for c in s:
    if c == 'T': continue
    if c.isDigit:
      numStr.add(c)
    else:
      let n = if numStr.len > 0: parseInt(numStr) else: 0
      numStr = ""
      case c
      of 'D': minutes += n * 1440
      of 'H': minutes += n * 60
      of 'M': minutes += n
      of 'S': discard
      else: discard
  if negative: minutes else: 0

proc parseStatus(s: string): TaskStatus =
  case s.strip.toUpperAscii
  of "NEEDS-ACTION": tsNeedsAction
  of "IN-PROCESS": tsInProcess
  of "COMPLETED": tsCompleted
  of "CANCELLED": tsCancelled
  else: tsNeedsAction

# --- ICS File Parsing ---

proc parseTask(filePath, calName: string): Option[Task] =
  let content = try: readFile(filePath) except: return none(Task)
  let rawLines = content.splitLines

  var preLines, vtodoRawLines, postLines: seq[string]
  var phase = 0 # 0=pre, 1=vtodo, 2=post
  for line in rawLines:
    case phase
    of 0:
      if line.strip == "BEGIN:VTODO":
        phase = 1
      else:
        preLines.add(line)
    of 1:
      if line.strip == "END:VTODO":
        phase = 2
      else:
        vtodoRawLines.add(line)
    of 2:
      postLines.add(line)
    else: discard

  if phase < 1: return none(Task)

  let vtodoLines = unfoldLines(vtodoRawLines.join("\n"))

  # Separate VALARM blocks from properties
  var propLines: seq[string]
  var alarmLines: seq[string]
  var inAlarm = false
  for line in vtodoLines:
    if line.strip == "BEGIN:VALARM":
      inAlarm = true
      alarmLines = @[]
    elif line.strip == "END:VALARM":
      inAlarm = false
    elif inAlarm:
      alarmLines.add(line)
    else:
      propLines.add(line)

  var task = Task(
    status: tsNeedsAction,
    calendarName: calName,
    filePath: filePath,
    preVtodo: preLines,
    postVtodo: postLines,
  )

  var extraProps: seq[string]
  for line in propLines:
    if line.strip.len == 0: continue
    let (name, params, value) = parsePropLine(line)
    case name.toUpperAscii
    of "UID": task.uid = value
    of "SUMMARY": task.summary = unescapeIcsText(value)
    of "DESCRIPTION": task.description = unescapeIcsText(value)
    of "DUE":
      try: task.due = some(parseIcsDue(params, value))
      except: extraProps.add(line)
    of "PRIORITY":
      try: task.priority = parseInt(value.strip)
      except: discard
    of "STATUS": task.status = parseStatus(value)
    of "CATEGORIES":
      for cat in value.split(","):
        let c = cat.strip
        if c.len > 0: task.categories.add(c)
    of "CREATED":
      try: task.created = some(parseIcsUtcDt(value))
      except: discard
    of "LAST-MODIFIED":
      try: task.lastModified = some(parseIcsUtcDt(value))
      except: discard
    of "COMPLETED":
      try: task.completed = some(parseIcsUtcDt(value))
      except: discard
    of "DTSTAMP":
      try: task.dtstamp = some(parseIcsUtcDt(value))
      except: discard
    of "SEQUENCE":
      try: task.sequence = parseInt(value.strip)
      except: discard
    of "PERCENT-COMPLETE":
      try: task.percentComplete = parseInt(value.strip)
      except: discard
    else:
      extraProps.add(line)

  # Parse alarms
  for line in alarmLines:
    let (name, params, value) = parsePropLine(line)
    if name.toUpperAscii == "TRIGGER":
      task.alarms.add(parseAlarmMinutes(value))

  task.extraProps = extraProps
  if task.uid.len == 0: return none(Task)
  some(task)

# --- ICS File Writing ---

proc toIcs(task: Task): string =
  var lines: seq[string]

  if task.preVtodo.len > 0:
    lines = task.preVtodo
  else:
    lines = @["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:td/" & Version]

  lines.add("BEGIN:VTODO")

  let stamp = now().utc.format("yyyyMMdd'T'HHmmss'Z'")
  lines.add("DTSTAMP:" & stamp)
  lines.add("UID:" & task.uid)
  if task.sequence > 0:
    lines.add("SEQUENCE:" & $task.sequence)
  if task.created.isSome:
    lines.add("CREATED:" & task.created.get.format("yyyyMMdd'T'HHmmss'Z'"))
  lines.add("LAST-MODIFIED:" & stamp)
  lines.add(foldLine("SUMMARY:" & escapeIcsText(task.summary)))
  if task.description.len > 0:
    lines.add(foldLine("DESCRIPTION:" & escapeIcsText(task.description)))
  if task.due.isSome:
    lines.add(formatIcsDue(task.due.get))
  if task.priority > 0:
    lines.add("PRIORITY:" & $task.priority)
  lines.add("STATUS:" & $task.status)
  if task.categories.len > 0:
    lines.add(foldLine("CATEGORIES:" & task.categories.join(",")))
  if task.percentComplete > 0:
    lines.add("PERCENT-COMPLETE:" & $task.percentComplete)
  if task.status == tsCompleted:
    if task.completed.isSome:
      lines.add("COMPLETED:" & task.completed.get.format("yyyyMMdd'T'HHmmss'Z'"))
    else:
      lines.add("COMPLETED:" & stamp)

  for prop in task.extraProps:
    lines.add(foldLine(prop))

  for mins in task.alarms:
    lines.add("BEGIN:VALARM")
    if mins > 0:
      lines.add("TRIGGER:-PT" & $mins & "M")
    else:
      lines.add("TRIGGER:PT0S")
    lines.add("ACTION:DISPLAY")
    lines.add(foldLine("DESCRIPTION:" & escapeIcsText(task.summary)))
    lines.add("END:VALARM")

  lines.add("END:VTODO")

  if task.postVtodo.len > 0:
    for line in task.postVtodo:
      lines.add(line)
  else:
    lines.add("END:VCALENDAR")

  lines.join("\n") & "\n"

# --- ID Map ---

proc loadIdMap(): (Table[string, int], Table[int, string]) =
  var uidToId: Table[string, int]
  var idToUid: Table[int, string]
  let path = dataDir / "idmap"
  if fileExists(path):
    for line in lines(path):
      let parts = line.split('\t')
      if parts.len >= 2:
        try:
          let id = parseInt(parts[0])
          let uid = parts[1]
          uidToId[uid] = id
          idToUid[id] = uid
        except: discard
  (uidToId, idToUid)

proc saveIdMap(uidToId: Table[string, int]) =
  createDir(dataDir)
  let path = dataDir / "idmap"
  var f = open(path, fmWrite)
  defer: f.close()
  var pairs: seq[(int, string)]
  for uid, id in uidToId:
    pairs.add((id, uid))
  pairs.sort()
  for (id, uid) in pairs:
    f.writeLine($id & "\t" & uid)

proc syncIdMap(tasks: var seq[Task]) =
  var (uidToId, idToUid) = loadIdMap()
  let taskUids = tasks.mapIt(it.uid).toHashSet

  # Remove stale entries
  var staleUids: seq[string]
  for uid in uidToId.keys:
    if uid notin taskUids:
      staleUids.add(uid)
  for uid in staleUids:
    let id = uidToId[uid]
    uidToId.del(uid)
    idToUid.del(id)

  # Add new entries with gap-filling
  var usedIds = toHashSet(toSeq(idToUid.keys))
  for i in 0 ..< tasks.len:
    if tasks[i].uid notin uidToId:
      var newId = 1
      while newId in usedIds:
        inc newId
      uidToId[tasks[i].uid] = newId
      idToUid[newId] = tasks[i].uid
      usedIds.incl(newId)

  saveIdMap(uidToId)

  for i in 0 ..< tasks.len:
    tasks[i].id = uidToId[tasks[i].uid]

# --- Date Parsing ---

proc parseDateInput(s: string): DueDate =
  let today = now()
  let todayDate = dateTime(today.year, today.month, today.monthday, zone = local())

  proc nextWeekday(target: WeekDay): DueDate =
    var d = todayDate + 1.days
    for _ in 0 ..< 7:
      if d.weekday == target:
        return DueDate(dt: d, isDateOnly: true)
      d = d + 1.days
    DueDate(dt: d, isDateOnly: true)

  case s.toLowerAscii
  of "today": return DueDate(dt: todayDate, isDateOnly: true)
  of "tomorrow": return DueDate(dt: todayDate + 1.days, isDateOnly: true)
  of "yesterday": return DueDate(dt: todayDate - 1.days, isDateOnly: true)
  of "monday", "mon": return nextWeekday(dMon)
  of "tuesday", "tue": return nextWeekday(dTue)
  of "wednesday", "wed": return nextWeekday(dWed)
  of "thursday", "thu": return nextWeekday(dThu)
  of "friday", "fri": return nextWeekday(dFri)
  of "saturday", "sat": return nextWeekday(dSat)
  of "sunday", "sun": return nextWeekday(dSun)
  else: discard

  # Relative: +3d, -1w, +2m
  if s.len >= 2 and s[0] in {'+', '-'}:
    let sign = if s[0] == '+': 1 else: -1
    let unit = s[^1]
    let numStr = s[1 ..^ 2]
    try:
      let n = parseInt(numStr)
      case unit
      of 'd': return DueDate(dt: todayDate + (n * sign).days, isDateOnly: true)
      of 'w': return DueDate(dt: todayDate + (n * sign * 7).days, isDateOnly: true)
      of 'm': return DueDate(dt: todayDate + (n * sign).months, isDateOnly: true)
      else: discard
    except ValueError: discard

  # Absolute: 2026-04-01 or 20260401
  let cleaned = s.replace("-", "")
  try:
    return DueDate(dt: parse(cleaned, "yyyyMMdd"), isDateOnly: true)
  except:
    quit("Invalid date: " & s, 1)

proc parsePriority(s: string): int =
  case s.toLowerAscii
  of "high", "h", "1": 1
  of "medium", "med", "m", "5": 5
  of "low", "l", "9": 9
  of "none", "n", "0", "": 0
  else:
    try:
      let n = parseInt(s)
      if n < 0 or n > 9: quit("Invalid priority: " & s, 1)
      n
    except ValueError:
      quit("Invalid priority: " & s, 1)

# --- Task Loading ---

proc defaultCalendarName(): string =
  if defaultCal != "":
    return defaultCal
  var first = ""
  for kind, path in walkDir(tdPath):
    if kind != pcDir: continue
    let name = lastPathPart(path)
    if name.startsWith("."): continue
    if name == "default": return "default"
    if first == "": first = name
  if first == "":
    quit("No calendars found in " & tdPath, 1)
  first

proc resolveCalendar(name: string): string =
  result = tdPath / name
  if not dirExists(result):
    quit("Calendar not found: " & name, 1)

proc loadAllTasks(): seq[Task] =
  result = @[]
  for calKind, calPath in walkDir(tdPath):
    if calKind != pcDir: continue
    let calName = lastPathPart(calPath)
    if calName.startsWith("."): continue
    for fileKind, filePath in walkDir(calPath):
      if fileKind != pcFile: continue
      if not filePath.endsWith(".ics"): continue
      let task = parseTask(filePath, calName)
      if task.isSome:
        result.add(task.get)
  syncIdMap(result)

# --- Display ---

proc dueLabel(d: DueDate): string =
  let today = now()
  let todayTuple = (today.year, today.month.ord, today.monthday)
  let dueTuple = (d.dt.year, d.dt.month.ord, d.dt.monthday)
  if dueTuple == todayTuple: return "today"
  let tom = today + 1.days
  let tomTuple = (tom.year, tom.month.ord, tom.monthday)
  if dueTuple == tomTuple: return "tomorrow"
  let yest = today - 1.days
  let yestTuple = (yest.year, yest.month.ord, yest.monthday)
  if dueTuple == yestTuple: return "yesterday"
  d.dt.format("yyyy-MM-dd")

proc dueLabelColored(d: DueDate): string =
  let today = now()
  let todayTuple = (today.year, today.month.ord, today.monthday)
  let dueTuple = (d.dt.year, d.dt.month.ord, d.dt.monthday)
  if dueTuple == todayTuple: return bold("today")
  let tom = today + 1.days
  if (tom.year, tom.month.ord, tom.monthday) == dueTuple: return "tomorrow"
  if dueTuple < todayTuple: return red(dueLabel(d))
  dueLabel(d)

proc isOverdue(d: DueDate): bool =
  let today = now()
  (d.dt.year, d.dt.month.ord, d.dt.monthday) <
    (today.year, today.month.ord, today.monthday)

proc isDueToday(d: DueDate): bool =
  let today = now()
  (d.dt.year, d.dt.month.ord, d.dt.monthday) ==
    (today.year, today.month.ord, today.monthday)

proc sortDue(d: Option[DueDate]): int64 =
  if d.isNone: return high(int64)
  d.get.dt.toTime.toUnix

proc displayList(tasks: seq[Task]) =
  if tasks.len == 0:
    return

  let maxIdWidth = max(2, tasks.mapIt(($it.id).len).max)
  let maxCalWidth = max(3, tasks.mapIt(it.calendarName.len).max)
  let dueWidth = 10
  let prioWidth = 3
  let tw = try: terminalWidth() except: 80
  let summaryWidth = max(10, tw - maxIdWidth - 1 - prioWidth - 1 - dueWidth - 1 - maxCalWidth - 1)

  for t in tasks:
    let idStr = align($t.id, maxIdWidth)
    let prioStr = if useColor: priorityIconColored(t.priority)
                  else: priorityIcon(t.priority)
    let dueStr = if t.due.isSome:
                   if useColor: alignLeft(dueLabelColored(t.due.get), dueWidth)
                   else: alignLeft(dueLabel(t.due.get), dueWidth)
                 else: alignLeft("--", dueWidth)
    var summ = t.summary
    if summ.len > summaryWidth:
      summ = summ[0 ..< summaryWidth - 3] & "..."
    let summStr = alignLeft(summ, summaryWidth)
    let calStr = t.calendarName

    let statusMark = case t.status
      of tsCompleted: dim("[x] ")
      of tsCancelled: dim("[-] ")
      of tsInProcess: "[>] "
      else: "    "

    echo idStr & " " & prioStr & " " & dueStr & " " & statusMark & summStr & " " & calStr

proc displayDetail(task: Task) =
  echo bold($task.id & ": " & task.summary)
  echo "  Calendar:  " & task.calendarName
  echo "  Status:    " & $task.status
  if task.priority > 0:
    echo "  Priority:  " & priorityName(task.priority) & " (" & $task.priority & ")"
  if task.due.isSome:
    let d = task.due.get
    let label = if useColor: dueLabelColored(d) else: dueLabel(d)
    echo "  Due:       " & label & (if d.isDateOnly: "" else: " " & d.dt.format("HH:mm"))
  if task.description.len > 0:
    echo "  Note:      " & task.description.replace("\n", "\n             ")
  if task.categories.len > 0:
    echo "  Tags:      " & task.categories.join(", ")
  if task.alarms.len > 0:
    echo "  Alarms:    " & task.alarms.mapIt($it & "m before").join(", ")
  if task.created.isSome:
    echo "  Created:   " & task.created.get.local.format("yyyy-MM-dd HH:mm")
  if task.lastModified.isSome:
    echo "  Modified:  " & task.lastModified.get.local.format("yyyy-MM-dd HH:mm")

# --- Option Parsing Helpers ---

type
  ParsedOpts = object
    due: Option[DueDate]
    hasDue: bool
    priority: int
    hasPriority: bool
    note: string
    hasNote: bool
    tags: seq[string]
    hasTags: bool
    alarms: seq[int]
    hasAlarms: bool
    calName: string
    hasCal: bool
    # list-specific
    showAll: bool
    showDone: bool
    sortField: string
    # positional
    args: seq[string]

proc handleOptValue(opts: var ParsedOpts, field, value: string) =
  case field
  of "d":
    opts.hasDue = true
    if value == "":
      opts.due = none(DueDate)
    else:
      opts.due = some(parseDateInput(value))
  of "p":
    opts.hasPriority = true
    opts.priority = parsePriority(value)
  of "n":
    opts.hasNote = true
    opts.note = value
  of "t":
    opts.hasTags = true
    if value == "":
      opts.tags = @[]
    else:
      opts.tags.add(value)
  of "a-alarm":
    opts.hasAlarms = true
    if value == "":
      opts.alarms = @[]
    else:
      try: opts.alarms.add(parseInt(value))
      except ValueError: quit("Invalid alarm minutes: " & value, 1)
  of "c":
    opts.hasCal = true
    opts.calName = value
  of "s":
    opts.sortField = value
  else: discard

proc parseOpts(args: seq[string], isListCmd: bool = false): ParsedOpts =
  var opts = ParsedOpts(sortField: "default")
  var expectVal = ""
  var p = initOptParser(args)
  for kind, key, val in p.getopt():
    if expectVal != "":
      if kind == cmdShortOption and key.len > 0 and key[0].isDigit:
        # Negative value like -1w
        handleOptValue(opts, expectVal, "-" & key & val)
        expectVal = ""
        continue
      elif kind in {cmdArgument, cmdEnd}:
        handleOptValue(opts, expectVal, key)
        expectVal = ""
        if kind == cmdEnd: break
        continue
      else:
        # Next option without value — error
        quit("Missing value for option", 1)

    case kind
    of cmdShortOption, cmdLongOption:
      if val != "":
        case key
        of "d", "due": handleOptValue(opts, "d", val)
        of "p", "priority", "prio": handleOptValue(opts, "p", val)
        of "n", "note": handleOptValue(opts, "n", val)
        of "t", "tag": handleOptValue(opts, "t", val)
        of "a":
          if isListCmd: opts.showAll = true
          else: handleOptValue(opts, "a-alarm", val)
        of "alarm": handleOptValue(opts, "a-alarm", val)
        of "c", "cal", "calendar": handleOptValue(opts, "c", val)
        of "s", "sort": handleOptValue(opts, "s", val)
        of "done": opts.showDone = true
        else: quit("Unknown option: " & key, 1)
      else:
        case key
        of "d", "due": expectVal = "d"
        of "p", "priority", "prio": expectVal = "p"
        of "n", "note": expectVal = "n"
        of "t", "tag": expectVal = "t"
        of "a":
          if isListCmd: opts.showAll = true
          else: expectVal = "a-alarm"
        of "alarm": expectVal = "a-alarm"
        of "c", "cal", "calendar": expectVal = "c"
        of "s", "sort": expectVal = "s"
        of "all": opts.showAll = true
        of "done": opts.showDone = true
        else: quit("Unknown option: " & key, 1)
    of cmdArgument:
      opts.args.add(key)
    of cmdEnd: break

  if expectVal != "":
    quit("Missing value for option", 1)
  opts

# --- Commands ---

proc cmdAdd(args: seq[string]) =
  let opts = parseOpts(args)
  if opts.args.len == 0:
    quit("Usage: td add [options] \"summary\"", 1)

  let summary = opts.args.join(" ")
  let calName = if opts.hasCal: opts.calName else: defaultCalendarName()
  let calDir = resolveCalendar(calName)
  let uid = generateUuid()
  let filePath = calDir / uid & ".ics"

  var task = Task(
    uid: uid,
    summary: summary,
    description: if opts.hasNote: opts.note else: "",
    due: opts.due,
    priority: if opts.hasPriority: opts.priority else: 0,
    status: tsNeedsAction,
    categories: opts.tags,
    alarms: opts.alarms,
    calendarName: calName,
    filePath: filePath,
    created: some(now().utc),
    sequence: 0,
  )

  writeFile(filePath, toIcs(task))

  # Sync idmap to get assigned ID
  var allTasks = loadAllTasks()
  var taskId = 0
  for t in allTasks:
    if t.uid == uid:
      taskId = t.id
      break
  echo $taskId

proc cmdEdit(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td edit <id> [options]", 1)

  var taskId: int
  try: taskId = parseInt(args[0])
  except ValueError: quit("Invalid task ID: " & args[0], 1)

  var allTasks = loadAllTasks()
  let idx = findTask(allTasks, taskId)
  if idx < 0:
    quit("Task not found: " & $taskId, 1)

  let opts = parseOpts(args[1 ..^ 1])
  var task = allTasks[idx]

  # Apply only explicitly set fields
  if opts.hasDue: task.due = opts.due
  if opts.hasNote: task.description = opts.note
  if opts.hasPriority: task.priority = opts.priority
  if opts.hasTags: task.categories = opts.tags
  if opts.hasAlarms: task.alarms = opts.alarms

  # Update summary if positional arg given
  if opts.args.len > 0:
    task.summary = opts.args.join(" ")

  task.sequence += 1
  task.lastModified = some(now().utc)

  writeFile(task.filePath, toIcs(task))
  discard

proc cmdList(args: seq[string]) =
  let opts = parseOpts(args, isListCmd = true)
  if opts.args.len > 0:
    quit("Unexpected argument: " & opts.args[0] & ". See td --help", 1)
  var tasks = loadAllTasks()

  # Filter
  if not opts.showAll:
    # Status filter
    if opts.showDone:
      tasks = tasks.filterIt(it.status in {tsCompleted, tsCancelled})
    else:
      tasks = tasks.filterIt(it.status in {tsNeedsAction, tsInProcess})

    # Due date filter (default: overdue + today + no due)
    if opts.hasDue and opts.due.isSome:
      let filterDue = opts.due.get
      let label = dueLabel(filterDue)
      case label
      of "today":
        tasks = tasks.filterIt(it.due.isNone or
          (it.due.isSome and (isDueToday(it.due.get) or isOverdue(it.due.get))))
      of "tomorrow":
        let tom = now() + 1.days
        let tomTuple = (tom.year, tom.month.ord, tom.monthday)
        tasks = tasks.filterIt(it.due.isSome and
          (it.due.get.dt.year, it.due.get.dt.month.ord, it.due.get.dt.monthday) <= tomTuple)
      else:
        # Filter up to the specified date
        let target = (filterDue.dt.year, filterDue.dt.month.ord, filterDue.dt.monthday)
        tasks = tasks.filterIt(it.due.isSome and
          (it.due.get.dt.year, it.due.get.dt.month.ord, it.due.get.dt.monthday) <= target)
    elif not opts.showDone and not opts.hasDue:
      # Default: overdue + today + no due date
      tasks = tasks.filterIt(
        it.due.isNone or
        (it.due.isSome and (isDueToday(it.due.get) or isOverdue(it.due.get)))
      )

    # Priority filter (default: 0-5, hide low)
    if opts.hasPriority:
      let maxPrio = opts.priority  # e.g., 9 means show all
      tasks = tasks.filterIt(it.priority == 0 or it.priority <= maxPrio)
    elif not opts.showDone:
      tasks = tasks.filterIt(it.priority == 0 or it.priority <= 5)

  # Calendar filter (always applies)
  if opts.hasCal:
    tasks = tasks.filterIt(it.calendarName == opts.calName)

  # Tag filter (always applies)
  if opts.hasTags and opts.tags.len > 0:
    let filterTags = opts.tags.toHashSet
    tasks = tasks.filterIt(it.categories.anyIt(it in filterTags))

  # Sort
  case opts.sortField
  of "due", "d":
    tasks.sort(proc(a, b: Task): int =
      result = cmp(sortDue(a.due), sortDue(b.due))
      if result == 0:
        result = cmp(sortPriority(a.priority), sortPriority(b.priority))
    )
  of "prio", "p", "priority":
    tasks.sort(proc(a, b: Task): int =
      result = cmp(sortPriority(a.priority), sortPriority(b.priority))
      if result == 0:
        result = cmp(sortDue(a.due), sortDue(b.due))
    )
  of "created", "c":
    tasks.sort(proc(a, b: Task): int =
      let aTime = if a.created.isSome: a.created.get.toTime.toUnix else: 0'i64
      let bTime = if b.created.isSome: b.created.get.toTime.toUnix else: 0'i64
      cmp(aTime, bTime)
    )
  else:
    # Default: priority then due
    tasks.sort(proc(a, b: Task): int =
      result = cmp(sortPriority(a.priority), sortPriority(b.priority))
      if result == 0:
        result = cmp(sortDue(a.due), sortDue(b.due))
    )

  displayList(tasks)
  if tasks.len == 0: quit(1)

proc cmdDone(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td done <id> [id...]", 1)

  var allTasks = loadAllTasks()
  for arg in args:
    var taskId: int
    try: taskId = parseInt(arg)
    except ValueError:
      stderr.writeLine("Invalid task ID: " & arg)
      continue
    let idx = findTask(allTasks, taskId)
    if idx < 0:
      stderr.writeLine("Task not found: " & $taskId)
      continue
    var task = allTasks[idx]
    task.status = tsCompleted
    task.percentComplete = 100
    task.completed = some(now().utc)
    task.sequence += 1
    task.lastModified = some(now().utc)
    writeFile(task.filePath, toIcs(task))
    discard

proc cmdCancel(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td cancel <id> [id...]", 1)

  var allTasks = loadAllTasks()
  for arg in args:
    var taskId: int
    try: taskId = parseInt(arg)
    except ValueError:
      stderr.writeLine("Invalid task ID: " & arg)
      continue
    let idx = findTask(allTasks, taskId)
    if idx < 0:
      stderr.writeLine("Task not found: " & $taskId)
      continue
    var task = allTasks[idx]
    task.status = tsCancelled
    task.sequence += 1
    task.lastModified = some(now().utc)
    writeFile(task.filePath, toIcs(task))
    discard

proc cmdDelete(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td delete <id> [id...]", 1)

  var allTasks = loadAllTasks()
  let trashDir = tdPath / ".trash"

  for arg in args:
    var taskId: int
    try: taskId = parseInt(arg)
    except ValueError:
      stderr.writeLine("Invalid task ID: " & arg)
      continue
    let idx = findTask(allTasks, taskId)
    if idx < 0:
      stderr.writeLine("Task not found: " & $taskId)
      continue
    let task = allTasks[idx]
    createDir(trashDir)
    let trashPath = trashDir / extractFilename(task.filePath)
    moveFile(task.filePath, trashPath)
    discard

proc cmdFind(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td find <query>", 1)

  let query = args.join(" ").toLowerAscii
  var tasks = loadAllTasks()

  tasks = tasks.filterIt(
    it.summary.toLowerAscii.contains(query) or
    it.description.toLowerAscii.contains(query) or
    it.categories.anyIt(it.toLowerAscii.contains(query))
  )

  # Sort: active first, then by priority
  tasks.sort(proc(a, b: Task): int =
    let aActive = if a.status in {tsNeedsAction, tsInProcess}: 0 else: 1
    let bActive = if b.status in {tsNeedsAction, tsInProcess}: 0 else: 1
    result = cmp(aActive, bActive)
    if result == 0:
      result = cmp(sortPriority(a.priority), sortPriority(b.priority))
    if result == 0:
      result = cmp(sortDue(a.due), sortDue(b.due))
  )

  displayList(tasks)
  if tasks.len == 0: quit(1)

proc cmdShow(args: seq[string]) =
  if args.len == 0:
    quit("Usage: td show <id>", 1)

  var taskId: int
  try: taskId = parseInt(args[0])
  except ValueError: quit("Invalid task ID: " & args[0], 1)

  var allTasks = loadAllTasks()
  let idx = findTask(allTasks, taskId)
  if idx < 0:
    quit("Task not found: " & $taskId, 1)

  displayDetail(allTasks[idx])

# --- Usage ---

proc usage() =
  echo """td """ & Version & """ - Task manager for ICS/vdirsyncer

Usage:
  td [command] [options]

Commands:
  add, new              Add a new task
  edit, mod, modify     Edit an existing task
  list, ls              List tasks (default)
  done, do              Mark task(s) as completed
  cancel                Cancel task(s)
  find, search          Full text search across all tasks
  delete, del, rm       Delete task(s) (moves to trash)
  show, view            Show task details

Add/Edit options:
  -d, --due DATE        Due date (today, tomorrow, +3d, +1w, 2026-04-01)
  -p, --priority P      Priority (high, medium, low, none)
  -n, --note TEXT       Description/notes
  -t, --tag TAG         Category (repeatable)
  -a, --alarm MIN       Alarm N minutes before due (repeatable)
  -c, --calendar CAL    Calendar name

List options:
  -a, --all             Show all tasks (overrides filters)
  -d, --due DATE        Filter: show tasks due by DATE
  -p, --priority P      Filter: minimum priority to show
  -c, --calendar CAL    Filter: calendar name
  -t, --tag TAG         Filter: category
  -s, --sort FIELD      Sort by: due/d, prio/p, created/c
  --done                Show completed/cancelled tasks

Edit: use empty string to clear a field (e.g., -d "" clears due date)

Global:
  -v, --version         Show version
  -h, --help            Show this help"""

# --- Main ---

proc main() =
  useColor = not existsEnv("NO_COLOR") and isatty(stdout)

  loadEnvFile(".env")
  tdPath = expandTilde(getEnv("TD_PATH", "~/.local/var/lib/vdirsyncer/calendars"))
  defaultCal = getEnv("TD_CALENDAR", "")
  dataDir = expandTilde(getEnv("XDG_DATA_HOME", "~/.local/share")) / "td"

  let params = commandLineParams()

  for p in params:
    if p in ["-v", "--version"]:
      echo "td " & Version
      quit(0)
    if p in ["-h", "--help"]:
      usage()
      quit(0)

  var subcmd = "list"
  var cmdArgs: seq[string]

  if params.len > 0:
    let first = params[0]
    case first
    of "add", "new": subcmd = "add"; cmdArgs = params[1 ..^ 1]
    of "edit", "mod", "modify": subcmd = "edit"; cmdArgs = params[1 ..^ 1]
    of "list", "ls": subcmd = "list"; cmdArgs = params[1 ..^ 1]
    of "done", "do": subcmd = "done"; cmdArgs = params[1 ..^ 1]
    of "cancel": subcmd = "cancel"; cmdArgs = params[1 ..^ 1]
    of "find", "search": subcmd = "find"; cmdArgs = params[1 ..^ 1]
    of "delete", "del", "rm", "remove": subcmd = "delete"; cmdArgs = params[1 ..^ 1]
    of "show", "view": subcmd = "show"; cmdArgs = params[1 ..^ 1]
    else:
      # Bare number = show shortcut
      try:
        discard parseInt(first)
        subcmd = "show"
        cmdArgs = params
      except ValueError:
        subcmd = "list"
        cmdArgs = params

  case subcmd
  of "add": cmdAdd(cmdArgs)
  of "edit": cmdEdit(cmdArgs)
  of "list": cmdList(cmdArgs)
  of "done": cmdDone(cmdArgs)
  of "cancel": cmdCancel(cmdArgs)
  of "find": cmdFind(cmdArgs)
  of "delete": cmdDelete(cmdArgs)
  of "show": cmdShow(cmdArgs)
  else: usage(); quit(1)

main()
