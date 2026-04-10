#Requires AutoHotkey v2.0
#Include ..\AsyncProcessIO.ahk

; Source and destination folders for robocopy.
src := 'C:\Windows\Fonts'
dst := A_ScriptDir '\fonts_test'
try DirDelete dst, true

; /E  — copy subdirectories including empty ones
; /NJH — suppress job header (cleaner output, first line is folder info)
cmd := 'robocopy "' src '" "' dst '" /E /NJH'

; --- GUI setup ---

wnd := Gui('+Resize', 'Robocopy progress monitor')
wnd.SetFont('s11', 'Consolas')

wnd.AddText('x10 y10', 'Source:')
wnd.AddText('x+5 yp', src)

wnd.AddText('x10 y+8', 'Files:')
fileCount := wnd.AddText('x+5 yp w200', 'scanning...')

progress := wnd.AddProgress('x10 y+8 w760 h20 Range0-100')

logEdit := wnd.AddEdit('x10 y+8 w760 h350 ReadOnly BackgroundWhite')
logEdit.GetPos(, &logY)

stats := wnd.AddEdit('x10 y+8 w760 h190 ReadOnly BackgroundWhite')

wnd.OnEvent('Close', (*) => ExitApp())
wnd.OnEvent('Size', (g, mm, w, h) => (
    progress.Move(,, w - 20),
    logEdit.Move(,, w - 20, h - logY - 210),
    logEdit.GetPos(, &ly, , &lh),
    stats.Move(, ly + lh + 8, w - 20)
))
wnd.Show('w780')

; --- State ---
totalFiles  := 0
copiedFiles := 0
carry       := ''
statsBuffer := ''
inStats     := false

; --- Process ---

proc := AsyncProcessIO(cmd, OnData)

OnData(pid, str, state, stream) {
    static queue := []
    queue.Push({str: str, state: state, stream: stream})
    if queue.Length > 1
        return  ; re-entrant call — will be processed by the active loop
    while queue.Length {
        item := queue[1]
        _processChunk(item.str, item.state, item.stream)
        queue.RemoveAt(1)
    }
}

_processChunk(str, state, stream) {
    global totalFiles, copiedFiles, carry, proc, statsBuffer, inStats

    if stream != 0
        return

    str := carry . str
    carry := ''

    loop {
        lfPos := InStr(str, '`n')
        if !lfPos {
            carry := str
            break
        }
        line := SubStr(str, 1, lfPos - 1)
        str  := SubStr(str, lfPos + 1)

        ; Strip CR characters left by in-place progress updates
        line := StrReplace(line, '`r')
        line := Trim(line)

        if line = ''
            continue

        ; First non-empty line: "    New Dir     383    C:\Windows\Fonts\"
        ; The first number in this line is the total file count.
        if totalFiles = 0 && RegExMatch(line, '\d+', &m) {
            totalFiles := Integer(m[])
            fileCount.Text := '0 / ' totalFiles
            progress.Value := 0
            continue
        }

        ; Summary separator — everything after this is statistics
        if SubStr(line, 1, 3) = '---' {
            inStats := true
            continue
        }

        if inStats {
            statsBuffer .= line '`n'
            continue
        }

        ; Completed file line ends with "100%"
        if SubStr(line, -4) = '100%' {
            copiedFiles++
            if totalFiles > 0 {
                progress.Value := Round(copiedFiles / totalFiles * 100)
                fileCount.Text := copiedFiles ' / ' totalFiles
            }
            _appendLog(_getFileName(line) '`r`n')
        }
    }

    if state != 0 {
        if carry != '' {
            line := Trim(StrReplace(carry, '`r'))
            if InStr(line, '100%') {
                copiedFiles++
                _appendLog(_getFileName(line) '`r`n')
            }
        }
        carry := ''
        progress.Value := 100
        if statsBuffer != ''
            stats.Value := Trim(statsBuffer, '`n `t')
        fileCount.Text := copiedFiles ' / ' totalFiles ' — done'
        proc := ''
    }
}

_getFileName(line) {
    parts := StrSplit(line, '`t')
    lastField := parts[parts.Length]
    fileName := RegExReplace(lastField, '[\s\d\.]+%.*$')
    return Trim(fileName)
}

_appendLog(str) {
    static EM_SETSEL := 0xB1
    SetTimer () => (
        SendMessage(EM_SETSEL, -2, -1, logEdit),
        EditPaste(str, logEdit)
    ), -10
}