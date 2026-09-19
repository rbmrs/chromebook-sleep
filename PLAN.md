# chromebook-sleep — Plan

Plugin id: `io.github.rbmrs.chromebook-sleep`

ChromeOS-style "shutdown from suspend" for Omarchy. The laptop sleeps normally (S3 deep sleep).
If it stays asleep longer than a user-defined time (hours or days), it wakes itself, powers off
cleanly, and stops draining the battery.

## Background: why this and not hibernation

Investigated 2026-09-19 on a Samsung Chromebook 4 (Google Bluebird/Octopus, Celeron N4020,
MrChromebox firmware 2606.1):

- **Hibernation is broken on this hardware.** It fails the same way on linux-omarchy 7.2.5,
  linux 7.2.3 and linux-lts 6.18.49. While the kernel copies memory into the snapshot, control
  jumps into the "resume" path. The `Image created` line is never logged, the kernel reports
  `Hibernation image restored successfully`, and it never writes an image to disk. With
  `systemctl hibernate`, this showed up as a frozen lock screen. The cause is at the
  firmware or hardware level, and there is no fix upstream.
- **ChromeOS never hibernated on this board.** It used S3 suspend. Its powerd daemon then did
  "shutdown from suspend": after a set time asleep (or when the battery got low), it woke the
  machine and powered it off. Once powered off, battery drain is close to zero.
- **S3 already works well on Linux.** Measured drain is about 2–3% per day. This plugin adds
  the missing piece, a timed power-off.

## How it works

```
lid closes ─► systemd-sleep "pre"  ─► remember the time; set an RTC wake alarm for now + LIMIT
                    ... S3 ...
wake       ─► systemd-sleep "post" ─► clear the alarm
                                      elapsed >= LIMIT (our alarm fired) and conditions met?
                                        yes ─► systemctl poweroff
                                        no  ─► normal resume (user opened the lid early)
```

- **Wake mechanism:** the RTC alarm, set through `/sys/class/rtc/rtc0/wakealarm` or `rtcwake -m no`.
  - On this machine `rtc0` is already an enabled wakeup source.
- **Detecting our own wake:** compare elapsed wall-clock time with the limit, allowing about 60 s
  of tolerance.
  - Wall-clock time keeps advancing during S3.
  - This approach needs no wake-reason API.
- **Scope:** the timer runs once per suspend.
  - Opening the lid early cancels it.
  - The next suspend starts a fresh countdown.
- **Suspend only:** the hook acts only on `suspend` and ignores hibernate and hybrid-sleep, so it
  cannot fight another setup.
- **Logging:** everything goes to the journal under `logger -t chromebook-sleep`.

## Components

Repo layout. The repo root is the plugin, as in `omarchy-smart-enter`, so that
`omarchy plugin add <git-url>` works:

```
chromebook-sleep/
├── manifest.json            # Omarchy shell plugin manifest (schemaVersion 1)
├── Panel.qml / Service.qml  # settings UI + status (kind decided in Phase 3)
├── system/
│   ├── chromebook-sleep.hook   # installed to /usr/lib/systemd/system-sleep/chromebook-sleep
│   ├── common.sh               # config parser + helpers, installed to /usr/lib/chromebook-sleep/
│   ├── chromebook-sleep        # CLI, installed to /usr/local/bin
│   ├── setup.sh                # installs the system parts (needs sudo)
│   └── uninstall.sh
├── tests/                   # hook-test.sh, cli-test.sh: run against a fake config/RTC/power_supply tree
├── README.md
├── LICENSE                  # MIT
└── preview.png
```

### 1. System hook (runs as root)
- Script: `/usr/lib/systemd/system-sleep/chromebook-sleep`.
- **`pre suspend`:**
  - Read the config.
  - If enabled, and not on AC while `ON_AC=skip`: arm the RTC alarm and write
    `<start> <limit-seconds> <on-ac>` to `/run/chromebook-sleep/state`.
    - The snapshot means config edits made while asleep don't change the current cycle.
- **`post suspend`:**
  - If the state file exists (we armed), disarm the alarm. A foreign alarm is left alone.
  - If elapsed time ≥ LIMIT − 30 s and the AC policy allows it (AC is checked again),
    log the decision and start the power-off.
  - The power-off is `systemctl start --no-block --job-mode=replace-irreversibly poweroff.target`,
    not `systemctl poweroff`. The latter goes through logind, which rejects it while the
    suspend operation is still in progress. Starting the target irreversibly is what logind
    does itself, and it also stops a lid-triggered re-suspend from replacing the power-off.
- **Safety:**
  - Never `source` the config. Parse it with strict regexes.
  - Treat invalid values as "disabled" and log a warning.

### 2. Config
- File: `/etc/chromebook-sleep.conf`.
- Owner and mode: `root:wheel`, mode `0664`.
  - The UI and CLI can edit it without sudo.
  - wheel users already have sudo, so this gives them nothing new.
  - The hook still validates every value.
- Contents:
  ```ini
  ENABLED=yes
  POWEROFF_AFTER=12h      # <number><m|h|d>, 2m–28d (rtc_cmos alarms reach one month ahead)
  ON_AC=skip              # skip = never power off while plugged in (ChromeOS behaviour) | poweroff
  ```
- No hidden default: `setup.sh` asks for the time on first install.

### 3. CLI: `chromebook-sleep`
- `status`: shows the config, whether the hook is installed, and the last decision from the journal.
- `set <duration>`, e.g. `set 8h`, `set 2d`: validates the value and writes the config.
- `enable`, `disable`.
- `on-ac skip|poweroff`.
- `test [duration]`: a guided short test, default 2m.
  - It never edits the config. With one `sudo`, it writes a one-shot duration to
    `/run/chromebook-sleep/test`.
  - The hook uses that file for the next suspend only, ignoring ENABLED and ON_AC, then deletes
    it. `/run` is cleared on reboot, so nothing needs restoring after the power-off.
- `status --json` is the interface for the QML UI.
- The config is rewritten in place with a single write, not temp+rename, because `/etc` isn't
  user-writable. A torn read counts as invalid config for that one cycle.

### 4. Shell plugin (QML)
- Settings UI:
  - An enable toggle.
  - Duration input with presets (4h, 12h, 1d, 3d) plus a custom number with an hours/days unit.
  - The AC policy.
  - Status, including "System hook not installed → [Install]".
- The UI reads and writes the config through the CLI (`Process`); it never writes the file directly.
- "Install" opens a terminal that runs `system/setup.sh`, because sudo needs a TTY.

## Phases

### Phase 0: Clean up this machine (one-time; not part of the plugin)
1. Set the UPower critical battery action to power off.
   - Currently `Auto` → hibernate, which hangs this machine.
   - Change `CriticalPowerAction=PowerOff` in `/etc/UPower/UPower.conf`.
   - Then run `systemctl restart upower`.
2. Remove the hibernation setup with `omarchy-hibernation-remove`.
3. Remove the boot setting that script leaves behind, `/etc/limine-entry-tool.d/resume.conf`, then
   run `sudo limine-mkinitcpio`.
4. Optionally remove `linux-lts`: `sudo pacman -Rns linux-lts`.
5. Update `~/dev/AGENTS.md`. It claims `suspend-then-hibernate` with a 15-minute delay, but no
   such config exists and hibernation doesn't work.
6. Verify:
   - `busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate`
     returns `"no"`.
   - The Hibernate item is gone from the Omarchy menu.

### Phase 1: Prove that RTC wake from S3 works
- Run `sudo rtcwake -m mem -s 60`. The laptop must wake by itself after about 60 s.
- Check `journalctl -k` for a clean S3 exit.
- If RTC wake does not work, stop and rethink the design.

### Phase 2: System hook + config + CLI
- Implement `system/`: the hook, the CLI and `setup.sh`/`uninstall.sh`.
- Test matrix (use a short LIMIT such as 2m):

  | Case | Expected |
  |---|---|
  | Lid closed > LIMIT, on battery | Wakes, powers off, journal shows the decision |
  | Lid opened before LIMIT | Normal resume, alarm cleared |
  | Lid closed > LIMIT, on AC, `ON_AC=skip` | Wakes briefly, re-suspends, no power-off |
  | Disabled / invalid config | Hook does nothing, warning logged |
  | Suspend from menu vs lid | Same behaviour |

- Decided (#3): with `ON_AC=skip`, don't arm the alarm while on AC; check AC in `pre`.
  - Consequence: unplugging during sleep doesn't start the timer. ChromeOS behaves the same way.
  - If the alarm fires but the machine was plugged in during sleep, it stays awake with the lid
    closed. #2 showed logind does not re-suspend on its own. Observe this in #6.

### Phase 3: Shell plugin UI
- Study the first-party plugins in `/usr/share/omarchy/shell/plugins/` (`panels`, `services`,
  `menu`) and pick the right `kind`, e.g. a panel or a menu entry.
- Build the settings UI on top of the CLI.
- Run `omarchy plugin validate .`.

### Phase 4: Publish
- Write the README:
  - What it does, and why it is not hibernation.
  - Install steps: `omarchy plugin add <url>`, then run setup.
  - Uninstall steps and troubleshooting.
- Add an MIT LICENSE and `preview.png`.
- Tag `v1.0.0` and push to GitHub (`rbmrs/chromebook-sleep`).
- Submit to the Omarchy plugins site.

## Later ideas (not v1)
- **Low-battery guard,** like ChromeOS dark resume.
  - Wake every N hours, check the battery, and power off below X%. Otherwise re-suspend.
- **Notify on next login** that the laptop was powered off after sleeping for N hours.
- **Naming:** the mechanism works on any laptop with RTC wake, not only Chromebooks. Mention this
  in the README.
