#Requires AutoHotkey v2.0
#Include ..\AsyncWait.ahk
Persistent
SYNCHRONIZE := 0x100000

; Launch a process and get its handle.
Run 'cmd',,, &pid
hProcess := DllCall('OpenProcess', 'UInt', SYNCHRONIZE, 'Int', false, 'UInt', pid, 'Ptr')

; Register a one-shot thread-pool wait for the process handle.
; When the process exits, the callback is delivered on the AHK GUI thread.
wait := AsyncWait.Register(hProcess, OnProcessExit)

OnProcessExit(handle, timedOut) {
    global wait
    DllCall('GetExitCodeProcess', 'Ptr', handle, 'UIntP', &exitCode := 0)
    DllCall('CloseHandle', 'Ptr', handle)
    wait := ''
    MsgBox 'cmd.exe exited with code ' exitCode
    ExitApp
}