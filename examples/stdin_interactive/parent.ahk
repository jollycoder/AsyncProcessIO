#Requires AutoHotkey v2.0
#Include ..\..\AsyncProcessIO.ahk
Persistent

; Demonstrates interactive stdin/stdout communication with a child process.
; The parent sends file paths to the child one by one; the child responds
; with the file size (stdout) or an error message if the file doesn't exist
; (stderr). The child process stays alive for the duration of the session.

; stdinOverlapped := true is required for AsyncStdinReader on the child side.
proc := AsyncProcessIO(
    '"' A_AhkPath '" "' A_ScriptDir '\child.ahk" fromParent',
    OnData,,,, true)

; --- GUI setup ---

wnd := Gui(, 'stdin interactive — file size query')
wnd.SetFont('s11', 'Consolas')
wnd.MarginX := wnd.MarginY := 8

wnd.AddText('xm', 'File path:')
input := wnd.AddEdit('xm y+4 w460')
btn   := wnd.AddButton('x+6 yp-1 w80 h26 Default', 'Send')

wnd.AddText('xm y+10', 'stdout (file size):')
outEdit := wnd.AddEdit('xm y+4 w550 h120 ReadOnly BackgroundWhite')

wnd.AddText('xm y+8', 'stderr (errors):')
errEdit := wnd.AddEdit('xm y+4 w550 h120 ReadOnly BackgroundWhite')

btn.OnEvent('Click', SendRequest)
input.OnEvent('Change', (*) => btn.Enabled := Trim(input.Value) != '')
wnd.OnEvent('Close', (*) => (proc.CloseStdIn(), ExitApp()))
wnd.Show()

; Disable button initially if input is empty
btn.Enabled := false

SendRequest(*) {
    path := Trim(input.Value)
    if path = ''
        return
    ; Send the path as a single line to the child's stdin.
    proc.WriteText(path '`n')
    input.Value := ''
    btn.Enabled := false
}

OnData(pid, data, state, stream) {
    static EM_SETSEL := 0xB1
    ctrl := stream = 0 ? outEdit : errEdit
    if data != '' {
        ; Defer EditPaste to avoid re-entrancy: SendMessage can pump the
        ; message queue, causing OnData to be called again before this
        ; call returns.
        SetTimer () => (
            SendMessage(EM_SETSEL, -2, -1, ctrl),
            EditPaste(data . '`r`n', ctrl)
        ), -10
    }
}
