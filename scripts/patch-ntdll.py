#!/usr/bin/env python3
"""Binary-patch a prebuilt Wine 11.0 x86_64 ntdll.so (macOS) with the check_invalid_gsbase fix.

Only needed for engines based on Wine 11.0-11.3: upstream Wine fixed this in wine-11.4 (commit 6f6f66ee,
"ntdll: Don't fix gsbase on execution fault exception"), which skips the check for execute faults.

On macOS, Wine cannot read the faulting thread's %gs base, so check_invalid_gsbase() inspects the
instruction bytes at the faulting RIP. When an instruction straddles into an inaccessible page,
only its first byte(s) can be read; if those are prefix bytes (e.g. REX 0x48), the prefix loop runs
out of bytes and the function returns TRUE ("gs fault, fixed up") without ever seeing a %gs prefix.
Wine then swallows the access violation and retries the instruction forever. Diablo II: Resurrected's
protection decrypts code pages on demand through exactly such faults, so the game crawls/hangs.

The source fix (patches/0001-...) makes the function return FALSE unless a %gs prefix was seen.
For prebuilt engines we instead make the "instruction bytes read" path always return FALSE, i.e.
the %gs fix-up only stays active for faults in Wine's own syscall dispatchers (checked before this
point). On macOS the byte heuristic is unreliable anyway, because the gs base cannot be read.

The patched instruction is the length check right after virtual_uninterrupted_read_memory():
    mov   $0xffffffff, %edx
    and   %rax, %rdx
    je    <return FALSE>          ->  jmp <return FALSE>; nop
"""
import struct
import sys

PATTERN = bytes.fromhex("ba ffffffff 4821c2".replace(" ", ""))  # mov $-1,%edx ; and %rax,%rdx


def find_sites(data):
    sites, pos = [], 0
    while (i := data.find(PATTERN, pos)) >= 0:
        j = i + len(PATTERN)
        # preceded by "call rel32" to the read function, followed by "je rel32" (unpatched) or "jmp rel32; nop"
        # lea -0x40(%rbp),%rsi ; mov $0x10,%edx ; mov %r14,%rdi ; mov %rax,%rbx ; call virtual_uninterrupted_read_memory
        if (data[i - 20:i - 16] == bytes.fromhex("488d75c0") and data[i - 16:i - 11] == bytes.fromhex("ba10000000")
                and data[i - 8:i - 5] == bytes.fromhex("4889c3") and data[i - 5] == 0xE8):
            if data[j:j + 2] == b"\x0f\x84":
                sites.append((j, "unpatched"))
            elif data[j] == 0xE9 and data[j + 5] == 0x90:
                sites.append((j, "patched"))
        pos = i + 1
    return sites


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <ntdll.so> [--check]")
        return 2
    path, check_only = sys.argv[1], "--check" in sys.argv
    data = bytearray(open(path, "rb").read())
    sites = find_sites(data)
    if len(sites) != 1:
        print(f"{path}: expected exactly one patch site, found {len(sites)} - unsupported ntdll.so build, not patching")
        return 1
    off, state = sites[0]
    if state == "patched":
        print(f"{path}: already patched at {off:#x}")
        return 0
    if check_only:
        print(f"{path}: patch site found at {off:#x} (unpatched)")
        return 0
    rel = struct.unpack_from("<i", data, off + 2)[0]
    target = off + 6 + rel
    data[off:off + 6] = b"\xe9" + struct.pack("<i", target - (off + 5)) + b"\x90"
    open(path, "wb").write(data)
    print(f"{path}: patched je->jmp at {off:#x} (target {target:#x})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
