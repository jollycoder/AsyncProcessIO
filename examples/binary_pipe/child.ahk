#Requires AutoHotkey v2
#Include ..\..\AsyncProcessIO.ahk

; Receives raw binary data from parent via stdin and writes it to a file.
; On completion, compares the output file size with the expected size
; passed as a command-line argument to verify the transfer.

; Guard against accidental direct execution.
if !A_Args.Has(1) || !(A_Args[1] ~= '^\d+$') {
    MsgBox 'This script must be run from the parent.ahk script!', ' ', 48
    ExitApp
}

global stdinReader := ''
global OUT_FILE    := A_ScriptDir . '\test.bin'
global fileHandle  := ''
global EXPECTED_SIZE := Integer(A_Args.Length ? A_Args[1] : 0)

BuildUI()
OpenOutputFile()

stdinReader := AsyncStdinReader(OnStdinData,, true)

BuildUI() {
    static W := 500
    g := Gui('+Resize', 'Raw mode — child')
    g.SetFont('s11', 'Consolas')
    g.MarginX := g.MarginY := 8

    g.AddText('w' W - 20, 'Output file:')
    g.AddText('xm', OUT_FILE)

    g.AddText('xm w' W - 20 ' h8', '')  ; spacer

    g.AddText('xm', 'Status:')
    status   := g.AddText('x+6 yp w300', 'receiving...')
    g.AddText('xm', 'Bytes received:')
    bytesRcv := g.AddText('x+6 yp w200', '0')
    g.AddText('xm', 'Result:')
    result   := g.AddText('x+6 yp w300', '—')

    g.OnEvent('Close', (*) => ExitApp())
    g.Show('w' W)

    global ui := {status: status, bytesRcv: bytesRcv, result: result}
}

OpenOutputFile() {
    global fileHandle
    fileHandle := FileOpen(OUT_FILE, 'w')
    if !fileHandle
        throw Error('Failed to open output file: ' OUT_FILE)
}

OnStdinData(buf, state) {
    global stdinReader, fileHandle
    static callCount := 0
    callCount++
    if !fileHandle  ; guard against re-entry if state=1 arrives twice
        return
    if buf.Size > 0 {
        written := fileHandle.RawWrite(buf)
        ui.bytesRcv.Value := Integer(ui.bytesRcv.Value) + buf.Size
        if written != buf.Size
            ui.result.Value := 'RawWrite short write: ' written ' of ' buf.Size
    }
    if state = 1 {
        fileHandle.Close()
        fileHandle := ''
        ui.status.Value := 'done'
        CompareFiles()
        stdinReader := ''
    }
}

CompareFiles() {
    outSize := FileGetSize(OUT_FILE)
    if EXPECTED_SIZE = outSize
        ui.result.Value := 'OK — sizes match (' outSize ' bytes)'
    else
        ui.result.Value := 'MISMATCH — expected=' EXPECTED_SIZE ' out=' outSize
}