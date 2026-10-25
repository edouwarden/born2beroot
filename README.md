# Born2beroot

A reproducible, hardened Debian virtual machine built for the 42
**Born2beroot** project. The repository contains the unattended installer
configuration and the hardening scripts used to produce the VM; it is a
mirror of the submission kept on 42's Vogsphere.

## What the VM provides

| Requirement | Implementation |
| --- | --- |
| Operating system | Debian (see `installer/preseed.cfg`) |
| Disk encryption | LUKS on the whole disk, LVM volume group `LVMGroup` |
| Partitioning | `/boot`, `/`, `/home`, `/var`, `/srv`, `/tmp`, `/var/log`, swap |
| SSH | Port `4242`, root login disabled |
| Firewall | UFW, deny incoming by default, only SSH exposed |
| Password policy | `pam_pwquality`, 10 characters minimum, 30-day expiry |
| Privilege escalation | `sudo` with attempt limits, I/O logging, TTY requirement |
| Intrusion prevention | fail2ban |
| Monitoring | Broadcasts system metrics with `wall` every 10 minutes |

## Repository layout

```
.
├── installer/
│   ├── preseed.cfg      # unattended Debian installation (LUKS + LVM)
│   ├── isolinux.cfg     # boot menu entry point
│   ├── menu.cfg         # Debian installer menu
│   └── txt.cfg          # automated install entry
├── scripts/
│   ├── post_install.sh  # SSH, UFW, PAM, sudo, fail2ban, monitoring
│   └── monitoring.sh    # wall broadcast consumed by monitoring.service
└── README.md
```

## Building the VM

1. Download a Debian netinst ISO and copy it to a working directory.
2. Repack the ISO with the installer files at its root:

   ```bash
   mkdir -p iso
   xorriso -osirrox on -indev debian.iso -extract / iso
   cp installer/preseed.cfg installer/isolinux.cfg installer/menu.cfg installer/txt.cfg iso/
   cp scripts/post_install.sh scripts/monitoring.sh iso/
   chmod -w iso/isolinux/isolinux.bin
   xorriso -as mkisofs \
       -o born2beroot.iso -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
       -c isolinux/boot.cat -b isolinux/isolinux.bin -no-emul-boot \
       -boot-load-size 4 -boot-info-table -eltorito-alt-boot \
       -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat iso
   ```

   `installer/isolinux.cfg` selects `install-auto` from `installer/txt.cfg`
   with `auto=true ... file=/cdrom/preseed.cfg`.

3. Create a VM with a single disk (`/dev/sda`, 30 GB or more) and boot the
   ISO. The installation runs unattended and reboots into the hardened
   system.

> The UI-based installation path is still available from the same ISO if
> the automated boot entry is skipped.

Adjust the values marked `CHANGE ME` in `installer/preseed.cfg` (passwords,
mirror suite) before building the ISO.

## Security configuration

### SSH

```
Port 4242
PermitRootLogin no
```

Root connects only through `sudo`. `sshd -t` validates the configuration
before the service is restarted.

### Firewall

`ufw` starts from a clean state, denies incoming traffic by default and
opens only the SSH port. No other service is exposed.

### Password policy

`pam_pwquality.so` is inserted before `pam_unix.so` in
`/etc/pam.d/common-password`:

```
retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 difok=7 reject_username enforce_for_root
```

`/etc/login.defs` enforces a 30-day maximum password age, a 2-day minimum
and a 7-day warning period.

### sudo

Configuration lives in `/etc/sudoers.d/42-hardening` and is validated with
`visudo -cf` before being kept:

```
Defaults passwd_tries=3
Defaults badpass_message="..."
Defaults logfile="/var/log/sudo/sudo.log"
Defaults log_input, log_output
Defaults iolog_dir="/var/log/sudo"
Defaults requiretty
Defaults use_pty
Defaults secure_path="..."
```

Every sudo session is recorded in `/var/log/sudo`, whose permissions are
`0700 root:root`.

## Monitoring

`monitoring.sh` is installed as `/usr/local/bin/monitoring.sh` and started by
`monitoring.service` (`Restart=always`). It writes the required summary to
every logged-in terminal:

```
---------------- SYSTEM MONITORING ----------------
#Architecture: Linux enormand42 6.1.0-18-amd64 ...
#CPU physical: 1
#vCPU: 1
#Memory Usage: 512/1024MB (50.00%)
#Disk Usage: 8/30Gb (26%)
#CPU load: 3.4%
#Last boot: 2024-03-01 10:22
#LVM use: yes
#Connections TCP: 2 ESTABLISHED
#User log: 1
#Network: IP 10.0.2.15 (08:00:27:aa:bb:cc)
#Sudo: 12 cmd
----------------------------------------------------
```

The interval defaults to 600 seconds and can be overridden with the
`INTERVAL` environment variable.

Run it on demand:

```bash
sudo INTERVAL=5 /usr/local/bin/monitoring.sh   # demo mode, Ctrl-C to stop
```

## Verification

```bash
# SSH
ss -tlnp | grep 4242
sudo sshd -T | grep -E '^(port|permitrootlogin)'

# Firewall
sudo ufw status verbose

# Password policy
grep pam_pwquality /etc/pam.d/common-password
grep -E '^PASS_(MAX|MIN)_DAYS|^PASS_WARN_AGE' /etc/login.defs

# sudo
sudo visudo -c
sudo -l

# LVM
lsblk
sudo lvs

# Monitoring
systemctl status monitoring.service
journalctl -u monitoring.service -n 20
```

## Notes and limitations

* The preseed targets a BIOS/legacy boot on a single `/dev/sda` disk; adapt
  the partitioning section for UEFI or a different device.
* `mirror/suite` must match the Debian release of the ISO. The value is
  pinned to `bookworm`; change it for older or newer images.
* Passwords in `installer/preseed.cfg` are placeholders and must be changed
  before building an ISO.
* The 42 signature of the virtual disk is intentionally not versioned.

## References

* Debian GNU/Linux installation guide - preseed:
  <https://www.debian.org/releases/stable/amd64/apbs02.en.html>
* `pam_pwquality(8)`: <https://manpages.debian.org/bookworm/libpam-pwquality/pam_pwquality.8.en.html>
* `sudoers(5)`: <https://manpages.debian.org/bookworm/sudo/sudoers.5.en.html>
* UFW: <https://help.ubuntu.com/community/UFW>
