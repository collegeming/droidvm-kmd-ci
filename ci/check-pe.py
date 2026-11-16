#!/usr/bin/env python3
"""Fail unless the given PE image is an ARM64 native (kernel) DLL."""
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()
if data[:2] != b"MZ":
    sys.exit("not a PE: missing MZ signature")
pe = struct.unpack_from("<I", data, 0x3C)[0]
if data[pe:pe + 4] != b"PE\0\0":
    sys.exit("not a PE: missing PE signature")
machine = struct.unpack_from("<H", data, pe + 4)[0]
opt = pe + 24
magic = struct.unpack_from("<H", data, opt)[0]
entry_rva = struct.unpack_from("<I", data, opt + 0x10)[0]
image_base = struct.unpack_from("<Q", data, opt + 0x18)[0]
size_of_image = struct.unpack_from("<I", data, opt + 0x38)[0]
subsystem = struct.unpack_from("<H", data, opt + 0x44)[0]
dll_char = struct.unpack_from("<H", data, opt + 0x46)[0]

print(f"file={path}")
print(f"machine=0x{machine:04X}")
print(f"optional_magic=0x{magic:04X}")
print(f"entry_rva=0x{entry_rva:X} entry_va=0x{image_base + entry_rva:X}")
print(f"image_base=0x{image_base:X} size_of_image=0x{size_of_image:X}")
print(f"subsystem={subsystem} dll_characteristics=0x{dll_char:04X}")

errors = []
if machine != 0xAA64:
    errors.append(f"expected machine 0xAA64 (ARM64), got 0x{machine:04X}")
if magic != 0x20B:
    errors.append(f"expected PE32+ optional header 0x20B, got 0x{magic:04X}")
if subsystem != 1:
    errors.append(f"expected subsystem 1 (NATIVE), got {subsystem}")
if entry_rva == 0:
    errors.append("entry RVA is zero (missing /ENTRY:driver_entry)")
if errors:
    sys.exit("PE validation failed: " + "; ".join(errors))
print("PE validation: OK")
