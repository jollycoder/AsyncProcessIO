#Requires AutoHotkey v2.0
#Include ..\AsyncProcessIO.ahk

proc := AsyncProcessIO('ping google.com')
while !proc.complete {
    Sleep 50
}
Sleep 50
state := Map(0, 'running', 1, 'completed', -1, 'timed out')[proc.state]
MsgBox 'state: '    . state        . '`n`n'
     . 'outData:`n' . proc.outData . '`n`n'
     . 'outSize: '  . proc.outSize