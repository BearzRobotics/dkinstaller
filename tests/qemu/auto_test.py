#!/usr/bin/env python3
"""QEMU test of the autoinstall path (docs/AUTOINSTALL.md). Needs no root.

    auto_test.py --iso ISO --binary zig-out/bin/dkrescue-install [--firmware uefi|bios] [--workdir DIR]

Boots the live ISO with a blank 20 GB disk (vda), a guard disk (vdb) and a
small second disk (vdc) holding `dkinstall.ini` and a copy of the binary.
In the live session the kernel command line is made to carry
`dkinstall.auto=1` (a bind mount over /proc/cmdline: nothing on the current
ISO starts the launcher or sets the flag at boot). `dkrescue-install --auto`
then has to find the file on the unmounted second disk by itself, pass the
gates, install without a screen, and power off (`when_done = poweroff`).
The installed disk is then booted and checked. Run it under
`nice -n 19 ionice -c3`, with --workdir on fast storage.
"""
import argparse, os, pathlib, shutil, subprocess, sys, tempfile, time
import pexpect
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import qemu_test as q

ANSWERS = """[install]
disk = largest
partitioning = auto
confirm_erase = /dev/vda
when_done = poweroff

[system]
hostname = autotest
root_hash = {hash}
user = tester
user_hash = {hash}
timezone = UTC
keymap = us

[post]
commands = echo ran-in-chroot > /etc/dk-post-ran
commands = sed -i 's/"ro quiet"/"ro console=tty0 console=ttyS0,115200"/' /boot/dklilo.conf
commands = ln -sfn ../ttyS0 /etc/dinit.d/boot.d/ttyS0
commands = false
"""

results = []


def check(name, ok, why=""):
    results.append(ok)
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  <- " + why))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", required=True)
    ap.add_argument("--binary", required=True)
    ap.add_argument("--firmware", choices=["bios", "uefi"], default="uefi")
    ap.add_argument("--workdir")
    args = ap.parse_args()
    work = pathlib.Path(args.workdir or tempfile.mkdtemp(prefix="dkauto-qemu-"))
    work.mkdir(parents=True, exist_ok=True)
    target, guard, _ = q.make_disks(work, False)
    before = q.sha256(guard)
    seed_dir = work / "seed"
    shutil.rmtree(seed_dir, ignore_errors=True)
    seed_dir.mkdir()
    pw = subprocess.run(["openssl", "passwd", "-6", "-salt", "qemusalt", "testpw"], check=True, capture_output=True, text=True).stdout.strip()
    (seed_dir / "dkinstall.ini").write_text(ANSWERS.format(hash=pw))
    shutil.copy(args.binary, seed_dir / "dkrescue-install")
    seed = work / "seed.img"
    with open(seed, "wb") as f:
        f.truncate(64 * 1024**2)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "ANYLABEL", "-d", str(seed_dir), str(seed)], check=True)

    argv = q.qemu_argv(args.firmware, work, [target, guard, seed], iso=args.iso)
    child = q.spawn(argv, work / "serial.log")
    q.login(child)
    run = lambda c, t=60: q.run(child, c, t)
    child.sendline("sudo -s")
    if child.expect(["assword", r"[#$]"], timeout=30) == 0:
        child.sendline("")
        child.expect(r"[#$]")
    time.sleep(1)
    child.sendline("PS1='READ'\"Y> \"; stty -echo")
    child.expect("READY> ")

    run("mkdir -p /mnt/s && mount -o ro /dev/vdc /mnt/s && cp /mnt/s/dkrescue-install /usr/sbin/dkrescue-install && chmod +x /usr/sbin/dkrescue-install && umount /mnt/s")
    out = run("dkrescue-install --auto; echo RC=$?")
    check("without dkinstall.auto=1 it does nothing and exits 0", "nothing to do" in out and "RC=0" in out, out)
    check("the seed disk is not mounted before the auto run", "/dev/vdc" not in run("grep vdc /proc/mounts; true"))
    run("cat /proc/cmdline > /tmp/cmdline; echo ' dkinstall.auto=1' >> /tmp/cmdline; tr -d '\\n' < /tmp/cmdline > /tmp/cmdline2; mount --bind /tmp/cmdline2 /proc/cmdline")
    check("the flag shows in /proc/cmdline", "dkinstall.auto=1" in run("cat /proc/cmdline"))
    child.sendline("dkrescue-install --auto 2>&1 | tee /tmp/auto.out; echo EXIT=${PIPESTATUS[0]}")
    i = child.expect([r"EXIT=(\d+)", pexpect.EOF], timeout=q.INSTALL_TIMEOUT)
    child.close(force=True)
    log = open(work / "serial.log").read()
    check("found the answers file on the unmounted second disk", "found dkinstall.ini on /dev/vdc" in log, log[-800:])
    check("the gates passed and it says which disk it erases", "erasing /dev/vda as the answers file confirms" in log)
    check("no screen was needed: installation completed", "Installation complete." in log, log[-1200:])
    check("the failing post command is only a warning", "warning: Post-install command: false" in log)
    check("it powered the machine off (when_done = poweroff)", i == 1 or "autoinstall: poweroff" in log)
    child.close(force=True)
    check("guard disk untouched", q.sha256(guard) == before)

    # Boot the installed disk (AHCI: the kernel has no initrd and no virtio-blk).
    argv = q.qemu_argv(args.firmware, work, [])
    argv += ["-drive", f"file={target},format=raw,if=none,id=sys", "-device", "ich9-ahci,id=ahci",
             "-device", "ide-hd,drive=sys,bus=ahci.0,bootindex=1", "-nic", "user,model=virtio-net-pci"]
    child = q.spawn(argv, work / "boot.log")
    try:
        child.expect("login: ", timeout=q.LOGIN_TIMEOUT)
        child.sendline("root")
        child.expect("assword: ")
        child.sendline("testpw")
        child.expect(r"[#$]")
        time.sleep(1)
        child.sendline("PS1='READ'\"Y> \"; stty -echo")
        child.expect("READY> ")
        check("installed system boots to a login", True)
        check("hostname", "autotest" in run("hostname"))
        check("the post command ran in the chroot", "ran-in-chroot" in run("cat /etc/dk-post-ran"))
        check("the user exists with a home", "tester" in run("ls /home"))
        child.sendline("poweroff")
    except (pexpect.TIMEOUT, pexpect.EOF):
        check("installed system boots to a login", False, f"see {work}/boot.log")
    finally:
        child.close(force=True)
    print(f"workdir={work}")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
