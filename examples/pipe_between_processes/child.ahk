#Requires AutoHotkey v2.0
#Include ..\..\AsyncProcessIO.ahk

; Guard against accidental direct execution.
if !A_Args.Has(1) || A_Args[1] != 'fromParent' {
    MsgBox 'This script must be run from the parent.ahk script!', ' ', 48
    ExitApp
}

CreateGui()

; Read stdin asynchronously and display each chunk as it arrives.
; Chunk boundaries are not guaranteed to align with WriteText calls on the
; parent side — multiple writes may arrive as a single chunk, or one write
; may be split across several chunks.
stdinReader := AsyncStdinReader(OnStdinData)

OnStdinData(str, state) {
    global stdinReader, text, editCtrl
    static EM_SETSEL := 0xB1

    text.Value := state = 1 ? 'true' : state = -1 ? 'timed out' : 'false'
    if str != '' {
        ; defer to avoid re-entrancy
        SetTimer () => (
            SendMessage(EM_SETSEL, -2, -1, editCtrl),
            EditPaste(str, editCtrl)
        ), -1
    }
    if state != 0
        stdinReader := ''
}

CreateGui() {
    global text, editCtrl
    wnd  := Gui('+Resize', 'Stdin reader — child process')
    wnd.MarginX := wnd.MarginY := 0
    wnd.SetFont('s12', 'Consolas')
    wnd.AddText('x10 y10', 'Complete: ')
    text := wnd.AddText('x+5 yp w100', 'false')
    editCtrl := wnd.AddEdit('xm y+10 w700 h500 ReadOnly BackgroundWhite')
    editCtrl.GetPos(, &editY)
    wnd.OnEvent('Size', (o, m, w, h) => editCtrl.Move(,, w, h - editY))
    wnd.OnEvent('Close', (*) => ExitApp())
    wnd.Show()
}