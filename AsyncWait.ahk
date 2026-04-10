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
     * Based on lexikos's code: https://www.autohotkey.com/boards/viewtopic.php?t=110691
     * 
     * Version: 1.0.0
     * Date:    2026-04-10
     */

    static WT_EXECUTEDEFAULT      := 0x00000000
         , WT_EXECUTEINWAITTHREAD := 0x00000004
         , WT_EXECUTEONLYONCE     := 0x00000008

    ; Custom window message used to marshal callbacks to the AHK thread
         , WM_ASYNCWAIT_CALLBACK  := 0x5743

         , _inited := false

    static Register(handle, callback, flags := this.WT_EXECUTEONLYONCE, timeout := -1, completionEvent := -1) {
        this._init()
        param := this.RegisteredWait(handle, callback)
        NumPut('Ptr', this._postMessageW, 'Ptr', this._wnd.hwnd,
               'Ptr', this._nmsg, param)
        NumPut('Ptr', ObjPtr(param), param, A_PtrSize * 3)

        if !DllCall('RegisterWaitForSingleObject',
                    'Ptr*', &wh := 0, 'Ptr', handle,
                    'Ptr',  this._waitCallback, 'Ptr', param,
                    'UInt', timeout, 'UInt', flags)
            throw OSError()

        param.waitHandle := wh
        ; Intentional self-addref: keeps `param` alive while it lives in the
        ; system thread-pool queue, where AHK's GC cannot see it.
        ; Released in _unlock() after the callback is delivered.
        param.locked := ObjPtrAddRef(param)
        param.completionEvent := completionEvent
        return param
    }

    static _init() {
        static PAGE_EXECUTE_READWRITE := 0x40, HWND_MESSAGE := -3
        if this._inited
            return
        /**
         * #include <windows.h>
         * struct Param {
         *     decltype(&PostMessageW) pm;
         *     HWND wnd;
         *     UINT msg;
         * };
         * VOID CALLBACK WaitCallback(Param *param, BOOLEAN waitFired) {
         *     param->pm(param->wnd, param->msg, (WPARAM)param, (LPARAM)waitFired);
         * }
         * ---- 64-bit
         * 00000	48 8b c1		 mov	 rax, rcx
         * 00003	44 0f b6 ca		 movzx	 r9d, dl
         * 00007	8b 51 10		 mov	 edx, DWORD PTR [rcx+16]
         * 0000a	4c 8b c1		 mov	 r8, rcx
         * 0000d	48 8b 49 08		 mov	 rcx, QWORD PTR [rcx+8]
         * 00011	48 ff 20		 rex_jmp QWORD PTR [rax]
         * ---- 32-bit
         * 00000	0f b6 44 24 08	 movzx	 eax, BYTE PTR _waitFired$[esp-4]
         * 00005	50				 push	 eax
         * 00006	8b 44 24 08		 mov	 eax, DWORD PTR _param$[esp]
         * 0000a	50				 push	 eax
         * 0000b	ff 70 08		 push	 DWORD PTR [eax+8]
         * 0000e	ff 70 04		 push	 DWORD PTR [eax+4]
         * 00011	8b 00			 mov	 eax, DWORD PTR [eax]
         * 00013	ff d0			 call	 eax
         * 00015	c2 08 00		 ret	 8
         */
        a := A_PtrSize = 8 ? 0x8BCAB60F44C18B48 : 0x448B50082444B60F
        b := A_PtrSize = 8 ? 0x498B48C18B4C1051 : 0x70FF0870FF500824
        c := A_PtrSize = 8 ? 0x0000000020FF4808 : 0x0008C2D0FF008B04
        NumPut('Int64', a, 'Int64', b, 'Int64', c, this._waitCallback := Buffer(24))
        DllCall('VirtualProtect', 'Ptr', this._waitCallback, 'Ptr', 24,
                                  'UInt', PAGE_EXECUTE_READWRITE, 'UInt*', 0)
        hLib := DllCall('GetModuleHandle', 'Str', 'user32', 'Ptr')
        this._postMessageW := DllCall('GetProcAddress', 'Ptr', hLib, 'AStr', 'PostMessageW', 'Ptr')

        this._wnd  := Gui()
        DllCall('SetParent', 'Ptr', this._wnd.hwnd, 'Ptr', HWND_MESSAGE)
        this._nmsg := AsyncWait.WM_ASYNCWAIT_CALLBACK
        OnMessage(this._nmsg, ObjBindMethod(this, '_messaged'), 255)
        this._inited := true
    }

    static _messaged(wParam, lParam, nmsg, hwnd) {
        if hwnd = this._wnd.hwnd {
            param := ObjFromPtrAddRef(NumGet(wParam + A_PtrSize * 3, 'Ptr'))
            try (param.callback)(param.handle, lParam)
            (param.locked) && param._unlock()
        }
    }

    ; -------------------------------------------------------------------------
    class RegisteredWait extends Buffer {
        static prototype.waitHandle := 0, prototype.locked := 0, prototype.completionEvent := -1

        __New(handle, callback) {
            super.__New(A_PtrSize * 5, 0)
            this.handle   := handle
            this.callback := callback
        }

        __Delete() => this.Unregister()
        _unlock()  => (p := this.locked) && (this.locked := 0, ObjRelease(p))

        Unregister() {
            wh := this.waitHandle, this.waitHandle := 0
            (wh) && DllCall('UnregisterWaitEx', 'Ptr', wh, 'Ptr', this.completionEvent)
            this._unlock(), this.callback := ''
        }
    }
}