#Requires AutoHotkey v2.0
#Include ..\..\AsyncProcessIO.ahk
Persistent

; Guard against accidental direct execution.
if !A_Args.Has(1) || A_Args[1] != 'fromParent' {
    MsgBox 'This script must be run from the parent.ahk script!', ' ', 48
    ExitApp
}

; Read file path requests from stdin line by line.
; For each path: write file size to stdout, or an error message to stderr.
stdinReader := AsyncStdinReader(OnStdin)

OnStdin(data, state) {
    global stdinReader

    ; Process each complete line in the received chunk.
    ; Chunk boundaries are not guaranteed to align with WriteLine calls on
    ; the parent side, so we split manually and carry incomplete lines.
    static carry := ''
    data := carry . data
    carry := ''

    loop {
        lfPos := InStr(data, '`n')
        if !lfPos {
            carry := data
            break
        }
        line := Trim(SubStr(data, 1, lfPos - 1), '`r `t')
        data := SubStr(data, lfPos + 1)

        if line = ''
            continue

        if FileExist(line) {
            ; Write file size to stdout
            FileAppend FileGetSize(line) '`n', '*'
        } else {
            ; Write error to stderr
            FileAppend 'File not found: ' line '`n', '**'
        }
    }

    if state = 1 {
        stdinReader := ''
        ExitApp
    }
}
