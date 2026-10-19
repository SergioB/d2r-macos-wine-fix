# Draft: WineHQ bug report / merge request

**Product:** Wine · **Component:** ntdll · **Platform:** macOS (x86_64, also under Rosetta 2)

**Title:** ntdll: check_invalid_gsbase() swallows access violations on instructions straddling an inaccessible page (macOS)

## Description

On macOS, `check_invalid_gsbase()` (dlls/ntdll/unix/signal_x86_64.c) cannot read the faulting thread's
gs base (`init_handler()` already reset it), so it falls back to decoding the instruction bytes at the
faulting RIP and treats the fault as a `%gs` fault if it finds a `0x65` prefix.

When the faulting instruction starts on the last byte of a readable page and continues into an
inaccessible page, `virtual_uninterrupted_read_memory()` returns only 1 byte. If that byte is a prefix
(REX `0x48` etc.), the prefix loop consumes it, exits because `i == len`, and the function falls through
to the "fixing up" path and returns TRUE, although no `%gs` prefix was seen. `segv_handler()` then
returns without raising the exception and the instruction faults again, forever.

Diablo II: Resurrected (build 93847, Battle.net) decrypts code pages on demand: it executes into
`PAGE_NOACCESS` pages of its own image and handles the resulting access violation. With this bug the
exception is never delivered; the main thread retries ~40,000 times per second and the game never starts
(black window). Instrumented trace:

```
segv-handled #4000 tid 0024 rip 0x1400a6fff addr 0x1400a7000   (err 8 = execute, page PROT_NONE)
```

On Linux the function returns early because the gs base can be read and equals the TEB.

## Fix

Only treat the fault as a gs fault if a `%gs` prefix was actually decoded:

```diff
+    BOOL gs_prefix = FALSE;
 ...
             case 0x65:  /* %gs: */
+                gs_prefix = TRUE;
                 break;
 ...
         }
+        if (!gs_prefix) return FALSE;
     }
```

(patches/0001-ntdll-check_invalid_gsbase-require-gs-prefix.patch). With it D2R starts in ~2 s.
Tested on Wine 11.0 (Porting Kit build) on macOS 26.6.2, Apple M3.
