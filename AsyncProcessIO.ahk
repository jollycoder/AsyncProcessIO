#Requires AutoHotkey v2

; =============================================================================
; AsyncProcessIO   — spawn a child process with async stdout/stderr reading
;                    and synchronous stdin writing.
; AsyncStdinReader — read inherited stdin asynchronously in a child process.
; StreamReader     — shared engine for async pipe reading (used by both above).
; AsyncWait        — thread-pool wait → GUI thread marshalling via PostMessageW.
;
; Version: 1.0.0
; Date:    2026-04-10
; Forum:   https://www.autohotkey.com/boards/viewtopic.php?f=83&t=122732
; =============================================================================

class AsyncProcessIO
{
    /**
     * Spawns a child process, reads its stdout and stderr asynchronously
     * without blocking the AHK thread, and allows writing to stdin synchronously.
     *
     * cmd:      command line of the process to create.
     * callback: function called when a new data chunk arrives on stdout or stderr.
     *           Text mode: callback(PID, str, state, stream)
     *           Raw mode:  callback(PID, buf, state, stream)
     *               state  — 0 (data incoming), 1 (completed), -1 (timed out)
     *               stream — 0 (stdout), 1 (stderr)
     *           When no callback is supplied, data is accumulated in outData/errData.
     * timeout:  max milliseconds of silence on both streams before firing state=-1.
     *           The timer is shared: any data on either stream resets it.
     * encoding: text encoding for stdin/stdout/stderr; defaults to system OEM codepage.
     *           In raw mode, encoding is only used by WriteText.
     * raw:      when true, stdout is delivered as raw Buffer objects instead of
     *           decoded strings; UTF-8 boundary fixing is skipped.
     *           stderr is always delivered as decoded text regardless of this flag.
     */

    static BUF_STDOUT_SIZE := 0x10000
         , BUF_STDERR_SIZE := 0x01000

    __New(cmd, callback?, timeout?, encoding?, raw?, stdinOverlapped := false) {
        raw      := raw      ?? false
        encoding := encoding ?? 'cp' . DllCall('GetOEMCP')
        this._raw       := raw
        this._encoding  := encoding
        this._startTime := A_TickCount
        if IsSet(callback)
            this._callback := callback
        if IsSet(timeout)
            this._timeout  := timeout

        ; Accumulation buffers (no-callback mode)
        this._outData := raw ? Buffer(AsyncProcessIO.BUF_STDOUT_SIZE) : ''
        this._errData := ''
        this._outPos  := 0
        this._outState := 0
        this._errState := 0

        this.hEvent    := DllCall('CreateEvent', 'Int', 0, 'Int', 0, 'Int', 0, 'Int', 0, 'Ptr')
        this.hEventErr := DllCall('CreateEvent', 'Int', 0, 'Int', 0, 'Int', 0, 'Int', 0, 'Ptr')

        stdoutBuf := Buffer(AsyncProcessIO.BUF_STDOUT_SIZE, 0)
        stderrBuf := Buffer(AsyncProcessIO.BUF_STDERR_SIZE, 0)

        this.process := AsyncProcessIO.Process(cmd, stdoutBuf.Size, stderrBuf.Size, stdinOverlapped)

        t := this.HasProp('_timeout') ? this._timeout : -1
        this._stdout := StreamReader(
            this.process.hPipeRead, this.hEvent, stdoutBuf,
            ObjBindMethod(this, '_streamCallback', 0), encoding, raw, t)
        this._stderr := StreamReader(
            this.process.hPipeReadErr, this.hEventErr, stderrBuf,
            ObjBindMethod(this, '_streamCallback', 1), encoding, false, t)

        this._stdout.start()
        this._stderr.start()
    }

    processID => this.process.PID

    ; True only when both stdout and stderr are fully drained
    complete => this._stdout.complete && this._stderr.complete

    ; Per-stream completion state: 0 = running, 1 = EOF, -1 = timed out
    outState => this._outState
    errState => this._errState

    ; Aggregate state: -1 if any stream timed out, 1 if both reached EOF, 0 otherwise
    state => (this._outState = -1 || this._errState = -1) ? -1
           : (this._outState =  1 && this._errState =  1) ?  1 : 0

    outData  => this._outData
    errData  => this._errData

    ; Byte count of accumulated data in raw mode; string length in text mode
    outSize  => this._raw ? this._outPos : StrLen(this._outData)
    errSize  => StrLen(this._errData)

    /**
     * Write a text string to the child's stdin.
     * Encoding matches the one supplied to the constructor.
     * The null terminator is never sent to the child.
     * Returns the number of bytes actually written.
     */
    WriteText(str) {
        byteCount := StrPut(str, this._encoding)
        buf := Buffer(byteCount)
        StrPut(str, buf, this._encoding)
        return this.WriteData(buf, byteCount - (InStr(this._encoding, '16') ? 2 : 1))
    }

    /**
     * Write raw bytes to the child's stdin.
     * size defaults to buf.Size if omitted.
     * Returns the number of bytes actually written.
     */
    WriteData(buf, size?) {
        if !IsSet(size)
            size := buf.Size
        DllCall('WriteFile', 'Ptr', this.process.hInPipeWrite,
                             'Ptr', buf, 'UInt', size,
                             'UIntP', &written := 0, 'Ptr', 0)
        return written
    }

    /**
     * Close the write end of stdin, sending EOF to the child.
     * Call this when no more input will be written.
     */
    CloseStdIn() {
        if this.process.hInPipeWrite {
            DllCall('CloseHandle', 'Ptr', this.process.hInPipeWrite)
            this.process.hInPipeWrite := 0
        }
    }

    ; -------------------------------------------------------------------------

    ; Callback bound to each StreamReader via ObjBindMethod.
    ; Prepends PID and stream index, dispatches to user callback or accumulates.
    _streamCallback(stream, data, state) {
        if state = -1 {
            this._handleTimeout(stream)
            return
        }
        this._startTime := A_TickCount
        if state = 1 {
            if stream = 0
                this._outState := 1
            else
                this._errState := 1
        }
        if this.HasProp('_callback') {
            SetTimer(this._callback.Bind(this.process.PID, data, state, stream), -10)
            return
        }
        ; No-callback mode: accumulate
        if stream = 0 {
            if this._raw {
                if data.Size > 0
                    this._appendRaw(data)
            } else if data != ''
                this._outData .= data
        } else if data != ''
            this._errData .= data
    }

    ; Handle a timeout from one stream. The silence timer is shared across both
    ; streams: any data on either stream resets _startTime. If the other stream
    ; is still active, re-register with a full timeout instead of firing.
    _handleTimeout(stream) {
        reader := stream = 0 ? this._stdout : this._stderr
        if this.HasProp('_timeout') {
            remaining := this._timeout - (A_TickCount - this._startTime)
            if remaining > 0 {
                reader._registerWait(remaining)
                return
            }
        }
        otherDone := stream = 0 ? this._stderr.complete : this._stdout.complete
        if !otherDone && this.HasProp('_timeout') {
            reader._registerWait(this._timeout)
            return
        }
        if stream = 0
            this._outState := -1
        else
            this._errState := -1
        if this.HasProp('_callback') {
            emptyData := (stream = 0 && this._raw) ? Buffer(0) : ''
            SetTimer(this._callback.Bind(this.process.PID, emptyData, -1, stream), -10)
        }
    }

    ; Append a raw Buffer to the stdout accumulation buffer (no-callback, raw mode).
    ; Uses amortized doubling to minimize reallocations.
    _appendRaw(dataBuf) {
        pos  := this._outPos
        buf  := this._outData
        size := dataBuf.Size
        if pos + size > buf.Size {
            newSize := Max(buf.Size * 2, pos + size)
            newBuf  := Buffer(newSize)
            (pos > 0) && DllCall('RtlMoveMemory', 'Ptr', newBuf, 'Ptr', buf, 'Ptr', pos)
            this._outData := newBuf
            buf := newBuf
        }
        DllCall('RtlMoveMemory', 'Ptr', buf.Ptr + pos, 'Ptr', dataBuf, 'Ptr', size)
        this._outPos := pos + size
    }

    __Delete() {
        if !this.HasProp('process')
            return
        pid := this.process.PID
        ; Cancel both streams simultaneously, then wait once for in-flight
        ; PostMessageW callbacks to arrive and be silenced by the sentinel.
        this._stdout.prepareDelete()
        this._stderr.prepareDelete()
        Sleep 50
        this._stdout.finishDelete()
        this._stderr.finishDelete()
        this.process.Clear()
        DllCall('CloseHandle', 'Ptr', this.hEvent)
        DllCall('CloseHandle', 'Ptr', this.hEventErr)
        this._outData := ''
        this._errData := ''
        ProcessClose(pid)
    }

    ; =========================================================================
    class Process
    {
        ; Static counter to avoid pipe name collisions when multiple
        ; instances are created within the same millisecond tick.
        static _pipeId := 0

        __New(cmd, stdoutBufSize, stderrBufSize, stdinOverlapped := false) {
            this.CreatePipes(stdoutBufSize, stderrBufSize, stdinOverlapped)
            if !this.PID := this.CreateProcess(cmd)
                throw OSError('Failed to create process')
        }

        CreatePipes(stdoutBufSize, stderrBufSize, stdinOverlapped := false) {
            static GENERIC_READ := 0x80000000, GENERIC_WRITE := 0x40000000
            id := ++AsyncProcessIO.Process._pipeId

            ; --- stdout: overlapped read, inheritable write ---
            this.hPipeRead := this._createReadPipe(
                pipeName := '\\.\pipe\StdOut_' A_TickCount '_' id, stdoutBufSize)
            this.hPipeWrite := this._createChildEnd(pipeName, GENERIC_WRITE, stdinOverlapped)

            ; --- stderr: overlapped read, inheritable write ---
            this.hPipeReadErr := this._createReadPipe(
                pipeName := '\\.\pipe\StdErr_' A_TickCount '_' id, stderrBufSize)
            this.hErrPipeWrite := this._createChildEnd(pipeName, GENERIC_WRITE, stdinOverlapped)

            ; --- stdin: synchronous write on our side ---
            ; Child's read end must NOT be overlapped: child processes read stdin
            ; with a NULL OVERLAPPED pointer, which is undefined behaviour on an
            ; overlapped handle (MSDN KB 156932).
            this.hInPipeWrite := this._createWritePipe(
                pipeName := '\\.\pipe\StdIn_' A_TickCount '_' id, stdoutBufSize)
            this.hInPipeRead :=  this._createChildEnd(pipeName, GENERIC_READ, stdinOverlapped)
        }

        ; Create the parent's read end of a pipe (overlapped, non-inheritable).
        _createReadPipe(pipeName, bufSize) {
            return DllCall('CreateNamedPipe',
                'Str', pipeName, 'UInt', 0x40000001,  ; PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
                'UInt', 0, 'UInt', 1,
                'UInt', bufSize, 'UInt', bufSize,
                'UInt', 120000, 'Ptr', 0, 'Ptr')
        }

        ; Create the parent's write end of a pipe (synchronous, non-inheritable).
        _createWritePipe(pipeName, bufSize) {
            return DllCall('CreateNamedPipe',
                'Str', pipeName, 'UInt', 0x2,  ; PIPE_ACCESS_OUTBOUND (no overlapped)
                'UInt', 0, 'UInt', 1,
                'UInt', 0, 'UInt', bufSize,
                'UInt', 120000, 'Ptr', 0, 'Ptr')
        }

        ; Open the child-facing end of an existing named pipe (inheritable).
        ; access: GENERIC_READ (0x80000000) or GENERIC_WRITE (0x40000000)
        ; overlapped: whether to open with FILE_FLAG_OVERLAPPED
        _createChildEnd(pipeName, access, overlapped) {
            h := DllCall('CreateFile',
                'Str', pipeName, 'UInt', access,
                'UInt', 0, 'Ptr', 0, 'UInt', 0x3,  ; OPEN_EXISTING
                'UInt', 0x80 | (overlapped ? 0x40000000 : 0),  ; FILE_ATTRIBUTE_NORMAL [| FILE_FLAG_OVERLAPPED]
                'Ptr', 0, 'Ptr')
            DllCall('SetHandleInformation', 'Ptr', h, 'UInt', 1, 'UInt', 1)  ; HANDLE_FLAG_INHERIT
            return h
        }

        CreateProcess(cmd) {
            static STARTF_USESTDHANDLES := 0x100
                 , CREATE_NO_WINDOW     := 0x8000000

            STARTUPINFO := Buffer(siSize := A_PtrSize * 9 + 32, 0)
            NumPut('UInt', siSize,               STARTUPINFO)
            NumPut('UInt', STARTF_USESTDHANDLES, STARTUPINFO, A_PtrSize * 4 + 28)
            NumPut('Ptr', this.hInPipeRead, 'Ptr', this.hPipeWrite, 'Ptr', this.hErrPipeWrite,
                   STARTUPINFO, siSize - A_PtrSize * 3)

            PROCESS_INFORMATION := Buffer(A_PtrSize * 2 + 8, 0)
            if !DllCall('CreateProcess',
                'Ptr', 0, 'Str', cmd, 'Ptr', 0, 'Ptr', 0, 'UInt', true,
                'UInt', CREATE_NO_WINDOW, 'Ptr', 0, 'Ptr', 0,
                'Ptr', STARTUPINFO, 'Ptr', PROCESS_INFORMATION)
                return this.Clear()

            ; Close the parent's copies of child-facing handles immediately after spawn.
            ; Keeping hPipeWrite/hErrPipeWrite open would prevent EOF detection;
            ; keeping hInPipeRead open would leak a handle.
            for h in ['hPipeWrite', 'hErrPipeWrite', 'hInPipeRead']
                DllCall('CloseHandle', 'Ptr', this.%h%), this.%h% := 0

            pid := NumGet(PROCESS_INFORMATION, A_PtrSize * 2, 'UInt')
            DllCall('CloseHandle', 'Ptr', NumGet(PROCESS_INFORMATION, 0, 'Ptr'))           ; hProcess
            DllCall('CloseHandle', 'Ptr', NumGet(PROCESS_INFORMATION, A_PtrSize, 'Ptr'))   ; hThread
            return pid
        }

        Clear() {
            for h in ['hPipeRead', 'hPipeReadErr', 'hPipeWrite',
                      'hErrPipeWrite', 'hInPipeWrite', 'hInPipeRead']
                (this.%h%) && DllCall('CloseHandle', 'Ptr', this.%h%)
        }
    }
}

; =============================================================================
class AsyncStdinReader
{
    /**
     * Reads inherited stdin asynchronously without blocking the AHK thread.
     * Intended for use in child processes spawned via AsyncProcessIO.
     *
     * The parent writes to stdin via AsyncProcessIO.WriteText / WriteData,
     * and this class picks up the data on the child side without blocking.
     *
     * callback: called when a new data chunk arrives on stdin.
     *     Text mode: callback(str, state)
     *         str   — decoded string (empty on EOF)
     *         state — 0 (data incoming), 1 (EOF)
     *     Raw mode:  callback(buf, state)
     *         buf   — Buffer with raw bytes (Buffer(0) on EOF)
     *         state — 0 (data incoming), 1 (EOF)
     * encoding: text encoding for StrGet; defaults to system OEM codepage.
     * raw:      deliver raw Buffer objects instead of decoded strings.
     */

    static BUF_STDIN_SIZE := 0x10000

    __New(callback, encoding?, raw?) {
        encoding := encoding ?? 'cp' . DllCall('GetOEMCP')
        raw      := raw      ?? false

        ; GetStdHandle returns the inherited pipe handle from the parent.
        ; The parent must have created the stdin pipe with FILE_FLAG_OVERLAPPED
        ; (stdinOverlapped := true in AsyncProcessIO) for overlapped reads to work.
        this._hStdin := DllCall('GetStdHandle', 'Int', -10, 'Ptr')  ; STD_INPUT_HANDLE

        this._hEvent := DllCall('CreateEvent', 'Int', 0, 'Int', 0, 'Int', 0, 'Int', 0, 'Ptr')
        buf := Buffer(AsyncStdinReader.BUF_STDIN_SIZE, 0)

        ; No timeout — stdin stays open as long as the parent keeps writing.
        ; The -1 timeout in _onSignal will never fire because StreamReader
        ; passes it to RegisterWaitForSingleObject as INFINITE.
        this._reader := StreamReader(
            this._hStdin, this._hEvent, buf, callback, encoding, raw)
        this._reader.start()
    }

    complete => this._reader.complete

    __Delete() {
        if !this.HasProp('_reader')
            return
        this._reader.prepareDelete()
        Sleep 50
        this._reader.finishDelete()
        DllCall('CloseHandle', 'Ptr', this._hEvent)
    }
}

; =============================================================================
class StreamReader
{
    /**
     * Async reader for a single overlapped pipe. Shared engine used by both
     * AsyncProcessIO (for stdout/stderr) and AsyncStdinReader (for stdin).
     *
     * Does not own any handles — the caller creates and destroys hPipe, hEvent,
     * and buf. This class only manages the OVERLAPPED state, thread-pool waits,
     * and data decoding.
     *
     * hPipe:    overlapped pipe handle to read from.
     * hEvent:   auto-reset event for OVERLAPPED signalling (owned by caller).
     * buf:      read buffer (owned by caller).
     * callback: called on each data chunk or stream event.
     *               Text mode: callback(str, state)
     *               Raw mode:  callback(buf, state)
     *           state: 0 = data incoming, 1 = completed/EOF, -1 = timed out
     * encoding: text encoding for StrGet.
     * raw:      deliver raw Buffer objects instead of decoded strings.
     * timeout:  default wait timeout in ms for RegisterWaitForSingleObject.
     *           -1 = wait indefinitely (INFINITE).
     */
    __New(hPipe, hEvent, buf, callback, encoding, raw, timeout := -1) {
        this._hPipe       := hPipe
        this._hEvent      := hEvent
        this._buf         := buf
        this._callback    := callback
        this._encoding    := encoding
        this._raw         := raw
        this._timeout     := timeout
        this._complete    := false
        this._gen         := 0
        this._watchdogGen := 0
        this._sentinel    := {alive: true}

        this._overlapped := Buffer(A_PtrSize * 3 + 8, 0)
        this._carry      := Buffer(4, 0)
        this._carrySize  := 0

        ; Watchdog closure — created once, reused by SetTimer on each _registerWait.
        ; Captures a weak reference (raw ObjPtr) + sentinel to avoid preventing GC.
        weakPtr  := ObjPtr(this)
        sentinel := this._sentinel
        this._watchdogFn := () => (
            sentinel.alive && (
                obj := ObjFromPtrAddRef(weakPtr),
                obj._watchdogTick()
            )
        )
    }

    complete => this._complete

    ; Begin the first async read.
    start() {
        switch this._issueRead() {
            case  1 : this._registerWait()      ; ASYNC — waiting for kernel signal
            case -1 : this._onSignal(0, false)  ; SYNC  — data already in pipe buffer
            case  0 :                           ; DONE  — pipe already closed
                this._complete := true
                emptyData := this._raw ? Buffer(0) : ''
                SetTimer(this._callback.Bind(emptyData, 1), -10)
        }
    }

    ; -------------------------------------------------------------------------
    ; ReadFile + OVERLAPPED management
    ; -------------------------------------------------------------------------

    ; Issue an overlapped ReadFile on the pipe.
    ; Returns: 1 (ASYNC — kernel will signal hEvent when data is ready),
    ;         -1 (SYNC  — data was already in the pipe buffer),
    ;          0 (DONE  — pipe closed or unrecoverable error).
    _issueRead() {
        static ERROR_IO_PENDING := 997
        ovlp := this._overlapped
        ; Zero the OVERLAPPED fields before reuse; hEvent is set explicitly below.
        DllCall('RtlZeroMemory', 'Ptr', ovlp, 'Ptr', A_PtrSize * 2 + 8)
        ; Reset the event before issuing ReadFile. When ReadFile completes
        ; synchronously it signals hEvent as a side effect; without this reset
        ; that leftover signal would cause _onSignal to fire spuriously.
        DllCall('ResetEvent', 'Ptr', this._hEvent)
        NumPut('Ptr', this._hEvent, ovlp, A_PtrSize * 2 + 8)  ; OVERLAPPED.hEvent
        ; Request buf.Size-4 bytes, leaving headroom for UTF-8 carry prepend.
        res := DllCall('ReadFile', 'Ptr', this._hPipe,
                       'Ptr', this._buf, 'UInt', this._buf.Size - 4,
                       'UIntP', &size := 0, 'Ptr', ovlp)
        switch {
            case res                            : return -1   ; SYNC
            case A_LastError = ERROR_IO_PENDING : return  1   ; ASYNC
            default                             : return  0   ; DONE
        }
    }

    ; -------------------------------------------------------------------------
    ; Thread-pool wait + watchdog
    ; -------------------------------------------------------------------------

    ; Register a one-shot thread-pool wait for the OVERLAPPED event.
    ; Each registration bumps a generation counter; stale callbacks from
    ; previous registrations silently exit when the generation doesn't match.
    _registerWait(timeout?) {
        if !IsSet(timeout)
            timeout := this._timeout
        gen       := ++this._gen
        this._watchdogGen := gen
        weakPtr   := ObjPtr(this)
        sentinel  := this._sentinel
        this._regWait := AsyncWait.Register(this._hEvent,
            (handle, timedOut) => (
                sentinel.alive && (
                    obj := ObjFromPtrAddRef(weakPtr),
                    (obj._gen = gen) && (
                        obj._gen++,
                        obj._onSignal(handle, timedOut)
                    )
                )
            ),
            AsyncWait.WT_EXECUTEONLYONCE, timeout, 0)
        ; Watchdog: recover if PostMessageW is lost (e.g. message queue overflow).
        ; The closure is pre-allocated in __New; SetTimer just resets the countdown.
        SetTimer(this._watchdogFn, -500)
    }

    ; If the overlapped IO completed but PostMessageW was lost,
    ; re-enter _onSignal directly to recover.
    _watchdogTick() {
        if this._complete
            return
        if this._gen != this._watchdogGen  ; normal callback already advanced gen
            return
        ; OVERLAPPED.Internal == STATUS_PENDING (0x103) means IO is still
        ; in progress; any other value means it completed but the signal
        ; was lost (e.g. message queue overflow under heavy IO).
        if NumGet(this._overlapped, 0, 'UPtr') != 0x103 {
            this._gen++
            this._onSignal(0, false)
        }
    }

    ; -------------------------------------------------------------------------
    ; Signal handling
    ; -------------------------------------------------------------------------

    ; Entry point when the OVERLAPPED event fires or watchdog recovers.
    _onSignal(handle, timedOut) {
        if timedOut {
            ; Deliver timeout to caller; for AsyncProcessIO the outer
            ; _streamCallback routes this through _handleTimeout which
            ; checks the shared silence timer before actually firing.
            emptyData := this._raw ? Buffer(0) : ''
            SetTimer(this._callback.Bind(emptyData, -1), -10)
            return
        }
        if !DllCall('GetOverlappedResult', 'Ptr', this._hPipe,
                    'Ptr', this._overlapped, 'UIntP', &size := 0, 'UInt', false) {
            this._onReadError()
            return
        }
        this._processData(size)
    }

    ; GetOverlappedResult failed — either a spurious signal or pipe closed.
    _onReadError() {
        ; ERROR_IO_INCOMPLETE: the overlapped operation is still pending.
        ; This can happen if a spurious signal slipped through despite
        ; the ResetEvent guard. Re-register to catch the real completion.
        if A_LastError = 996 {
            this._registerWait()
            return
        }
        this._complete := true
        remainder := this._raw ? Buffer(0) : this._flushCarry()
        SetTimer(this._callback.Bind(remainder, 1), -10)
    }

    ; Data is available — drain all synchronous completions and deliver as one batch.
    _processData(size) {
        if this._raw
            batch := this._drainRaw(size, &pending)
        else
            batch := this._drainText(size, &pending)
        done := (pending = 0)
        if done
            this._complete := true  ; set BEFORE SetTimer — closes the race window
        SetTimer(this._callback.Bind(batch, done ? 1 : 0), -10)
        if !done
            this._registerWait()
    }

    ; -------------------------------------------------------------------------
    ; Data draining
    ; -------------------------------------------------------------------------

    ; Drain all synchronously available data in raw mode.
    ; Returns a single Buffer containing all batched chunks.
    _drainRaw(size, &pending) {
        buf      := this._buf
        batchBuf := Buffer(size)
        DllCall('RtlMoveMemory', 'Ptr', batchBuf, 'Ptr', buf, 'Ptr', size)
        batchPos := size
        pending := this._issueRead()
        while pending = -1 {
            size := NumGet(this._overlapped, A_PtrSize, 'UPtr')
            if batchPos + size > batchBuf.Size {
                newBuf := Buffer(Max(batchBuf.Size * 2, batchPos + size))
                DllCall('RtlMoveMemory', 'Ptr', newBuf, 'Ptr', batchBuf, 'Ptr', batchPos)
                batchBuf := newBuf
            }
            DllCall('RtlMoveMemory', 'Ptr', batchBuf.Ptr + batchPos, 'Ptr', buf, 'Ptr', size)
            batchPos += size
            pending := this._issueRead()
        }
        batchBuf.Size := batchPos
        return batchBuf
    }

    ; Drain all synchronously available data in text mode.
    ; Returns a single string with UTF-8 boundary fixing applied.
    _drainText(size, &pending) {
        size  := this._fixBoundary(size)
        batch := size > 0 ? StrGet(this._buf, size, this._encoding) : ''
        pending := this._issueRead()
        while pending = -1 {
            size  := NumGet(this._overlapped, A_PtrSize, 'UPtr')  ; InternalHigh
            size  := this._fixBoundary(size)
            batch .= size > 0 ? StrGet(this._buf, size, this._encoding) : ''
            pending := this._issueRead()
        }
        ; Flush leftover carry bytes when the pipe is closed
        if pending = 0 {
            remainder := this._flushCarry()
            if remainder != ''
                batch .= remainder
        }
        return batch
    }

    ; -------------------------------------------------------------------------
    ; UTF-8 boundary fixing (text mode only)
    ; -------------------------------------------------------------------------

    ; Prepend carry-over from the previous read and strip any incomplete
    ; trailing UTF-8 sequence. Returns the number of decodable bytes in buf.
    _fixBoundary(size) {
        if !this._isUTF8()
            return size
        carry     := this._carry
        carrySize := this._carrySize
        ; Prepend leftover bytes from the previous read.
        ; RtlMoveMemory is memmove — safe for overlapping regions.
        if carrySize > 0 {
            DllCall('RtlMoveMemory', 'Ptr', this._buf.Ptr + carrySize, 'Ptr', this._buf, 'Ptr', size)
            DllCall('RtlMoveMemory', 'Ptr', this._buf, 'Ptr', carry, 'Ptr', carrySize)
            size += carrySize
        }
        ; Tail scan only when ReadFile filled the buffer completely —
        ; a partial read means the kernel delivered all available data
        ; and the byte sequence is intact.
        maxRead := this._buf.Size - 4
        tail    := size >= maxRead ? this._utf8Tail(this._buf.Ptr, size) : 0
        ; Save incomplete bytes for the next read
        if tail > 0
            DllCall('RtlMoveMemory', 'Ptr', carry, 'Ptr', this._buf.Ptr + size - tail, 'Ptr', tail)
        this._carrySize := tail
        return size - tail
    }

    ; Decode and return any remaining carry-over bytes when a stream completes.
    _flushCarry() {
        if !this._isUTF8()
            return ''
        size := this._carrySize
        if size = 0
            return ''
        this._carrySize := 0
        return StrGet(this._carry, size, this._encoding)
    }

    _isUTF8() => this._encoding ~= 'i)utf-8|cp65001'

    ; Return the number of bytes belonging to an incomplete UTF-8 sequence
    ; at the end of the buffer, or 0 if the boundary is clean.
    _utf8Tail(ptr, size) {
        if size = 0
            return 0
        last := NumGet(ptr + size - 1, 'UChar')
        ; ASCII — no split possible
        if last < 0x80
            return 0
        ; Leading byte with no continuation bytes after it — incomplete
        if last >= 0xC0
            return 1
        ; Continuation byte (10xxxxxx) — scan backward for the leading byte;
        ; a valid UTF-8 sequence is at most 4 bytes, so look back up to 4.
        i     := size - 1
        limit := Max(0, size - 4)
        loop {
            if --i < limit
                return 0  ; no valid leading byte found, likely corrupted
            b := NumGet(ptr + i, 'UChar')
        } until (b & 0xC0) != 0x80
        expected := (b & 0xE0) = 0xC0 ? 2
                  : (b & 0xF0) = 0xE0 ? 3
                  : (b & 0xF8) = 0xF0 ? 4 : 0
        if !expected
            return 0  ; invalid leading byte
        actual := size - i
        return actual < expected ? actual : 0
    }

    ; -------------------------------------------------------------------------
    ; Lifecycle management
    ; -------------------------------------------------------------------------

    ; Step 1 of coordinated cleanup: cancel pending IO and poison the sentinel.
    ; When cleaning up multiple StreamReaders (e.g. stdout+stderr), call
    ; prepareDelete() on all of them first, Sleep 50 once, then finishDelete().
    prepareDelete() {
        if this.HasProp('_cancelled')
            return
        this._cancelled := true
        this._sentinel.alive := false
        SetTimer(this._watchdogFn, 0)
        if !this._complete {
            DllCall('CancelIoEx', 'Ptr', this._hPipe, 'Ptr', this._overlapped)
            DllCall('SetEvent',   'Ptr', this._hEvent)
        }
    }

    ; Step 2 of coordinated cleanup: unregister the thread-pool wait.
    finishDelete() {
        if this.HasProp('_regWait')
            this._regWait.Unregister()
    }

    ; Standalone cleanup — used when only one StreamReader needs to be torn
    ; down (e.g. AsyncStdinReader). Skipped if prepareDelete() was already called.
    __Delete() {
        if this.HasProp('_cancelled')
            return
        this.prepareDelete()
        Sleep 50
        this.finishDelete()
    }
}

class AsyncWait
{
    /**
     * Wraps RegisterWaitForSingleObject so that the system thread-pool callback
     * is safely delivered to the AHK GUI thread via PostMessageW.
     *
     * Public API:
     *     AsyncWait.Register(handle, callback, flags, timeout, completionEvent) -> RegisteredWait
     *         completionEvent: -1 (INVALID_HANDLE_VALUE) — block until callback completes (default)
     *                           0 (NULL) — return immediately, callback may still be running
     *     RegisteredWait.Unregister()
     *
     * Suitable kernel objects:
     *     OVERLAPPED I/O events (files, named pipes, sockets)
     *     Manual/auto-reset events created with CreateEvent
     *     Process/thread handles (wait for exit)
     *     Semaphores, mutexes (wait for release)
     *
     * Based on lexikos's code: https://www.autohotkey.com/boards/viewtopic.php?t=110691
     */

    static WT_EXECUTEDEFAULT      := 0x00000000
         , WT_EXECUTEINWAITTHREAD := 0x00000004
         , WT_EXECUTEONLYONCE     := 0x00000008

    ; Custom window message used to marshal callbacks to the AHK thread
         , WM_ASYNCWAIT_CALLBACK  := 0x5743

         , _inited := false

    static Register(handle, callback, flags := this.WT_EXECUTEONLYONCE, timeout := -1, completionEvent := -1) {
        this._init()
        param := this.RegisteredWait(handle, callback)
        NumPut('Ptr', this._postMessageW, 'Ptr', this._wnd.hwnd,
               'Ptr', this._nmsg, param)
        NumPut('Ptr', ObjPtr(param), param, A_PtrSize * 3)

        if !DllCall('RegisterWaitForSingleObject',
                    'Ptr*', &wh := 0, 'Ptr', handle,
                    'Ptr',  this._waitCallback, 'Ptr', param,
                    'UInt', timeout, 'UInt', flags)
            throw OSError()

        param.waitHandle := wh
        ; Intentional self-addref: keeps `param` alive while it lives in the
        ; system thread-pool queue, where AHK's GC cannot see it.
        ; Released in _unlock() after the callback is delivered.
        param.locked := ObjPtrAddRef(param)
        param.completionEvent := completionEvent
        return param
    }

    static _init() {
        static PAGE_EXECUTE_READWRITE := 0x40, HWND_MESSAGE := -3
        if this._inited
            return
        /**
         * #include <windows.h>
         * struct Param {
         *     decltype(&PostMessageW) pm;
         *     HWND wnd;
         *     UINT msg;
         * };
         * VOID CALLBACK WaitCallback(Param *param, BOOLEAN waitFired) {
         *     param->pm(param->wnd, param->msg, (WPARAM)param, (LPARAM)waitFired);
         * }
         * ---- 64-bit
         * 00000	48 8b c1		 mov	 rax, rcx
         * 00003	44 0f b6 ca		 movzx	 r9d, dl
         * 00007	8b 51 10		 mov	 edx, DWORD PTR [rcx+16]
         * 0000a	4c 8b c1		 mov	 r8, rcx
         * 0000d	48 8b 49 08		 mov	 rcx, QWORD PTR [rcx+8]
         * 00011	48 ff 20		 rex_jmp QWORD PTR [rax]
         * ---- 32-bit
         * 00000	0f b6 44 24 08	 movzx	 eax, BYTE PTR _waitFired$[esp-4]
         * 00005	50				 push	 eax
         * 00006	8b 44 24 08		 mov	 eax, DWORD PTR _param$[esp]
         * 0000a	50				 push	 eax
         * 0000b	ff 70 08		 push	 DWORD PTR [eax+8]
         * 0000e	ff 70 04		 push	 DWORD PTR [eax+4]
         * 00011	8b 00			 mov	 eax, DWORD PTR [eax]
         * 00013	ff d0			 call	 eax
         * 00015	c2 08 00		 ret	 8
         */
        a := A_PtrSize = 8 ? 0x8BCAB60F44C18B48 : 0x448B50082444B60F
        b := A_PtrSize = 8 ? 0x498B48C18B4C1051 : 0x70FF0870FF500824
        c := A_PtrSize = 8 ? 0x0000000020FF4808 : 0x0008C2D0FF008B04
        NumPut('Int64', a, 'Int64', b, 'Int64', c, this._waitCallback := Buffer(24))
        DllCall('VirtualProtect', 'Ptr', this._waitCallback, 'Ptr', 24,
                                  'UInt', PAGE_EXECUTE_READWRITE, 'UInt*', 0)
        hLib := DllCall('GetModuleHandle', 'Str', 'user32', 'Ptr')
        this._postMessageW := DllCall('GetProcAddress', 'Ptr', hLib, 'AStr', 'PostMessageW', 'Ptr')

        this._wnd  := Gui()
        DllCall('SetParent', 'Ptr', this._wnd.hwnd, 'Ptr', HWND_MESSAGE)
        this._nmsg := AsyncWait.WM_ASYNCWAIT_CALLBACK
        OnMessage(this._nmsg, ObjBindMethod(this, '_messaged'), 255)
        this._inited := true
    }

    static _messaged(wParam, lParam, nmsg, hwnd) {
        if hwnd = this._wnd.hwnd {
            param := ObjFromPtrAddRef(NumGet(wParam + A_PtrSize * 3, 'Ptr'))
            try (param.callback)(param.handle, lParam)
            (param.locked) && param._unlock()
        }
    }

    ; -------------------------------------------------------------------------
    class RegisteredWait extends Buffer {
        static prototype.waitHandle := 0, prototype.locked := 0, prototype.completionEvent := -1

        __New(handle, callback) {
            super.__New(A_PtrSize * 5, 0)
            this.handle   := handle
            this.callback := callback
        }

        __Delete() => this.Unregister()
        _unlock()  => (p := this.locked) && (this.locked := 0, ObjRelease(p))

        Unregister() {
            wh := this.waitHandle, this.waitHandle := 0
            (wh) && DllCall('UnregisterWaitEx', 'Ptr', wh, 'Ptr', this.completionEvent)
            this._unlock(), this.callback := ''
        }
    }
}
