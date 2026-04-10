#Requires AutoHotkey v2.0
#Include ..\..\AsyncProcessIO.ahk

; Spawn a child AHK process that will display incoming stdin in a GUI window.
; stdinOverlapped := true is required for AsyncStdinReader on the child side.
childProc := AsyncProcessIO(A_AhkPath ' "' A_ScriptDir '\child.ahk" fromParent',,,,, true)

; Give the child process time to initialize its GUI before we start sending data.
Sleep 1000

; Spawn a second process and pipe its stdout directly into the child's stdin.
; This demonstrates using two AsyncProcessIO instances simultaneously and
; forwarding output from one process to the input of another.
dirProc := AsyncProcessIO('cmd /c dir /s C:\Windows\System32', OnDirOutput)

OnDirOutput(pid, str, state, stream) {
    global childProc, dirProc
    ; Only forward stdout; ignore stderr
    if stream != 0
        return
    if str != ''
        childProc.WriteText(str)
    if state = 1
        childProc.CloseStdIn()  ; signal EOF to the child
    if state != 0
        dirProc := ''
}