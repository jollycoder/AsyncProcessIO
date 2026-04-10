# AsyncProcessIO — Architecture & Design Decisions

## Overview

The project is split into two files:

- **`AsyncWait.ahk`** — standalone library: marshals system thread-pool callbacks to the AHK GUI thread via `PostMessageW`. Has no dependencies and can be used independently.
- **`AsyncProcessIO.ahk`** — process I/O library; includes `AsyncWait.ahk`. Contains three classes:
  - **AsyncProcessIO** — parent mode: spawn a child process, read stdout/stderr asynchronously, write stdin synchronously.
  - **AsyncStdinReader** — child mode: read inherited stdin asynchronously.
  - **StreamReader** — shared engine for async pipe reading (used by both above).

## Core async mechanism

### Why RegisterWaitForSingleObject + PostMessageW

AHK v2 is single-threaded with a message-pumping event loop. Overlapped I/O completes on a kernel thread, but AHK objects can only be touched from the GUI thread. The pipeline is:

1. `ReadFile` with OVERLAPPED → kernel signals `hEvent` when data is ready.
2. `RegisterWaitForSingleObject` watches `hEvent` from the system thread pool.
3. Thread-pool callback (a shellcode thunk) calls `PostMessageW` to marshal into the GUI thread.
4. `OnMessage` handler dispatches to the AHK callback.

An alternative is IOCP via `BindIoCompletionCallback` + `SendMessageW` (as in thqby's `child_process`). `SendMessageW` is synchronous and can't lose messages, eliminating the need for watchdog and generation counters. However, it blocks the thread-pool thread until the GUI thread processes the message. The `PostMessageW` approach was chosen to avoid blocking the thread pool, at the cost of needing protective mechanisms described below.

### Why named pipes instead of anonymous pipes

Anonymous pipes (`CreatePipe`) don't support `FILE_FLAG_OVERLAPPED`. Named pipes (`CreateNamedPipe` + `CreateFile`) do. Overlapped reads are essential — without them, `ReadFile` blocks the only AHK thread.

### Why stdin is synchronous

The child's stdin read end must NOT be overlapped. Child processes (cmd.exe, python, powershell) call `ReadFile` with a NULL OVERLAPPED pointer, which is undefined behaviour on an overlapped handle (MSDN KB 156932). The parent's write end is also synchronous — `WriteFile` blocks until the child reads, which is acceptable for interactive input.

## Protective mechanisms

### Watchdog timer

**Problem:** Under heavy I/O (e.g. `dir /s` of a large directory), the thread-pool callback fires `PostMessageW` hundreds of times per second. The Windows message queue has a limit (~10,000 messages), and if the GUI thread can't keep up (busy with `SetTimer` callbacks, Edit control updates), `PostMessageW` silently returns FALSE. The message is lost, `_onSignal` never fires, the next `ReadFile` is never issued — the stream hangs.

**Solution:** A watchdog timer checks `OVERLAPPED.Internal`: if it's no longer `STATUS_PENDING` (0x103), the I/O completed but the signal was lost. The watchdog calls `_onSignal` directly to recover.

The watchdog closure is created once in `StreamReader.__New` and reused via `SetTimer(fn, -500)` on each `_registerWait`. This avoids allocating a new closure per read cycle — a significant optimization when hundreds of reads happen per second.

The 500ms interval is a balance: low enough that a lost message causes only a brief visible pause, high enough that the overhead is negligible (one `NumGet` check).

#### Watchdog false-positive fix

**Problem:** Under heavy I/O, the watchdog fires while a new `_registerWait` cycle is already in progress. The previous `ReadFile` completed normally, `_onSignal` was called, a new `ReadFile` was issued — but the watchdog timer from the previous cycle fires 500ms later, sees `OVERLAPPED.Internal != STATUS_PENDING` (the *new* ReadFile already completed), and calls `_onSignal` a second time, duplicating data delivery.

**Fix:** `_watchdogGen` is set to the current `_gen` on each `_registerWait`. In `_watchdogTick`, if `_gen != _watchdogGen`, the normal callback already advanced the generation counter — the watchdog exits silently.

### Generation counters

**Problem:** When `_registerWait` creates a new `RegisteredWait`, the old one is overwritten and destroyed. But `UnregisterWaitEx` with `completionEvent=0` (NULL) returns immediately — the old thread-pool callback may still be in flight. If it arrives after the new wait is registered, two `_onSignal` calls happen for the same stream, corrupting state (double `ReadFile`, double `GetOverlappedResult`).

**Solution:** Each `_registerWait` bumps `_gen` and captures the current value in the closure. The callback checks `obj._gen = gen` — if the generation doesn't match, the callback is stale and silently exits.

#### _complete flag ordering in _processData

`_complete := true` must be set **before** `SetTimer` in `_processData`. Setting it after creates a window where a stale callback can pass the `if this._complete` guard in `_onSignal` before the flag is raised, causing a duplicate `_drainRaw` call.

### Sentinel (weak reference pattern)

**Problem:** The closure passed to `RegisterWaitForSingleObject` captures `ObjPtr(this)` — a raw pointer, not a reference. If the `StreamReader` is destroyed before the closure fires, `ObjFromPtrAddRef` would dereference a dangling pointer.

**Solution:** A separate `{alive: true}` object is captured alongside the raw pointer. `__Delete` sets `alive := false`. The closure checks `sentinel.alive` before attempting `ObjFromPtrAddRef`. The sentinel is a distinct object that remains valid even after the `StreamReader` is gone — its reference is held by the closure itself.

### Why completionEvent = 0 (not -1) in _registerWait

`RegisteredWait.Unregister()` calls `UnregisterWaitEx(wh, completionEvent)`. The default is `-1` (INVALID_HANDLE_VALUE), which blocks until the callback completes — safe in general use. But `_registerWait` passes `completionEvent=0` (NULL) for non-blocking unregistration. This is necessary because the old `RegisteredWait` is destroyed inside `_registerWait` (overwritten by the new one), which is itself called from `_onSignal` — blocking here would deadlock if the thread-pool callback hasn't returned yet.

The generation counter protects against the resulting race condition (stale callback arriving after the new wait is registered).

For standalone use of `AsyncWait`, the default `-1` is safer and should be preferred.

## UnregisterWaitEx — the main memory leak fix

**Problem (original bug):** `RegisteredWait.Unregister()` originally skipped `UnregisterWaitEx` when `fired = true`, reasoning that a fired wait doesn't need cleanup. But MSDN states: *"Even wait operations that use WT_EXECUTEONLYONCE must be canceled by calling UnregisterWaitEx."* Each `RegisterWaitForSingleObject` allocates an internal kernel structure that is only freed by `UnregisterWaitEx`.

During a `dir /s` of a large directory, hundreds of read cycles occur per second. Each creates a new `RegisteredWait`, the old one fires and is destroyed, and `Unregister()` skips `UnregisterWaitEx` because `fired = true`. Kernel wait objects accumulate — ~0.2 MB per run, scaling with data volume.

**Fix:** Always call `UnregisterWaitEx`, regardless of whether the callback has fired. For a fired `WT_EXECUTEONLYONCE` wait, `UnregisterWaitEx` simply frees the kernel structure and returns immediately.

The `fired` field was removed entirely — it served no other purpose.

## Raw (binary) mode

### Why raw applies only to stdout

stderr is a diagnostic channel — error messages, warnings, progress. No real-world program writes binary data to stderr. Making `raw` per-stream would double every `if raw` check into `if (stream = 0 ? rawStdout : rawStderr)` for zero practical benefit.

### Accumulation in no-callback mode

In text mode, `outData` is a string built with `.=` concatenation. In raw mode, `outData` is a `Buffer` with amortized doubling (`_appendRaw`): when capacity is exceeded, a new buffer 2× larger is allocated and data is copied. `outPos` tracks the write position; `outSize` returns `outPos` (not `buf.Size`).

When a callback is supplied, the class does not accumulate — data is delivered per-chunk, and `outData`/`errData` remain empty.

## UTF-8 boundary fixing

### The problem

`ReadFile` splits data at buffer boundaries, which can fall in the middle of a multi-byte UTF-8 character (2–4 bytes). `StrGet` on a truncated sequence produces U+FFFD or corrupted output.

### The approach

After each `ReadFile`, `_fixBoundary` scans the last 1–4 bytes of the buffer for an incomplete UTF-8 sequence (`_utf8Tail`). Incomplete bytes are saved in a 4-byte carry buffer. Before the next `StrGet`, carry bytes are prepended to the new data.

**Why not a universal multi-byte decoder:** An alternative approach (used in thqby's `TextStreamDecoder`) detects splits by calling `MultiByteToWideChar` in a loop and checking for U+FFFD. This works with any multi-byte encoding (Shift-JIS, GB2312, Big5). However, for console I/O on Windows, the only practical multi-byte encoding is UTF-8 — OEM codepages (cp866, cp437) are single-byte, UTF-16 is rare. The manual UTF-8 tail scan is simpler, faster, and sufficient.

**Optimization:** Tail scanning is skipped when `ReadFile` returns fewer bytes than requested (`size < buf.Size - 4`), because a partial read means the kernel delivered all available data and the sequence is intact. Carry prepend is only needed after a full-buffer read.

When the stream completes (pipe closed), `_flushCarry` decodes any remaining carry bytes — these represent a truncated character at the very end of the stream (the child wrote an incomplete UTF-8 sequence before exiting).

## Two-phase cleanup

### The problem

`AsyncProcessIO` owns two `StreamReader`s (stdout + stderr). Each has a pending `RegisterWaitForSingleObject` and possibly in-flight `PostMessageW` messages. Cleaning up one at a time with `Sleep 50` each would take 100ms minimum.

### The solution

1. `prepareDelete()` on both: poison sentinel, cancel IO, signal events.
2. `Sleep 50` once: let any in-flight PostMessageW arrive; sentinel prevents execution.
3. `finishDelete()` on both: `Unregister()` the thread-pool waits.

`AsyncStdinReader` has only one `StreamReader`, so it uses `prepareDelete` + `Sleep 50` + `finishDelete` directly.

`StreamReader.__Delete` handles the standalone case: if `prepareDelete` wasn't called (no coordinated cleanup), it runs the full sequence itself.

## stdinOverlapped — AsyncStdinReader compatibility

`AsyncStdinReader` requires an overlapped handle on stdin. The natural fix would be `ReOpenFile` with `FILE_FLAG_OVERLAPPED` on the existing handle — but this fails with `ERROR_INVALID_PARAMETER` on named pipes: Windows does not allow changing the overlapped flag on a pipe handle after creation.

The correct fix is the `stdinOverlapped` parameter on `AsyncProcessIO`. When `true`, `hInPipeRead` is created with `FILE_FLAG_OVERLAPPED` from the start via `_createChildEnd`. The child process inherits this handle as `STD_INPUT_HANDLE`, and `GetStdHandle(STD_INPUT_HANDLE)` in `AsyncStdinReader` returns an already-overlapped handle — no `ReOpenFile` needed.

This parameter must remain `false` (the default) for any child process that reads stdin with a NULL OVERLAPPED pointer (cmd.exe, python, powershell etc.) — passing an overlapped handle to such a process is undefined behaviour (MSDN KB 156932).

## Pipe naming and collisions

Pipe names include `A_TickCount` for uniqueness across time. A static counter `_pipeId` is appended to handle the case where multiple `AsyncProcessIO` instances are created within the same millisecond tick. The three pipes within one instance (stdout/stderr/stdin) use different prefixes (`StdOut_`/`StdErr_`/`StdIn_`), so they share the same tick+id suffix safely.

## hProcess / hThread from CreateProcess

`CreateProcess` returns `hProcess` and `hThread` in `PROCESS_INFORMATION`. These must be explicitly closed — they are kernel handles with reference-counted lifetime. The original code only extracted `dwProcessId` and let the `PROCESS_INFORMATION` buffer go out of scope, leaking two handles per process launch. This was a constant leak (~few KB per run), independent of data volume.

`ProcessClose(pid)` in `__Delete` does NOT fix this: it opens a new handle via `OpenProcess`, terminates the process, and closes its own handle — the original handles from `CreateProcess` remain leaked.

## Callback re-entrancy under heavy I/O

Each data chunk is delivered to the user callback via `SetTimer(..., -10)`. Under heavy I/O,
multiple `SetTimer` calls may be queued before the first one executes. When the first callback
runs, it pumps the AHK message loop internally (e.g. via `SendMessage` for `EditPaste`, or via
`Sleep`). This allows a queued callback to fire before the first one has returned — re-entrant
execution of the same callback function.

This is harmless for stateless callbacks (simple GUI updates, logging). But if the callback
maintains state across calls — a carry buffer for incomplete lines, counters, accumulators —
re-entrant execution corrupts that state: the second call sees the carry from the middle of the
first call's processing.

**Solution:** Serialize execution with an in-memory queue:

```ahk
OnData(pid, str, state, stream) {
    static queue := []
    queue.Push({str: str, state: state, stream: stream})
    if queue.Length > 1
        return  ; re-entrant call — will be processed by the active loop
    while queue.Length {
        item := queue[1]
        _processChunk(item.str, item.state, item.stream)
        queue.RemoveAt(1)
    }
}
```

The active call drains the queue to completion before returning. Re-entrant calls push to the
queue and return immediately — their data is processed in order by the already-active loop.
This pattern is only needed when the callback maintains mutable state shared across calls.