#!/usr/bin/env python3
"""Packaging-only repair using the exact previously CI-signed arm64e binary."""
import argparse, hashlib, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build as b

p = argparse.ArgumentParser()
p.add_argument('--input', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
old = a.input.read_bytes()
assert b.sha(old) == 'c965543cc0039e935ed41943cc0d4199a2da07811721d2a8003e268ee29412b9'
parts = b.ar_read(old)
old_data = b.tar_read(parts['data.tar.gz'])
files = {m.name.lstrip('./'): d for m, d in old_data if d is not None}
companion = 'Library/MobileSubstrate/DynamicLibraries/PhoneLifecycleFix.dylib'
assert b.sha(files[companion]) == '8a51e25221258633139a42e54d9774b15fdd21999c58959acfc3d0d09de3407d'
info = b.thin_info(files[companion]); assert info['subtype'] == 0x80000002
assert b.sha(b.VENDOR_DEB.read_bytes()) == b.VENDOR_DEB_SHA256
vendor = b.ar_read(b.VENDOR_DEB.read_bytes())
data = b.tar_read(next(v for k, v in vendor.items() if k.startswith('data.tar')))
control = b.tar_read(next(v for k, v in vendor.items() if k.startswith('control.tar')))
a.out.mkdir(parents=True, exist_ok=True)
b.DIST = a.out
b.BUILD = a.out / 'work'
b.BUILD.mkdir(exist_ok=True)
signed = b.BUILD / 'PhoneLifecycleFix-arm64e.dylib'
signed.write_bytes(files[companion])
path, result = b.build_package('arm64e', '', data, control, signed, info)
new_members = b.tar_read(b.ar_read(path.read_bytes())['data.tar.gz'])
new_files = {m.name.lstrip('./'): d for m, d in new_members if d is not None}
assert new_files == files, 'a payload changed during directory-only repair'
try:
    b.verify_directories(old_data)
except AssertionError:
    rejected_old = True
else:
    raise AssertionError('directory regression check did not reject the old package')
receipt = {'operation': 'packaging_only_no_compilation', 'packages': [result],
           'input_deb_sha256': b.sha(old), 'signed_ci_run': 44493615985,
           'all_10_payload_files_byte_identical': True,
           'old_package_rejected_by_directory_check': rejected_old,
           'directories': b.verify_directories(new_members),
           'runtime_tested': False, 'device_installed': False}
(a.out / 'verification.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(receipt, ensure_ascii=False, indent=2))
