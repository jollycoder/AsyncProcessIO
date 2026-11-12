#Requires AutoHotkey v2.0

class AsyncWait
{
    /**
     * Wraps RegisterWaitForSingleObject so that the system thread-pool callback
     * is safely delivered to the AHK GUI thread via PostMessageW.
     *
     * Public API:
     *     AsyncWait.Register(handle, callback, flags, timeout, completionEvent) -> RegisteredWait
     *         completionEvent: -1 (INVALID_HANDLE_VALUE) — block until callback completes (default)
     *                           0 (NULL) — return immediately, callback may still be running
     *     RegisteredWait.Unregister()
     *
     * Suitable kernel objects:
     *     OVERLAPPED I/O events (files, named pipes, sockets)
     *     Manual/auto-reset events created with CreateEvent
     *     Process/thread handles (wait for exit)
     *     Semaphores, mutexes (wait for release)
     *
     * Lifetime model:
     *     Every registration gets a unique, never reused integer id. The thread-pool
     *     thunk posts only that id (wParam) and reads nothing but constants baked
     *     into its own code, so it never touches AHK-managed memory. The AHK side
     *     resolves the id through the _active map; a message that arrives after
     *     Unregister() (or after the object is gone) is simply ignored.
     *     The map holds a strong reference while the wait is registered, so the
     *     caller does not have to keep the returned object alive. A one-shot wait
     *     (WT_EXECUTEONLYONCE) is dropped from the map once delivered; any other
     *     wait stays there until Unregister() is called.
     *
     * Based on lexikos's code: https://www.autohotkey.com/boards/viewtopic.php?t=110691
     *
     * Version: 1.1.0
     * Date:    2026-09-22
     *     1.1.0 — fix use-after-free when a posted message outlived its
     *             RegisteredWait (crash in _messaged on resume from sleep).
     */

    static WT_EXECUTEDEFAULT      := 0x00000000
         , WT_EXECUTEINWAITTHREAD := 0x00000004
         , WT_EXECUTEONLYONCE     := 0x00000008

    ; Custom window message used to marshal callbacks to the AHK thread
         , WM_ASYNCWAIT_CALLBACK  := 0x5743

         , _inited := false
         , _nextId := 0
         , _active := Map()

    static Register(handle, callback, flags := this.WT_EXECUTEONLYONCE, timeout := -1, completionEvent := -1) {
        this._init()
        id := ++this._nextId
        rw := this.RegisteredWait(id, handle, callback, flags, completionEvent)
        ; Publish before registering: the message cannot be dispatched until this
        ; thread pumps, but keeping the map authoritative from the start is simpler.
        this._active[id] := rw
        if !DllCall('RegisterWaitForSingleObject',
                    'Ptr*', &wh := 0, 'Ptr', handle,
                    'Ptr',  this._waitCallback, 'Ptr', id,
                    'UInt', timeout, 'UInt', flags) {
            err := A_LastError
            this._active.Delete(id)
            rw.callback := ''
            throw OSError(err)
        }
        rw.waitHandle := wh
        return rw
    }

    static _init() {
        static HWND_MESSAGE := -3
        if this._inited
            return
        this._wnd  := Gui()
        DllCall('SetParent', 'Ptr', this._wnd.hwnd, 'Ptr', HWND_MESSAGE)
        this._nmsg := AsyncWait.WM_ASYNCWAIT_CALLBACK
        hLib := DllCall('GetModuleHandle', 'Str', 'user32', 'Ptr')
        pm   := DllCall('GetProcAddress', 'Ptr', hLib, 'AStr', 'PostMessageW', 'Ptr')
        this._waitCallback := this._buildThunk(pm, this._wnd.hwnd, this._nmsg)
        OnMessage(this._nmsg, ObjBindMethod(this, '_messaged'), 255)
        this._inited := true
    }

    /**
     * Builds the WAITORTIMERCALLBACK thunk with PostMessageW, hwnd and msg
     * embedded as immediates. Context carries the registration id.
     *
     * VOID CALLBACK WaitCallback(PVOID id, BOOLEAN waitFired) {
     *     PostMessageW(HWND_CONST, MSG_CONST, (WPARAM)id, (LPARAM)waitFired);
     * }
     * ---- 64-bit (tail call, caller's shadow space is reused)
     * 00  44 0F B6 CA        movzx r9d, dl        ; lParam = waitFired
     * 04  4C 8B C1           mov   r8, rcx        ; wParam = id
     * 07  BA imm32           mov   edx, msg
     * 0C  48 B9 imm64        mov   rcx, hwnd
     * 16  48 B8 imm64        mov   rax, PostMessageW
     * 20  FF E0              jmp   rax
     * ---- 32-bit (stdcall)
     * 00  0F B6 44 24 08     movzx eax, byte [esp+8]  ; waitFired
     * 05  50                 push  eax                ; lParam
     * 06  FF 74 24 08        push  dword [esp+8]      ; wParam = id
     * 0A  68 imm32           push  msg
     * 0F  68 imm32           push  hwnd
     * 14  B8 imm32           mov   eax, PostMessageW
     * 19  FF D0              call  eax
     * 1B  C2 08 00           ret   8
     *
     * The code block is allocated once and never freed: a thread-pool callback
     * may still be executing it after UnregisterWaitEx(wh, NULL) returns.
     */
    static _buildThunk(pm, hwnd, msg) {
        static MEM_COMMIT := 0x1000, MEM_RESERVE := 0x2000
             , PAGE_READWRITE := 0x04, PAGE_EXECUTE_READ := 0x20
        if A_PtrSize = 8 {
            hex  := '440FB6CA' . '4C8BC1' . 'BA00000000'
                  . '48B90000000000000000' . '48B80000000000000000' . 'FFE0'
            imms := [[0x08, 'UInt', msg], [0x0E, 'Ptr', hwnd], [0x18, 'Ptr', pm]]
        } else {
            hex  := '0FB6442408' . '50' . 'FF742408'
                  . '6800000000' . '6800000000' . 'B800000000' . 'FFD0' . 'C20800'
            imms := [[0x0B, 'UInt', msg], [0x10, 'Ptr', hwnd], [0x15, 'Ptr', pm]]
        }
        size := StrLen(hex) // 2
        p := DllCall('VirtualAlloc', 'Ptr', 0, 'Ptr', size,
                     'UInt', MEM_COMMIT | MEM_RESERVE, 'UInt', PAGE_READWRITE, 'Ptr')
        if !p
            throw OSError()
        loop size
            NumPut('UChar', Integer('0x' . SubStr(hex, A_Index * 2 - 1, 2)), p, A_Index - 1)
        for imm in imms
            NumPut(imm[2], imm[3], p, imm[1])
        DllCall('VirtualProtect', 'Ptr', p, 'Ptr', size, 'UInt', PAGE_EXECUTE_READ, 'UInt*', 0)
        DllCall('FlushInstructionCache', 'Ptr', DllCall('GetCurrentProcess', 'Ptr'), 'Ptr', p, 'Ptr', size)
        return p
    }

    static _messaged(wParam, lParam, nmsg, hwnd) {
        if hwnd != this._wnd.hwnd
            return
        ; Stale message: the wait was unregistered after the callback had
        ; already posted. Nothing to deliver, and nothing unsafe was read.
        if !this._active.Has(wParam)
            return 0
        rw := this._active[wParam]
        if rw.flags & this.WT_EXECUTEONLYONCE
            this._active.Delete(wParam)
        try (rw.callback)(rw.handle, lParam)
        return 0
    }

    ; -------------------------------------------------------------------------
    class RegisteredWait {
        static prototype.waitHandle := 0

        __New(id, handle, callback, flags, completionEvent) {
            this.id              := id
            this.handle          := handle
            this.callback        := callback
            this.flags           := flags
            this.completionEvent := completionEvent
        }

        __Delete() => this.Unregister()

        Unregister() {
            wh := this.waitHandle, this.waitHandle := 0
            ; Any message still queued for this id will be ignored from now on.
            if AsyncWait._active.Has(this.id)
                AsyncWait._active.Delete(this.id)
            (wh) && DllCall('UnregisterWaitEx', 'Ptr', wh, 'Ptr', this.completionEvent)
            this.callback := ''
        }
    }
}
