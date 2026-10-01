# Elden Ring crashes when it quits

**Status: open, known issue.** Quitting Elden Ring from its own menu ends in an
access violation instead of a clean exit. The game has already stopped when it
happens; at the title screen nothing is being saved. It does not depend on how
the game was started or which protium-built runtime it runs on, and the bad
pointer comes from the game's own shutdown code. This document records what is
known, what was ruled out, and what would settle it.

*Measured 2026-10-01 on an M4 Mac, macOS 26.6 (Darwin 25.6.0), Elden Ring 2.7.1.0
(Steam build `25080141`), `wine-11.0-cx26.3-p2` with D3DMetal 4.0b2.*

## The symptom

```
wine: Unhandled page fault on read access to 000003E80000EA5E at address 00006FFFFFD486B0
=>0 block_get_type(block=000003E80000EA58) in ntdll
  1 unsafe_block_from_ptr+0x130 in ntdll
  2 RtlFreeHeap+0x4e in ntdll
  3 eldenring+0x254cb68
  ...
0x006fffffd486b0 unsafe_block_from_ptr+0x130 in ntdll: movzbl -2(%r8), %eax
```

`r8` is `0x000003e80000ea60`, the pointer being freed, which is two small
integers side by side: `1000` and `60000`. The heap is `0x140000`, the process
heap. The game process's own thread list holds only the main thread and Wine's
helpers by then: all of the game's worker threads are already gone.

A launcher that reports the exit status sees `0xC0000005`. `protium run`
passes it out as a Unix status, which keeps only the low byte, so it reports
`5`. Those are the same crash.

**Seen with every combination tried:** the runtime built on 2026-09-08, the same
recipe rebuilt locally on 2026-10-01, and the runtime built by the `wine-build`
workflow on a GitHub runner, started by `protium run`, by a probe with no
injected code, and by `ermod-engine`'s in-prefix launcher (whose own
investigation, with a do-nothing DLL injected, reached the same conclusion: not
its code).

## Wine's side

`RtlFreeHeap` hands the pointer to `unsafe_block_from_ptr` in
`dlls/ntdll/heap.c`, which reads the block header just before it. Unless the
heap was created with `HEAP_VALIDATE`, the only check made before that read is
alignment, and `0x3e80000ea60` is 16-aligned, so the read happens and faults.

That function is **identical** in the CrossOver 26.3.0 tree this runtime is
built from, in upstream Wine `master`, and in Valve's `proton_10.0` branch
(compared 2026-10-01). Proton adds two unrelated heap options
(`heap_zero_hack`, `heap_top_down_hack`) and nothing that tolerates a free of a
bad pointer. Any of these Wines would fault in the same place.

## The game's side

The frames above `RtlFreeHeap` are the game's code. Disassembled from
`eldenring.exe` (image base `0x140000000`) with `llvm-objdump`:

| Frame | Address | What the code is |
| --- | --- | --- |
| 3 | `+0x254cb4c` | The statically linked C runtime's `free`: `HeapFree(crt_heap, 0, p)`, with `crt_heap` = `0x140000` |
| 4 | `+0x2521db8` | Aligned free: rounds `p` down to 8, reads the original allocation address from `[p - 8]`, and frees that. **This read returns `0x3e80000ea60`.** |
| 5 | `+0x1f64450` | An allocator's `Free(p)`: takes the allocator's lock (`0x141ed8080`, timeout `-1`), then the aligned free, then unlocks |
| 6 | `+0x1ede340` | Destroys a held object Y: its destructor through the vtable, then `allocator->Free(Y)` (vtable `+0x68`), then clears the holder's pointer |
| 7 | `+0x1ede620` | A thin wrapper around 6 |
| 8 | `+0x24296d0` | The destructor of an object X: tears down its members at `+0xb0`, `+0x80`, `+0x68` and then **`+0x48`**, the holder in frames 7 and 6, before the base class |
| 9 | `+0x2429753` | X's deleting destructor |

So, during shutdown, X is destroyed; its member at `X+0x48` owns an object Y;
freeing Y reads `[Y - 8]`, where the allocator should have stored where Y's
allocation began, and finds `60000, 1000` there.

## What was ruled out

* **Heap corruption that Wine can detect.** Run with `WINEDEBUG=warn+heap`,
  which this Wine turns into parameter validation plus tail and free checking
  (`heap_set_debug_flags` in `heap.c`). The flags took effect, since the crash
  dump shows the heap's flags as `0x40000062` instead of `2`. The run logged no
  heap error at all before the crash. Tail checking also changes every heap
  block's size, and so the heap's layout, and the bad value was **identical**:
  `0x3e80000ea60` again. Bytes that a neighbouring block overran, or a freed
  block's reused contents, would have moved or changed.
* **Y being a static object.** The address `0x144847ad8`, which recurs in the
  stack dump, lies in the game's `.data` and was first read as Y. No
  instruction in the game refers to `0x144847a00`–`0x144847bff` (all of `.text`
  and `.interpr` searched, 322 references to that page, none there), and every
  copy of it on the stack sits beside `0x141ed80fe`, the return address inside
  the allocator's unlock. It is the allocator's lock, left on the stack by
  earlier lock and unlock calls, not the object being freed.
* **The runtime build.** A Homebrew-free rebuild targeting macOS 15 and the
  CI-built runtime crash the same way as the 2026-09-08 build.
* **Injected code.** It happens with nothing but the game and Wine loaded.
* **How the game is started.** It happens however the game is started.

## What is still open

* **What Y is.** The evidence fits Y not being the start of an allocation: an
  interior pointer, such as a base-class pointer at an offset from the start of
  the object (then `[Y - 8]` is one of the object's own fields, which would
  explain why the value never changes), or an object the holder never owned.
  Neither is shown.
* **Whether it is Wine-specific.** Nothing measured shows Windows behaving
  differently, and nothing shows it behaves the same.
* **Not connected to it, yet.** The same log has, before the crash, four
  `secur32:get_cipher_algid unknown algorithm 23` /
  `get_mac_algid unknown algorithm 200` lines from the game's TLS connections,
  and `wbemprox:enum_class_object_Next timeout not supported` from a WMI query.
  `60000` and `1000` look like timeouts in milliseconds. These are suspects for
  a subsystem that comes up differently under Wine, not findings.

## What would settle it

The value of Y and the memory around it, read when the crash happens. The crash
report gives only frame 0's registers and a partial stack, so that needs an
interactive debugger: have Wine open `winedbg` on the crash rather than
printing a report and exiting, then select frame 6, read its registers, and
dump `[Y - 0x20, Y + 0x20]`. The game carries anti-tamper code, and whether it
tolerates a debugger in this state is untested.
