#Requires AutoHotkey v2.0
#Include ..\AsyncProcessIO.ahk
Persistent

; Demonstrates independent handling of stdout and stderr streams.
; PowerShell writes alternating lines to stdout and stderr with a short
; delay between them, making the independence of the two streams visible.
cmd := 'powershell -NoProfile -Command "
(
    foreach ($i in 1..5) {
        Write-Output \"stdout line $i\";
        $host.ui.WriteErrorLine(\"stderr line $i\");
        Start-Sleep -Milliseconds 300
    }"
)'

editOpt := 'xp y+5 w300 h200 ReadOnly BackgroundWhite'
wnd := Gui(, 'Stdout / stderr handling')
wnd.SetFont('s11', 'Consolas')

wnd.AddText(, 'stdout:')
outEdit := wnd.AddEdit(editOpt)

wnd.AddText('x+20 ym', 'stderr:')
errEdit := wnd.AddEdit(editOpt)

wnd.OnEvent('Close', (*) => ExitApp())
wnd.Show()

proc := AsyncProcessIO(cmd, OnData)

OnData(pid, str, state, stream) {
    static EM_SETSEL := 0xB1

    ctrl := stream = 0 ? outEdit : errEdit

    if str != '' {
        ; Defer to avoid re-entrancy
        SetTimer () => (
            SendMessage(EM_SETSEL, -2, -1, ctrl),
            EditPaste(str, ctrl)
        ), -10
    }

    (proc.complete) && SetTimer(() => ExitApp(), -3000)
}
