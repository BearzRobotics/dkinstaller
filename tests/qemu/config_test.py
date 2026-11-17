#!/usr/bin/env python3
"""QEMU test of the post-install configuration (services, SSH, network, NTP,
firewall, SELinux mode, timezone, domain, the repository step and the chroot
shell helper), driven through an answers file. Needs no root.

    config_test.py --iso ISO --binary zig-out/bin/dkrescue-install [--firmware uefi|bios] [--workdir DIR]

The ISO's own dkrescue-install is replaced by BINARY (a static build of this
tree) through the seed disk. After the install it mounts the new system in the
live session and checks the files, runs `--chroot-run` and checks that its
effect persisted, then boots the installed disk and checks the same things
from inside it. Checks that need the next ISO (SELinux policy, a working
repository, WiFi) are listed in the output as SKIP with the reason.

Environment: LIVE_USER (default root), LIVE_PASS (default empty).
"""
import argparse, os, pathlib, shutil, subprocess, sys, tempfile
import pexpect
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import qemu_test as q

KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@host"
ANSWERS = """[install]
disk = vda
partitioning = auto

[system]
hostname = qemutest
domain = lab.test
root_hash = {hash}
user = tester
user_hash = {hash}
timezone = Europe/Berlin
keymap = us
ntp = true
firewall = false
selinux = enforcing

[services]
enable = cupsd
disable = greetd

[ssh]
enable = true
root_login = no
password_auth = false
authorized_key = {key}

[network]
mode = guided
iface = @IFACE@ static 10.0.2.15/24 10.0.2.2
dns = 10.0.2.3
search = lab.test

[packages]
install = no-such-package-dk
"""


def make_seed(work, binary):
    work = pathlib.Path(work)
    seed_dir = work / "seed"
    shutil.rmtree(seed_dir, ignore_errors=True)
    (seed_dir / "repo/apks/x86_64").mkdir(parents=True)
    pw = subprocess.run(["openssl", "passwd", "-6", "-salt", "qemusalt", "testpw"], check=True, capture_output=True, text=True).stdout.strip()
    (seed_dir / "answers.ini").write_text(ANSWERS.format(hash=pw, key=KEY))
    shutil.copy(binary, seed_dir / "dkrescue-install")
    (seed_dir / "repo/apks/x86_64/APKINDEX.tar.gz").write_text("not a real index\n")
    (seed_dir / "repo/apks/x86_64/test.pub").write_text("not a real key\n")
    seed = work / "seed.img"
    with open(seed, "wb") as f:
        f.truncate(64 * 1024**2)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "SEED", "-d", str(seed_dir), str(seed)], check=True)
    return seed


results = []


def check(name, ok, why=""):
    results.append((name, ok))
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  <- " + why))


def skip(name, why):
    print("SKIP " + name + "  (" + why + ")")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", required=True)
    ap.add_argument("--binary", required=True)
    ap.add_argument("--firmware", choices=["bios", "uefi"], default="uefi")
    ap.add_argument("--workdir")
    args = ap.parse_args()
    work = pathlib.Path(args.workdir or tempfile.mkdtemp(prefix="dkconfig-qemu-"))
    work.mkdir(parents=True, exist_ok=True)
    target, guard, _ = q.make_disks(work, False)
    seed = make_seed(work, args.binary)
    argv = q.qemu_argv(args.firmware, work, [target, guard, seed], iso=args.iso)
    argv += ["-nic", "user,model=virtio-net-pci"]
    child = q.spawn(argv, work / "serial.log")
    q.login(child)
    run = lambda c, t=60: q.run(child, c, t)
    if os.environ.get("LIVE_USER", "root") != "root":
        # The dkde ISO's `live` has an empty password and root is locked: sudo -s (wheel).
        child.sendline("sudo -s")
        i = child.expect(["assword", r"[#$]"], timeout=30)
        if i == 0:
            child.sendline(os.environ.get("LIVE_PASS", ""))
            child.expect(r"[#$]")
        import time; time.sleep(1)
        child.sendline("PS1='READ'\"Y> \"; stty -echo")
        child.expect("READY> ")

    run("mkdir -p /mnt/seed && mount -o ro /dev/vdc /mnt/seed && cp /mnt/seed/dkrescue-install /usr/sbin/dkrescue-install && chmod +x /usr/sbin/dkrescue-install")
    run("IF=$(ls /sys/class/net | grep -v '^lo$' | head -1); sed \"s/@IFACE@/$IF/\" /mnt/seed/answers.ini > /tmp/answers.ini; echo IFACE=$IF")
    out = run("grep -c . /tmp/answers.ini")
    child.sendline("dkrescue-install --answers /tmp/answers.ini --yes-really-erase vda --repo /mnt/seed/repo > /tmp/install.out 2>&1; echo EXIT=$?")
    child.expect(r"EXIT=(\d+)", timeout=q.INSTALL_TIMEOUT)
    code = child.match.group(1)
    run("tail -n 12 /tmp/install.out")
    install_out = run("cat /tmp/install.out", 60)
    check("install exits 0 (apk failure is only a warning)", code == "0", f"exit {code}: {install_out[-600:]}")
    check("the failed apk step is reported as a warning", "warning: Install 1 extra package" in install_out, install_out[-400:])
    check("the live user was removed by its real name", "userdel" in install_out)

    # Inspect the new system from the live session.
    run("mkdir -p /mnt/t && mount /dev/vda3 /mnt/t")
    def file(path):
        return run(f"cat /mnt/t{path} 2>&1")
    def has(cmd):
        r = run(f"{cmd} >/dev/null 2>&1; echo RC=$?")
        return "RC=0" in r
    check("hostname and hosts with the domain", "qemutest" in file("/etc/hostname") and "qemutest.lab.test qemutest" in file("/etc/hosts"))
    check("timezone link", "zoneinfo/Europe/Berlin" in run("readlink /mnt/t/etc/localtime"))
    boot = run("ls /mnt/t/etc/dinit.d/boot.d")
    check("cupsd enabled, greetd disabled, firewalld disabled, chronyd enabled, sshd enabled",
          "cupsd" in boot and "greetd" not in boot and "firewalld" not in boot and "chronyd" in boot and "sshd" in boot, boot)
    check("network services left as the image has them (guided)", "networkmanager" in boot, boot)
    dropin = file("/etc/ssh/sshd_config.d/10-dkinstall.conf")
    check("sshd drop-in", "PermitRootLogin no" in dropin and "PasswordAuthentication no" in dropin, dropin)
    check("sshd_config includes the drop-in directory", "Include /etc/ssh/sshd_config.d/" in file("/etc/ssh/sshd_config"))
    ak = run("ls -ln /mnt/t/home/tester/.ssh/authorized_keys; cat /mnt/t/home/tester/.ssh/authorized_keys; ls -ldn /mnt/t/home/tester/.ssh")
    uid = run("grep '^tester:' /mnt/t/etc/passwd | cut -d: -f3,4").strip()
    check("authorized_keys: key, mode 600, owned by the user", KEY in ak and "-rw-------" in ak and uid.split(":")[0] in ak and "drwx------" in ak, ak + " uid=" + uid)
    check("ssh host keys generated at install", has("test -f /mnt/t/etc/ssh/ssh_host_ed25519_key"))
    nm = run("ls -l /mnt/t/etc/NetworkManager/system-connections/; cat /mnt/t/etc/NetworkManager/system-connections/dk-*.nmconnection")
    check("NetworkManager connection: static, 0600", "address1=10.0.2.15/24,10.0.2.2" in nm and "-rw-------" in nm and "dns=10.0.2.3;" in nm, nm)
    check("log copied to the new system", has("test -s /mnt/t/var/log/dkrescue-install.log"))
    check("live user gone", "live:" not in run("cat /mnt/t/etc/passwd"))
    skip("SELinux mode written to /etc/selinux/config", "this ISO has no /etc/selinux/config; the step is skipped as designed; needs the next ISO")
    check("no stray .autorelabel without policy", not has("test -e /mnt/t/.autorelabel"))
    skip("apk install from a repository medium", "needs a real signed repository disc; here the apk step ran and failed softly on a fake index")

    # The chroot helper: a command runs in the target, the bind mounts are gone afterwards.
    run("umount /mnt/t; mkdir -p /run/dkrescue-install/target && mount /dev/vda3 /run/dkrescue-install/target")
    r = run("dkrescue-install --chroot-run 'echo from-shell > /etc/shell-ran; mount | grep -c \" /proc \" > /etc/shell-proc; sync'; echo CRC=$?")
    check("chroot helper ran the command", "CRC=0" in r, r)
    mounts = run("grep -c 'dkrescue-install/target/\\(proc\\|sys\\|dev\\|run\\)' /proc/mounts; true")
    check("bind mounts cleaned up afterwards", mounts.strip().splitlines()[-1].strip() == "0", mounts)
    check("the shell's change persisted in the target", "from-shell" in run("cat /run/dkrescue-install/target/etc/shell-ran"))
    run("umount /run/dkrescue-install/target")
    child.sendline("poweroff")
    child.expect(pexpect.EOF, timeout=120)

    # Boot the installed disk and look from inside.
    argv = q.qemu_argv(args.firmware, work, [target])
    argv += ["-nic", "user,model=virtio-net-pci"]
    child = q.spawn(argv, work / "boot.log")
    try:
        child.expect("login: ", timeout=q.LOGIN_TIMEOUT)
        child.sendline("root")
        child.expect("assword: ")
        child.sendline("testpw")
        child.expect(r"[#$]")
        import time; time.sleep(1)
        child.sendline("PS1='READ'\"Y> \"; stty -echo")
        child.expect("READY> ")
        check("installed system boots to a login", True)
        eff = run("sshd -T -f /etc/ssh/sshd_config 2>&1 | grep -E '^(permitrootlogin|passwordauthentication)'")
        check("sshd reads the drop-in (effective config)", "permitrootlogin no" in eff and "passwordauthentication no" in eff, eff)
        check("shell-test file persisted", "from-shell" in run("cat /etc/shell-ran"))
        svc = run("dinitctl list 2>&1 | grep -E 'sshd|chronyd|cupsd|firewalld|greetd'; true")
        print("     services in the booted system:\n" + "\n".join("       " + l for l in svc.strip().splitlines()))
        check("sshd started in the installed system", "sshd" in svc and "STARTED" in svc.split("sshd")[1][:40] if "sshd" in svc else False, svc)
        check("hostname in the booted system", "qemutest" in run("hostname"))
        child.sendline("poweroff")
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        check("installed system boots to a login", False, f"see {work}/boot.log")
    finally:
        child.close(force=True)
    print(f"workdir={work}")
    sys.exit(0 if all(ok for _, ok in results) else 1)


if __name__ == "__main__":
    main()
