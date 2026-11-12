#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#ErrorStdOut UTF-8
#Warn All, StdOut
#Include ..\AsyncProcessIO.ahk

OnError(ReportError)
SetTimer(() => ExitApp(2), -30000)

if A_Args.Length {
    switch A_Args[1] {
        case 'output':
            FileAppend('stdout-data', '*')
            FileAppend('stderr-data', '**')
        case 'silent':
            Sleep 10000
        case 'exit-seven':
            ExitApp(7)
    }
    ExitApp(0)
}

LifetimeTests.Run()

ReportError(err, mode) {
    FileAppend('[FAIL] ' err.File ':' err.Line ' - ' err.Message '`n' err.Stack '`n', '**')
    ExitApp(1)
}

class LifetimeTests {
    static passed := 0
    static failed := 0
    static deleted := 0
    static pids := []

    static Run() {
        OnExit((*) => this.Cleanup())
        ; Warm up AHK's message window and the Windows thread pool before counting handles.
        this.RunCompleted()
        Sleep 200
        baseline := this.HandleCount()
        deletedBefore := this.deleted
        Loop 12
            this.RunCompleted()
        Sleep 200
        retained := this.HandleCount() - baseline
        this.Check(this.deleted - deletedBefore = 12, 'completed processes are destroyed')
        this.Check(retained <= 2, 'completed processes release handles (retained=' retained ')')

        this.TestCallbackOutput()
        this.TestExitCode()
        this.TestSilenceTimeout()
        this.TestPendingRelease()
        this.TestQueuedCallback()
        this.TestReplacedWaits()
        this.TestWaitDispatch()
        FileAppend('[RESULT] passed=' this.passed ' failed=' this.failed '`n', '*')
        ExitApp(this.failed ? 1 : 0)
    }

    static Spawn(mode, callback?, timeout := 2000) {
        cmd := '"' A_AhkPath '" /ErrorStdOut=UTF-8 "' A_ScriptFullPath '" ' mode
        proc := LifetimeTestProcess(cmd, callback?, timeout, 'UTF-8')
        this.pids.Push(proc.processID)
        return proc
    }

    static RunCompleted() {
        proc := this.Spawn('output')
        this.WaitFor(() => proc.state = 1, 'stdout/stderr EOF')
        this.Check(proc.outData = 'stdout-data' && proc.errData = 'stderr-data',
            'accumulated stdout/stderr are complete')
        proc := ''
    }

    static TestCallbackOutput() {
        received := {out: '', err: '', outDone: false, errDone: false}
        proc := this.Spawn('output', (pid, data, state, stream) => this.Collect(received, data, state, stream))
        this.WaitFor(() => received.outDone && received.errDone, 'callback EOF')
        this.Check(received.out = 'stdout-data' && received.err = 'stderr-data',
            'callback stdout/stderr are complete')
        deletedBefore := this.deleted
        proc := ''
        this.Check(this.deleted = deletedBefore + 1, 'callback process is destroyed')
    }

    static TestExitCode() {
        proc := this.Spawn('exit-seven')
        this.WaitFor(() => proc.complete, 'failed child EOF')
        this.Check(proc.exitCode = 7, 'nonzero child exit code is available')
        proc := ''
    }

    static TestSilenceTimeout() {
        received := {timedOut: false}
        proc := this.Spawn('silent', (pid, data, state, stream) =>
            (received.timedOut := received.timedOut || state = -1), 100)
        this.WaitFor(() => received.timedOut, 'silent child timeout')
        this.Check(proc.state = -1, 'silent child times out while both streams remain open')
        proc := ''
    }

    static Collect(received, data, state, stream) {
        if stream = 0 {
            received.out .= data
            received.outDone := state = 1
        } else {
            received.err .= data
            received.errDone := state = 1
        }
    }

    static TestPendingRelease() {
        proc := this.Spawn('silent')
        pid := proc.processID
        deletedBefore := this.deleted
        proc := ''
        this.Check(this.deleted = deletedBefore + 1, 'pending process is destroyed')
        ; ProcessClose requests termination; Windows may finish it after the destructor returns.
        started := A_TickCount
        while ProcessExist(pid) && A_TickCount - started < 2000
            Sleep 10
        this.Check(!ProcessExist(pid), 'pending child is terminated on release')
        ; Drain cancellation messages and the watchdog after the owner has been released.
        Sleep 600
    }

    static TestQueuedCallback() {
        proc := this.Spawn('silent')
        ; Keep the actual callback after releasing its owner, just as a queued timer does.
        lateCallback := proc._stdout._callback
        deletedBefore := this.deleted
        SetTimer(lateCallback.Bind('queued-data', 0), -1)
        proc := ''
        this.Check(this.deleted = deletedBefore + 1, 'saved stream callback does not own the process')
        lateCallback.Call('late-data', 0)
        lateCallback.Call('', -1)
        lateCallback.Call('', 1)
        this.Check(this.deleted = deletedBefore + 1, 'late data/timeout/EOF callbacks are harmless')
    }

    static TestReplacedWaits() {
        baseline := AsyncWait._active.Count
        proc := this.Spawn('silent')
        ; Simulate re-registering before a previous one-shot message is delivered.
        ; This is also the lifetime case when the watchdog recovers a lost message.
        Loop 12
            proc._stdout._registerWait()
        this.Check(AsyncWait._active.Count = baseline + 2,
            'replacing waits keeps only the two current registrations')
        proc := ''
        this.Check(AsyncWait._active.Count = baseline, 'release clears active wait registrations')
    }

    static TestWaitDispatch() {
        hEvent := DllCall('CreateEventW', 'Ptr', 0, 'Int', false, 'Int', false, 'Ptr', 0, 'Ptr')
        if !hEvent
            throw OSError()
        waitReg := ''
        baseline := AsyncWait._active.Count
        received := {calls: 0, timedOut: false}
        callback := (handle, timedOut) => (received.calls += 1, received.timedOut := timedOut)
        try {
            waitReg := AsyncWait.Register(hEvent, callback)
            id := waitReg.id
            DllCall('SetEvent', 'Ptr', hEvent)
            this.WaitFor(() => received.calls = 1, 'one-shot wait')
            this.Check(!received.timedOut && !AsyncWait._active.Has(id),
                'one-shot wait delivers the signal and leaves the active map')
            waitReg.Unregister()

            waitReg := AsyncWait.Register(hEvent, callback, AsyncWait.WT_EXECUTEONLYONCE, 50)
            this.WaitFor(() => received.calls = 2, 'wait timeout')
            this.Check(received.timedOut, 'wait timeout is delivered')
            waitReg.Unregister()

            waitReg := AsyncWait.Register(hEvent, callback, AsyncWait.WT_EXECUTEDEFAULT)
            Loop 3 {
                expected := received.calls + 1
                DllCall('SetEvent', 'Ptr', hEvent)
                this.WaitFor(() => received.calls = expected, 'repeated wait')
            }
            this.Check(AsyncWait._active.Has(waitReg.id), 'repeated wait stays registered')
            waitReg.Unregister()
            waitReg.Unregister()
            this.Check(AsyncWait._active.Count = baseline, 'Unregister is idempotent')

            callsBefore := received.calls
            wasCritical := A_IsCritical
            Critical
            try {
                waitReg := AsyncWait.Register(hEvent, callback, AsyncWait.WT_EXECUTEONLYONCE, -1, 0)
                ; Queue a notification and release its registration before delivery.
                DllCall('PostMessageW', 'Ptr', AsyncWait._wnd.Hwnd, 'UInt', AsyncWait._nmsg,
                    'UPtr', waitReg.id, 'Ptr', 0)
                waitReg.Unregister()
                waitReg := ''
                ; Exercise real thread-pool callbacks racing non-blocking cancellation.
                Loop 20 {
                    waitReg := AsyncWait.Register(hEvent, callback, AsyncWait.WT_EXECUTEONLYONCE, -1, 0)
                    DllCall('SetEvent', 'Ptr', hEvent)
                    waitReg.Unregister()
                    waitReg := ''
                }
            } finally {
                Critical wasCritical
            }
            Sleep 200
            this.Check(received.calls = callsBefore, 'stale posted notifications are ignored')
            this.Check(AsyncWait._active.Count = baseline, 'canceled waits leave no active entries')
        } finally {
            if IsObject(waitReg)
                waitReg.Unregister()
            DllCall('CloseHandle', 'Ptr', hEvent)
        }
    }

    static WaitFor(predicate, description) {
        started := A_TickCount
        while !predicate.Call() {
            if A_TickCount - started >= 5000
                throw TimeoutError('Waiting for ' description)
            Sleep 10
        }
    }

    static HandleCount() {
        count := 0
        if !DllCall('GetProcessHandleCount', 'Ptr', DllCall('GetCurrentProcess', 'Ptr'), 'UInt*', &count)
            throw OSError()
        return count
    }

    static Check(ok, description) {
        if ok
            this.passed += 1
        else
            this.failed += 1
        FileAppend((ok ? '[OK] ' : '[FAIL] ') description '`n', '*')
    }

    static Cleanup() {
        for pid in this.pids
            ProcessClose(pid)
    }
}

class LifetimeTestProcess extends AsyncProcessIO {
    __Delete() {
        LifetimeTests.deleted += 1
        super.__Delete()
    }
}
