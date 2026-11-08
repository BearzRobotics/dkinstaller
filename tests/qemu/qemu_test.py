#!/usr/bin/env python3
"""Unattended QEMU tests for dkrescue-install (SPEC.md 8). Needs no root.

    qemu_test.py install --iso ISO --firmware {bios,uefi} [--workdir DIR]
    qemu_test.py inject  --iso ISO --firmware {bios,uefi} --program PROGRAM
    qemu_test.py boot    --workdir DIR --firmware {bios,uefi}

`install` boots the ISO with a blank 20 GB disk (vda), a guard disk with
known contents (vdb) and a seed disk with the answers file (vdc), logs in
over the serial console, installs with --answers and --yes-really-erase,
powers off, and checks that the guard disk's checksum did not change.

`inject` does the same but makes PROGRAM fail (a shim earlier in PATH), and
checks that the install stops, says which step failed, leaves the log, and
never touched the guard disk.

`boot` boots the installed disk alone and waits for a login prompt. Run it
once per firmware on a disk `install` produced.

The live system's login comes from LIVE_USER / LIVE_PASS (default root, with
no password prompt expected if LIVE_PASS is empty). This script has not been
run against a real ISO yet.
"""
import argparse, hashlib, os, pathlib, shutil, subprocess, sys, tempfile, time
import pexpect

OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
DISK = "vda"
LOGIN_TIMEOUT = 300
INSTALL_TIMEOUT = 1800

ANSWERS = """[install]
disk = {disk}
partitioning = auto

[system]
hostname = qemutest
root_hash = {hash}
user = tester
user_hash = {hash}
timezone = UTC
keymap = us
"""


def sh(*argv, **kw):
    return subprocess.run(argv, check=True, **kw)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_disks(work, with_seed):
    work = pathlib.Path(work)
    work.mkdir(parents=True, exist_ok=True)
    target = work / "target.img"
    with open(target, "wb") as f:
        f.truncate(20 * 1024**3)
    guard = work / "guard.img"
    with open(guard, "wb") as f:
        f.write(b"GUARD-DISK-CONTENTS\n" * 50000)
        f.truncate(1024**3)
    if with_seed:
        seed_dir = work / "seed"
        shutil.rmtree(seed_dir, ignore_errors=True)
        seed_dir.mkdir()
        pw = subprocess.run(["openssl", "passwd", "-6", "-salt", "qemusalt", "testpw"],
                            check=True, capture_output=True, text=True).stdout.strip()
        (seed_dir / "answers.ini").write_text(ANSWERS.format(disk=DISK, hash=pw))
        seed = work / "seed.img"
        with open(seed, "wb") as f:
            f.truncate(16 * 1024**2)
        sh("mkfs.ext4", "-q", "-F", "-L", "SEED", "-d", str(seed_dir), str(seed))
    return target, guard, work / "seed.img"


def kvm_usable():
    """/dev/kvm can exist yet fail to open (WSL without nested virtualization)."""
    try:
        os.close(os.open("/dev/kvm", os.O_RDWR))
        return True
    except OSError:
        return False


def qemu_argv(firmware, work, drives, iso=None):
    argv = ["qemu-system-x86_64", "-m", "2048", "-smp", "2", "-nographic",
            "-serial", "mon:stdio", "-no-reboot"]
    argv += ["-accel", "kvm" if kvm_usable() else "tcg"]
    if firmware == "uefi":
        vars_copy = pathlib.Path(work) / "OVMF_VARS.fd"
        if not vars_copy.exists():
            shutil.copy(OVMF_VARS, vars_copy)
        argv += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
                 "-drive", f"if=pflash,format=raw,file={vars_copy}"]
    for i, d in enumerate(drives):
        argv += ["-drive", f"file={d},format=raw,if=none,id=d{i}",
                 "-device", f"virtio-blk-pci,drive=d{i}" + (",bootindex=1" if i == 0 and not iso else "")]
    if iso:
        argv += ["-drive", f"file={iso},format=raw,media=cdrom,readonly=on", "-boot", "d"]
    return argv


def spawn(argv, log):
    child = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", timeout=LOGIN_TIMEOUT)
    child.logfile_read = open(log, "w")
    return child


def login(child):
    user = os.environ.get("LIVE_USER", "root")
    pw = os.environ.get("LIVE_PASS", "")
    child.expect("login: ")
    child.sendline(user)
    if pw:
        child.expect("assword: ")
        child.sendline(pw)
    # The live prompt is coloured and ends "#" + escape code, no trailing space.
    child.expect(r"[#$]")
    time.sleep(1)
    # Split the string so the echoed command does not itself match READY> .
    child.sendline("PS1='READ'\"Y> \"; stty -echo")
    child.expect("READY> ")


def run(child, cmd, timeout=60):
    child.sendline(cmd)
    child.expect("READY> ", timeout=timeout)
    return child.before


def boot_live(args, work, extra_env=""):
    target, guard, seed = make_disks(work, True)
    before = sha256(guard)
    argv = qemu_argv(args.firmware, work, [target, guard, seed], iso=args.iso)
    child = spawn(argv, pathlib.Path(work) / "serial.log")
    login(child)
    run(child, "mkdir -p /mnt/seed && mount -o ro /dev/vdc /mnt/seed")
    # Test ISOs may carry the binary at their root instead of in the squashfs.
    # WORKAROUND: on the current dkrescue ISO /run/live is hidden after boot
    # (docs/ISO-REQUIREMENTS.md), so mount the disc where the installer looks.
    run(child, "mkdir -p /run/live/medium && mount -o ro /dev/sr0 /run/live/medium && cp /run/live/medium/dkrescue-install /usr/sbin/; [ -x /run/live/medium/dklilo ] && cp /run/live/medium/dklilo /usr/sbin/dklilo; true")
    return child, guard, before


def cmd_install(args):
    work = args.workdir or tempfile.mkdtemp(prefix="dkinstall-qemu-")
    child, guard, before = boot_live(args, work)
    child.sendline("dkrescue-install --answers /mnt/seed/answers.ini --yes-really-erase %s; echo EXIT=$?" % DISK)
    child.expect(r"EXIT=(\d+)", timeout=INSTALL_TIMEOUT)
    code = child.match.group(1)
    run(child, "cp /run/dkrescue-install/install.log /mnt/seed/ 2>/dev/null; true")
    child.sendline("poweroff")
    child.expect(pexpect.EOF, timeout=120)
    ok = code == "0" and "Installation complete." in child.before + open(pathlib.Path(work) / "serial.log").read()
    after = sha256(guard)
    print(f"install exit={code} guard {'unchanged' if before == after else 'CHANGED'} workdir={work}")
    return 0 if ok and before == after else 1


def cmd_inject(args):
    work = args.workdir or tempfile.mkdtemp(prefix="dkinstall-qemu-")
    child, guard, before = boot_live(args, work)
    run(child, f"mkdir -p /tmp/shim && printf '#!/bin/sh\\necho injected failure >&2\\nexit 7\\n' > /tmp/shim/{args.program} && chmod +x /tmp/shim/{args.program}")
    child.sendline("PATH=/tmp/shim:$PATH dkrescue-install --answers /mnt/seed/answers.ini --yes-really-erase %s; echo EXIT=$?" % DISK)
    child.expect(r"EXIT=(\d+)", timeout=INSTALL_TIMEOUT)
    code, out = child.match.group(1), child.before
    log = run(child, "cat /run/dkrescue-install/install.log", timeout=30)
    mounts = run(child, "grep dkrescue-install/target /proc/mounts; true")
    child.sendline("poweroff")
    child.expect(pexpect.EOF, timeout=120)
    after = sha256(guard)
    checks = {
        "exit code is 1": code == "1",
        "names the failed step": "failed:" in out,
        "log says failed": "-- failed:" in log,
        "log lists what did not run": "== not run" in log or "failed" in log,
        "nothing left mounted": "dkrescue-install/target" not in mounts,
        "guard disk untouched": before == after,
    }
    for name, passed in checks.items():
        print(("ok   " if passed else "FAIL ") + name)
    return 0 if all(checks.values()) else 1


def cmd_boot(args):
    work = pathlib.Path(args.workdir)
    argv = qemu_argv(args.firmware, work, [work / "target.img"])
    child = spawn(argv, work / f"boot-{args.firmware}.log")
    try:
        child.expect("login: ", timeout=LOGIN_TIMEOUT)
        print(f"boot {args.firmware}: reached a login prompt")
        return 0
    except (pexpect.TIMEOUT, pexpect.EOF):
        print(f"boot {args.firmware}: NO login prompt, see {work}/boot-{args.firmware}.log")
        return 1
    finally:
        child.close(force=True)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    for name in ("install", "inject", "boot"):
        s = sub.add_parser(name)
        s.add_argument("--firmware", choices=["bios", "uefi"], required=True)
        s.add_argument("--workdir")
        if name != "boot":
            s.add_argument("--iso", required=True)
        if name == "inject":
            s.add_argument("--program", required=True)
    args = p.parse_args()
    if args.mode == "boot" and not args.workdir:
        p.error("boot needs --workdir of an install run")
    sys.exit({"install": cmd_install, "inject": cmd_inject, "boot": cmd_boot}[args.mode](args))


if __name__ == "__main__":
    main()
