#Requires AutoHotkey v2
#Include ..\..\AsyncProcessIO.ahk

childProc := '', psProc := ''
bytesSentCount := 0

if !SOURCE_FILE := FileSelect(3, A_MyDocuments, 'Select the file to be sent as binary data') {
    return
}

BuildUI()

BuildUI() {
    W := 500
    g := Gui('+Resize', 'Raw mode — parent')
    g.SetFont('s11', 'Consolas')
    g.MarginX := g.MarginY := 8

    g.AddText('w' . W - 16, 'Source file:')
    g.AddEdit('xm wp ReadOnly', SOURCE_FILE)

    g.AddText('xm y+20', 'PS stderr:').Focus()
    psErr := g.AddEdit('xm w' . W - 16 ' h80 ReadOnly -Wrap')

    btnRun   := g.AddButton('w120 h26', 'Run test')
    status   := g.AddText('x+8 yp+4 w' . W - 148, 'idle')
    g.AddText('xm', 'Bytes sent:')
    bytesSent := g.AddText('x+6 yp w200', '0')

    btnRun.OnEvent('Click', RunTest)
    g.OnEvent('Close', (*) => ExitApp())
    g.Show('w' W)

    global ui := {status: status, bytesSent: bytesSent, psErr: psErr}
}

; Encodes a PowerShell script as Base64 UTF-16LE for use with -EncodedCommand.
; This avoids quoting issues with complex scripts passed on the command line.
EncodePSCommand(script) {
    byteCount := StrPut(script, 'UTF-16') - 2
    buf := Buffer(byteCount)
    StrPut(script, buf, 'UTF-16')
    DllCall('crypt32\CryptBinaryToString', 'Ptr', buf, 'UInt', byteCount,
            'UInt', 0x40000001, 'Ptr', 0, 'UIntP', &len := 0)
    out := Buffer(len * 2)
    DllCall('crypt32\CryptBinaryToString', 'Ptr', buf, 'UInt', byteCount,
            'UInt', 0x40000001, 'Ptr', out, 'UIntP', &len)
    return StrGet(out, 'UTF-16')
}

RunTest(*) {
    global childProc, psProc, bytesSentCount
    bytesSentCount := 0
    childProc := '', psProc := ''
    ui.bytesSent.Value := '0'
    ui.status.Value := 'starting child...'

    srcSize := FileGetSize(SOURCE_FILE)
    ; Spawn the child AHK process that will receive the binary data via stdin.
    ; stdinOverlapped := true is required for AsyncStdinReader on the child side.
    childProc := AsyncProcessIO(
        A_AhkPath ' "' A_ScriptDir '\child.ahk" ' . srcSize,,,,, true
    )
    script := Format('
    (
        $ProgressPreference = 'SilentlyContinue'
        $s = [System.IO.File]::OpenRead("{}")
        $buf = New-Object byte[] 65536
        while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
            [Console]::OpenStandardOutput().Write($buf, 0, $n)
        }
        $s.Close()
    )', SOURCE_FILE)

    ; Read the source file in chunks via PowerShell and write each raw Buffer
    ; chunk directly to the child's stdin. PowerShell writes to stdout using
    ; [Console]::OpenStandardOutput() to bypass text-mode encoding.
    psProc := AsyncProcessIO(
        'powershell -NoProfile -NonInteractive -EncodedCommand ' . EncodePSCommand(script),
        OnPsOutput,,, true
    )
    ui.status.Value := 'sending...'
}

OnPsOutput(pid, buf, state, stream) {
    global childProc, psProc, bytesSentCount
    if stream = 1 {
        if buf != ''
            ui.psErr.Value .= buf
        return
    }
    if buf.Size > 0 {
        written := childProc.WriteData(buf)
        bytesSentCount += buf.Size
        ui.bytesSent.Value := bytesSentCount
        if written != buf.Size
            ui.psErr.Value .= 'WriteData short write: ' written ' of ' buf.Size '`n'
    }
    if state = 1 {
        childProc.CloseStdIn()
        ui.status.Value := 'done — sent ' bytesSentCount ' bytes'
        psProc := ''
    }
}