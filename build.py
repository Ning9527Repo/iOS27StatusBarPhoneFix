#!/usr/bin/env python3
import copy, gzip, hashlib, io, json, os, plistlib, shutil, struct, subprocess, tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
BUILD = ROOT / "build"
VENDOR_DEB = ROOT / "vendor" / "statusbar-1.2-1.deb"
VENDOR_DEB_SHA256 = "b0004cd4fda700e66d5f9ea7f454576c1a3da40fe08df900987efce8ee86dde6"
ORIGINAL_DYLIB_SHA256 = "709baf93799bf42d9adb5efcc389e290f538aaf8c6d697a386d58481c8c83a77"
VERSION = "1.2-2"
COMPANION = "PhoneLifecycleFix"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(*args, cwd=ROOT):
    print("$", " ".join(map(str, args)), flush=True)
    p = subprocess.run([str(x) for x in args], cwd=cwd, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(p.stdout, end="", flush=True)
    if p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(map(str,args))}")
    return p.stdout


def ar_read(blob):
    assert blob[:8] == b"!<arch>\n"
    out, pos = {}, 8
    while pos < len(blob):
        header = blob[pos:pos + 60]
        assert len(header) == 60 and header[58:60] == b"`\n"
        size = int(header[48:58])
        name = header[:16].decode("ascii").strip().rstrip("/")
        out[name] = blob[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
    assert pos == len(blob)
    return out


def tar_read(blob):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tf:
        result = []
        for member in tf:
            data = tf.extractfile(member).read() if member.isfile() else None
            result.append((copy.copy(member), data))
        return result


def tar_write(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for original, data in entries:
            member = copy.copy(original)
            member.mtime = 0
            member.uid = member.gid = 0
            member.uname = member.gname = "root"
            if data is not None:
                member.size = len(data)
            tf.addfile(member, io.BytesIO(data) if data is not None else None)
    return gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)


def add_file(name, data, mode=0o644):
    member = tarfile.TarInfo("./" + name)
    member.mode = mode
    member.uid = member.gid = 0
    member.uname = member.gname = "root"
    member.mtime = 0
    member.size = len(data)
    return member, data


def add_dir(name, mode=0o755):
    member = tarfile.TarInfo("./" + name.rstrip("/") + "/")
    member.type = tarfile.DIRTYPE
    member.mode = mode
    member.uid = member.gid = 0
    member.uname = member.gname = "root"
    member.mtime = 0
    member.size = 0
    return member, None


def verify_directories(entries):
    seen = set()
    for member, data in entries:
        name = member.name.lstrip("./").rstrip("/")
        if not name:
            continue
        parent = Path(name).parent
        while parent != Path("."):
            assert parent.as_posix() in seen, "missing preceding directory: " + str(parent)
            parent = parent.parent
        if member.isdir():
            seen.add(name)
    return sorted(seen)


def mkdeb(control_entries, data_entries):
    out = bytearray(b"!<arch>\n")
    for name, payload in (("debian-binary", b"2.0\n"),
                          ("control.tar.gz", tar_write(control_entries)),
                          ("data.tar.gz", tar_write(data_entries))):
        header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n"
        out.extend(header.encode("ascii"))
        out.extend(payload)
        if len(payload) & 1:
            out.extend(b"\n")
    return bytes(out)


def thin_info(blob):
    if len(blob) < 12 or struct.unpack_from("<I", blob, 0)[0] != 0xfeedfacf:
        raise AssertionError("expected one thin 64-bit Mach-O")
    magic, cpu, subtype = struct.unpack_from("<III", blob, 0)
    assert magic == 0xfeedfacf and cpu == 0x0100000c
    return {"cpu": cpu, "subtype": subtype, "size": len(blob)}


def make_control(original, arch, installed_size):
    text = original.decode("utf-8")
    lines = []
    found_size = False
    for line in text.splitlines():
        if line.startswith("Architecture:"):
            line = "Architecture: " + arch
        elif line.startswith("Version:"):
            line = "Version: " + VERSION
        elif line.startswith("Installed-Size:"):
            line = "Installed-Size: " + str(installed_size)
            found_size = True
        lines.append(line)
    if not found_size:
        lines.append("Installed-Size: " + str(installed_size))
    return ("\n".join(lines) + "\n").encode("utf-8")

def build_companion(arch, sdk, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    dylib = out_dir / f"{COMPANION}-{arch}.dylib"
    clang = ["xcrun", "--sdk", "iphoneos", "clang", "-target", f"{arch}-apple-ios15.0",
             "-isysroot", sdk, "-dynamiclib", "-fobjc-arc", "-fblocks", "-O2",
             "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "src"),
             "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics",
             "-undefined", "dynamic_lookup", "-Wl,-install_name,@rpath/PhoneLifecycleFix.dylib",
             str(ROOT / "src" / "PhoneLifecycleFix.m"), "-o", str(dylib)]
    run(*clang)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", str(dylib))
    run("codesign", "--verify", "--strict", "--all-architectures", "--verbose=4", str(dylib))
    blob = dylib.read_bytes()
    info = thin_info(blob)
    expected_subtype = 0 if arch == "arm64" else 0x80000002
    assert info["subtype"] == expected_subtype, info
    return dylib, info


def build_package(arch, sdk, original_data, original_control, companion, info):
    stage = BUILD / arch
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    files = {}
    modes = {}
    for member, data in original_data:
        name = member.name.lstrip("./")
        if data is not None:
            files[name] = data
            modes[name] = member.mode
    original = files["Library/MobileSubstrate/DynamicLibraries/iOS27StatusBar.dylib"]
    assert sha(original) == ORIGINAL_DYLIB_SHA256
    companion_name = "Library/MobileSubstrate/DynamicLibraries/PhoneLifecycleFix.dylib"
    plist_name = "Library/MobileSubstrate/DynamicLibraries/PhoneLifecycleFix.plist"
    files[companion_name] = companion.read_bytes()
    plist = plistlib.dumps({"Filter": {"Bundles": ["com.apple.springboard"]}}, sort_keys=False)
    files[plist_name] = plist
    # dpkg requires explicit directory records; tar extraction alone may hide
    # missing parents by creating them implicitly. Preserve original modes too.
    directories = {}
    for member, data in original_data:
        if member.isdir():
            name = member.name.lstrip("./").rstrip("/")
            directories[name] = copy.copy(member)
        elif data is None:
            raise AssertionError("unsupported original entry: " + member.name)
    directories.setdefault("", add_dir("")[0])
    for name in files:
        parent = Path(name).parent
        while parent != Path("."):
            key = parent.as_posix()
            directories.setdefault(key, add_dir(key)[0])
            parent = parent.parent
    data_entries = [(directories[n], None) for n in
                    sorted(directories, key=lambda n: (len(Path(n).parts), n))]
    data_entries += [add_file(n, d, modes.get(n, 0o755 if n.endswith(".dylib") else 0o644))
                     for n, d in files.items()]
    installed_size = sum((len(d) + 1023) // 1024 for n, d in files.items())
    control = make_control(next(d for m, d in original_control if m.name.lstrip("./") == "control"),
                           "iphoneos-" + arch, installed_size)
    md5 = "".join(hashlib.md5(files[n]).hexdigest() + "  " + n + "\n"
                   for n in sorted(files))
    control_entries = [add_file("control", control), add_file("md5sums", md5.encode())]
    package = mkdeb(control_entries, data_entries)
    filename = f"com.local.ios27statusbar_{VERSION}_iphoneos-{arch}.deb"
    path = DIST / filename
    path.write_bytes(package)
    # Deserialize the exact archive and verify every payload, not only inputs.
    members = ar_read(package)
    got_entries = tar_read(members["data.tar.gz"])
    verified_dirs = verify_directories(got_entries)
    assert set(directories) - {""} == set(verified_dirs)
    assert {m.name.lstrip("./"): m.mode for m, d in got_entries if d is not None} == {
        n: modes.get(n, 0o755 if n.endswith(".dylib") else 0o644) for n in files}
    got = {m.name.lstrip("./"): d for m, d in got_entries if d is not None}
    assert got == files
    ctl = {m.name.lstrip("./"): d for m, d in tar_read(members["control.tar.gz"]) if d is not None}
    assert ctl["md5sums"].decode() == md5
    assert thin_info(got[companion_name])["subtype"] == info["subtype"]
    assert sha(got["Library/MobileSubstrate/DynamicLibraries/iOS27StatusBar.dylib"]) == ORIGINAL_DYLIB_SHA256
    return path, {"file": path.name, "size": path.stat().st_size,
                  "sha256": sha(package), "architecture": "iphoneos-" + arch,
                  "companion_sha256": sha(companion.read_bytes()),
                  "companion": info, "original_dylib_sha256": ORIGINAL_DYLIB_SHA256,
                  "version": VERSION, "layout": "original RootHide Library layout",
                  "runtime_tested": False, "installed": False}


def main():
    DIST.mkdir(exist_ok=True)
    if VENDOR_DEB_SHA256 != sha(VENDOR_DEB.read_bytes()):
        raise AssertionError("vendor deb changed")
    parts = ar_read(VENDOR_DEB.read_bytes())
    data_blob = next(v for k, v in parts.items() if k.startswith("data.tar"))
    control_blob = next(v for k, v in parts.items() if k.startswith("control.tar"))
    data_entries = tar_read(data_blob)
    control_entries = tar_read(control_blob)
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").strip()
    results = []
    for arch in ("arm64e",):
        companion, info = build_companion(arch, sdk, BUILD / ("companion-" + arch))
        _, result = build_package(arch, sdk, data_entries, control_entries, companion, info)
        results.append(result)
    receipt = {"source_sha256": sha((ROOT / "src" / "PhoneLifecycleFix.m").read_bytes()),
               "vendor_deb_sha256": VENDOR_DEB_SHA256,
               "original_dylib_sha256": ORIGINAL_DYLIB_SHA256,
               "packages": results, "runtime_tested": False, "installed": False}
    (DIST / "verification.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(receipt, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
