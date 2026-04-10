#Requires AutoHotkey v2.0
#Include ..\AsyncProcessIO.ahk

out := OutputGui(800, 600, () => ExitApp())
proc := AsyncProcessIO('powershell -Command Get-Process | Select-Object Name, Id, CPU, WorkingSet | Format-Table -AutoSize', OnData)

OnData(PID, str, state, stream) {
    global proc
    static prevState := ''
    ; defer to avoid re-entrancy
    SetTimer () => out.Append(str, stream), -1
    if state != prevState {
        prevState := state
        SetTimer () => out.SetState(state), -1
    }
    if proc && state {
        proc := ''
    }
}

class OutputGui
{
    states := Map(0, 'data incoming...', 1, 'completed', -1, 'timed out')
    visible := true

    __New(width, height, onClose?) => this._CreateGui(width, height, onClose ?? '')

    SetState(state) => this.status.Text := this.states[state]

    Append(str, stream) {
        (!this.visible) && (this.visible := true, this.gui.Show())
        ctrl := stream = 0 ? 'out' : 'err'
        SendMessage 0xB1, -2, -1, this.%ctrl% ; EM_SETSEL
        EditPaste str, this.%ctrl%
    }

    Clear() {
        for ctrl in ['status', 'out', 'err'] {
            this.%ctrl%.Text := ''
        }
    }

    _CreateGui(width, height, onClose) {
        static common := 'BackgroundWhite ReadOnly '
        selfPtr := ObjPtr(this)
        this.gui := wnd := Gui('+Resize', 'Async I/O reading')
        wnd.OnEvent('Close', (*) => (
            ObjFromPtrAddRef(selfPtr).visible := false,
            (onClose && onClose.Call())
        ))
        wnd.MarginX := wnd.MarginY := 0
        wnd.SetFont('s12', 'Consolas')
        wnd.AddText('x10 y10', 'Status: ').Focus()
        this.status := wnd.AddEdit(common . 'x+5 yp-2 w170 Center')

        wnd.AddText('x10 y+10', 'StdOut:')
        this.out := out := wnd.AddEdit(common . 'xm y+5 w' . width . ' h' . height)

        errTxt := wnd.AddText('x10 y+10', 'StdErr:')
        this.err := err := wnd.AddEdit(common . 'xm y+5 w' . width . ' r6')

        out.GetPos(, &yOut)
        err.GetPos(, &yErr,, &hErr)
        hPrev := yErr + hErr

        wnd.OnEvent('Size', (g, mm, w, h) => (
            dh := height + h - hPrev,
            out.Move(,, w, dh),
            errTxt.Move(, yOut + dh + 10),
            err.Move(, h - hErr, w)
        ))
        wnd.OnEvent('Close', (*) => wnd.Destroy())
        wnd.Show()
    }

    __Delete() => this.gui.Destroy()
}