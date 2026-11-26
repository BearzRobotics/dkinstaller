#!/usr/bin/env python3
"""Boot loader and root filesystem install test (SPEC.md 5.3.4, 5.6.8). Needs no root.

    loader_test.py --iso ISO --firmware {bios,uefi} --bootloader {dklilo,grub,systemd-boot}
                   [--root-fs ext4] --binary PATH-TO-dkrescue-install [--workdir DIR]

Boots ISO (the dkinstall-test image of dkbuild: base + GRUB + systemd-boot + the
filesystem tools) with a blank disk (vda) and a seed disk (vdb) that holds the answers
file and the installer binary under test, installs unattended, powers off, then boots
the installed disk ALONE and waits for a login prompt, logs in and prints what it came up
with (kernel command line, root filesystem, /boot). Exit 0 only if the install said
"Installation complete." and the installed system reached a login prompt.

The binary is built with: zig build --release=safe -Dtarget=x86_64-linux-musl -Dcpu=baseline
"""
import argparse, os, pathlib, shutil, subprocess, sys, tempfile, time
import pexpect

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import qemu_test as q  # qemu_argv, spawn

ANSWERS = """[install]
disk = "vda"
partitioning = "auto"
root_fs = "{root_fs}"
bootloader = "{bootloader}"

[system]
hostname = "qemutest"
root_hash = "{hash}"
user = "tester"
user_hash = "{hash}"
timezone = "UTC"
keymap = "us"
"""

INSTALL_TIMEOUT = 1800
# The first boot of a fresh install can be slow on a busy host (seen: over five minutes while the disk was saturated, 34 s the next time).
BOOT_TIMEOUT = 900


def sh(*argv, **kw):
    return subprocess.run(argv, check=True, **kw)


def make_disks(work, args):
    work = pathlib.Path(work)
    work.mkdir(parents=True, exist_ok=True)
    target = work / "target.img"
    with open(target, "wb") as f:
        f.truncate(12 * 1024**3)
    seed_dir = work / "seed"
    shutil.rmtree(seed_dir, ignore_errors=True)
    seed_dir.mkdir()
    pw = subprocess.run(["openssl", "passwd", "-6", "-salt", "qemusalt", "testpw"],
                        check=True, capture_output=True, text=True).stdout.strip()
    (seed_dir / "answers.toml").write_text(
        ANSWERS.format(hash=pw, root_fs=args.root_fs, bootloader=args.bootloader))
    shutil.copy(args.binary, seed_dir / "dkrescue-install")
    os.chmod(seed_dir / "dkrescue-install", 0o755)
    seed = work / "seed.img"
    with open(seed, "wb") as f:
        f.truncate(64 * 1024**2)
    sh("mkfs.ext4", "-q", "-F", "-L", "SEED", "-d", str(seed_dir), str(seed))
    return target, seed


def prompt(child):
    # Split the string so the echoed command does not itself match READY> .
    child.sendline("PS1='READ'\"Y> \"; stty -echo")
    child.expect("READY> ")


def run(child, cmd, timeout=60):
    child.sendline(cmd)
    child.expect("READY> ", timeout=timeout)
    return child.before


def stop(child):
    """Wait for the guest to power off; kill QEMU if it does not. Never raises."""
    try:
        child.expect(pexpect.EOF, timeout=120)
    except Exception:
        pass
    try:
        child.close(force=True)
    except Exception:
        try:
            os.kill(child.pid, 9)
        except Exception:
            pass


def live_login(child):
    child.expect("login: ")
    child.sendline("live")
    child.expect(r"[#$]")
    time.sleep(1)
    child.sendline("sudo -s")
    time.sleep(1)
    prompt(child)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", required=True)
    ap.add_argument("--firmware", choices=["bios", "uefi"], required=True)
    ap.add_argument("--bootloader", choices=["dklilo", "grub", "systemd-boot"], required=True)
    ap.add_argument("--root-fs", default="ext4")
    ap.add_argument("--binary", required=True)
    ap.add_argument("--workdir")
    args = ap.parse_args()
    work = pathlib.Path(args.workdir or tempfile.mkdtemp(prefix="dkloader-qemu-"))
    tag = f"{args.firmware}-{args.bootloader}-{args.root_fs}"
    print(f"== {tag}  workdir={work}")
    target, seed = make_disks(work, args)

    # 1. The live ISO: install.
    argv = q.qemu_argv(args.firmware, work, [target, seed], iso=args.iso)
    child = q.spawn(argv, work / "live.log")
    live_login(child)
    run(child, "mkdir -p /mnt/seed /run/live/medium && mount -o ro /dev/vdb /mnt/seed && "
               "mount -o ro /dev/sr0 /run/live/medium && cp /mnt/seed/dkrescue-install /tmp/ && chmod +x /tmp/dkrescue-install")
    run(child, "ls /usr/lib/grub /usr/lib/systemd/boot/efi 2>&1 | head -5; which mkfs.btrfs mkfs.xfs grub-install bootctl")
    child.sendline("/tmp/dkrescue-install --answers /mnt/seed/answers.toml --yes-really-erase vda > /tmp/inst.out 2>&1; echo EXIT=$?")
    child.expect(r"EXIT=(\d+)", timeout=INSTALL_TIMEOUT)
    code = child.match.group(1)
    child.expect("READY> ")
    out = run(child, "tail -60 /tmp/inst.out", timeout=60)
    (work / "install-output.txt").write_text(out)
    log = run(child, "tail -60 /run/dkrescue-install/install.log 2>&1", timeout=60)
    (work / "install-log-tail.txt").write_text(log)
    child.sendline("sync; poweroff")
    stop(child)
    done = "Installation complete." in out + log
    print(f"install: exit={code!r} complete={done}")
    if not done:
        print("---- installer output ----")
        print(out[-3000:])
        print("---- install log tail ----")
        print(log[-3000:])
        return 1

    # 2. The installed disk alone.
    argv = q.qemu_argv(args.firmware, work, [target])
    child = q.spawn(argv, work / "installed.log")
    try:
        child.expect("login: ", timeout=BOOT_TIMEOUT)
    except (pexpect.TIMEOUT, pexpect.EOF):
        print(f"BOOT FAILED: no login prompt; see {work}/installed.log")
        stop(child)
        return 1
    print("boot: reached a login prompt")
    child.sendline("tester")
    child.expect("assword: ")
    child.sendline("testpw")
    child.expect(r"[#$]")
    time.sleep(1)
    prompt(child)
    info = run(child, "uname -r; cat /proc/cmdline; findmnt -no SOURCE,FSTYPE,OPTIONS /; sudo findmnt -no TARGET,SOURCE,FSTYPE /boot /boot/efi 2>&1; sudo ls /boot | head -14")
    (work / "installed-info.txt").write_text(info)
    print(info)
    # Asked on their own, so nothing else in the output can match.
    rootfs = run(child, "findmnt -no FSTYPE /").strip()
    wanted = {"dklilo": "sudo test -f /boot/dklilo.conf",
              "grub": "sudo test -f /boot/grub/grub.cfg",
              "systemd-boot": "test \"$(findmnt -no FSTYPE /boot)\" = vfat && sudo test -d /boot/loader/entries"}[args.bootloader]
    loader_ok = "LOADER=0" in run(child, wanted + "; echo LOADER=$?")
    child.sendline("sudo poweroff")
    stop(child)
    ok = True
    if rootfs.splitlines()[-1:] != [args.root_fs]:
        print(f"FAIL: root is {rootfs!r}, not {args.root_fs}")
        ok = False
    if not loader_ok:
        print(f"FAIL: the installed system lacks what {args.bootloader} installs")
        ok = False
    print(f"RESULT {tag}: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
