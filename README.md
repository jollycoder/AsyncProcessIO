# AsyncProcessIO

Non-blocking process I/O for AutoHotkey v2 — spawn child processes and read their stdout/stderr asynchronously via overlapped named pipes, without blocking the AHK thread.

## Features

- Asynchronous stdout and stderr reading via overlapped I/O + system thread pool
- Synchronous stdin writing
- Text mode with automatic UTF-8 boundary fixing
- Raw (binary) mode for stdout — data delivered as `Buffer` objects
- Shared silence timeout across both streams
- Accumulation mode (no callback) — collect all output, read when done
- `AsyncStdinReader` for the child side — read inherited stdin asynchronously
- `AsyncWait` as a standalone utility — marshal any thread-pool wait to the AHK GUI thread

## Requirements

AutoHotkey v2.0+

## Files

| File | Description |
|------|-------------|
| `AsyncWait.ahk` | Standalone: thread-pool wait → GUI thread marshalling via `PostMessageW` |
| `AsyncProcessIO.ahk` | Process I/O library; includes `AsyncWait.ahk` automatically |

## Installation

Copy both files to your project and include the one you need:

```ahk
#Include AsyncProcessIO.ahk   ; includes AsyncWait.ahk automatically
; or, for AsyncWait alone:
#Include AsyncWait.ahk
```

## Quick start

### Accumulation mode — collect all output

```ahk
#Include <AsyncProcessIO>

proc := AsyncProcessIO('ping google.com')

; Wait for both streams to complete
while !proc.complete {
    Sleep 50
}
Sleep 50
state := Map(0, 'running', 1, 'completed', -1, 'timed out')[proc.state]
MsgBox 'state: '    . state        . '`n`n'
     . 'outData:`n' . proc.outData . '`n`n'
     . 'outSize: '  . proc.outSize
```

### Callback mode — process data as it arrives

```ahk
#Include AsyncProcessIO.ahk
Persistent

proc := AsyncProcessIO('powershell -Command Get-Process', OnData)

OnData(pid, data, state, stream) {
    static streams := Map(0, 'stdout', 1, 'stderr')
    if state = -1 {
        MsgBox 'Timed out'
        ExitApp
    }
    OutputDebug streams[stream] ': ' data
    if state = 1 {
        OutputDebug 'Stream ' streams[stream] ' completed`n'
    }
    if proc.complete {
        SetTimer () => ExitApp(), -50
    }
}
```

### Writing to stdin

```ahk
#Include AsyncProcessIO.ahk

proc := AsyncProcessIO('powershell -NoProfile -Command -',,, 'UTF-8')
proc.WriteText('Write-Output "hello from powershell"' . '`n')
proc.CloseStdIn()

while !proc.complete
    Sleep 50

MsgBox proc.outData
```

### Raw (binary) mode

Demonstrates transferring a binary file through a pipe. The child script reads the file and writes raw bytes to stdout; the parent receives them as `Buffer` chunks.

**`parent.ahk`:**
```ahk
#Requires AutoHotkey v2
#Include AsyncProcessIO.ahk
Persistent

outFile := FileOpen('output.bin', 'w')
proc := AsyncProcessIO(
    '"' A_AhkPath '" child.ahk "C:\Windows\System32\notepad.exe"',
    OnChunk, 5000, , true)

OnChunk(pid, buf, state, stream) {
    if stream = 0 && buf.Size > 0
        outFile.RawWrite(buf)
    if state = -1
        MsgBox 'Timed out'
    if proc.complete {
        outFile.Close()
        MsgBox 'Done'
        SetTimer () => ExitApp(), -50
    }
}
```

**`child.ahk`:**
```ahk
#Requires AutoHotkey v2

buf := FileRead(A_Args[1], 'RAW')
stdout := FileOpen('*', 'w')
stdout.RawWrite(buf)
stdout.Close()
```

### Timeout

The timeout is a shared silence timer across both stdout and stderr. It fires if neither stream delivers data for the specified number of milliseconds.

```ahk
#Requires AutoHotkey v2
#Include AsyncProcessIO.ahk
Persistent

proc := AsyncProcessIO('cmd /c pause', OnData, 3000)

OnData(pid, data, state, stream) {
    if state = -1 {
        MsgBox 'No output for 3 seconds'
        SetTimer () => ExitApp(), -50
    }
}
```

### AsyncStdinReader — child process side

Use this in a child AHK script to read its own stdin asynchronously. The parent must pass `stdinOverlapped := true` to `AsyncProcessIO`.

Note that chunk boundaries are not guaranteed to align with `WriteText` calls — two consecutive writes may arrive as a single chunk, or one write may be split across multiple chunks, depending on pipe buffer state and scheduling.

**Parent script:**
```ahk
#Include AsyncProcessIO.ahk
Persistent

proc := AsyncProcessIO('"' A_AhkPath '" child.ahk', OnData, , , , true)
proc.WriteText('hello`n')
proc.WriteText('world`n')
proc.CloseStdIn()

OnData(pid, data, state, stream) {
    if stream = 0 && data != ''
        OutputDebug 'Child stdout: ' data
    if proc.complete
        SetTimer () => ExitApp(), -50
}
```

**Child script (`child.ahk`):**
```ahk
#Include AsyncProcessIO.ahk
Persistent

reader := AsyncStdinReader(OnStdin, 'utf-8')

OnStdin(data, state) {
    FileAppend data, '*'   ; echo to stdout
    if state = 1           ; EOF
        ExitApp
}
```

## API Reference

### AsyncProcessIO

```ahk
proc := AsyncProcessIO(cmd, callback?, timeout?, encoding?, raw?, stdinOverlapped?)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `cmd` | String | — | Command line to execute |
| `callback` | Func | — | Called on each data chunk; omit to use accumulation mode |
| `timeout` | Integer | — | Silence timeout in ms; omit for no timeout |
| `encoding` | String | system OEM | Text encoding, e.g. `'utf-8'`, `'cp1252'` |
| `raw` | Boolean | `false` | Deliver stdout as `Buffer` instead of string |
| `stdinOverlapped` | Boolean | `false` | Create stdin pipe with `FILE_FLAG_OVERLAPPED` (required for `AsyncStdinReader` in the child) |

**Callback signature:**
```ahk
callback(pid, data, state, stream)
;   pid    — child process ID
;   data   — String (text mode) or Buffer (raw mode)
;   state  — 0 (data), 1 (stream completed), -1 (timed out)
;   stream — 0 (stdout), 1 (stderr)
```

**Properties:**

| Property | Description |
|----------|-------------|
| `proc.processID` | Child process ID |
| `proc.complete` | `true` when both stdout and stderr are fully drained |
| `proc.state` | Aggregate completion state: `0` running, `1` both streams reached EOF, `-1` at least one timed out |
| `proc.outState` | stdout completion state: `0` running, `1` EOF, `-1` timed out |
| `proc.errState` | stderr completion state: `0` running, `1` EOF, `-1` timed out |
| `proc.outData` | Accumulated stdout (text mode: String, raw mode: Buffer) |
| `proc.errData` | Accumulated stderr (always String) |
| `proc.outSize` | Byte count (raw) or string length (text) of accumulated stdout |
| `proc.errSize` | String length of accumulated stderr |

**Methods:**

```ahk
proc.WriteText(str)        ; write a string to stdin; returns bytes written
proc.WriteData(buf, size?) ; write raw bytes to stdin; returns bytes written
proc.CloseStdIn()          ; close stdin write end, sending EOF to child
```

---

### AsyncStdinReader

```ahk
reader := AsyncStdinReader(callback, encoding?, raw?)
```

Reads the child process's inherited stdin asynchronously. Requires the parent to have set `stdinOverlapped := true`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `callback` | Func | — | Called on each data chunk |
| `encoding` | String | system OEM | Text encoding |
| `raw` | Boolean | `false` | Deliver data as `Buffer` instead of string |

**Callback signature:**
```ahk
callback(data, state)
;   data  — String (text mode) or Buffer (raw mode)
;   state — 0 (data incoming), 1 (EOF)
```

---

### AsyncWait

Standalone utility. Wraps `RegisterWaitForSingleObject` to safely deliver thread-pool callbacks to the AHK GUI thread. Works with any waitable kernel object: overlapped I/O events, process/thread handles, semaphores, mutexes.

```ahk
#Include AsyncWait.ahk

; Wait for a process to exit
hProcess := DllCall('OpenProcess', 'UInt', 0x100000, 'Int', false, 'UInt', pid, 'Ptr')

wait := AsyncWait.Register(hProcess, (handle, timedOut) => (
    MsgBox timedOut ? 'Timed out' : 'Process exited'
))

; Cancel before it fires (optional):
; wait.Unregister()
```

```ahk
AsyncWait.Register(handle, callback, flags?, timeout?, completionEvent?)
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `handle` | — | Waitable kernel object handle |
| `callback` | — | `callback(handle, timedOut)` called on the GUI thread |
| `flags` | `WT_EXECUTEONLYONCE` | `RegisterWaitForSingleObject` flags |
| `timeout` | `-1` (INFINITE) | Timeout in ms |
| `completionEvent` | `-1` | `-1` blocks until callback completes; `0` returns immediately |

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed explanation of the async mechanism, protective mechanisms (watchdog, generation counters, sentinel pattern), UTF-8 boundary fixing, memory management, and design decisions.

## License

MIT © jollycoder
