# serviceman — Agent Instructions

serviceman is a POSIX shell script that registers services with launchctl (macOS),
systemd (Linux), or OpenRC (Alpine/Gentoo/Devuan).

For **using** serviceman as a tool in other projects, see [SKILL.md](SKILL.md).

## Repo Layout

```
bin/serviceman            The entire tool — one POSIX shell script
share/serviceman/         Service file templates
  template.agent.plist    macOS launchctl agent
  template.daemon.plist   macOS launchctl daemon
  template.logrotate      logrotate config
  template.openrc         OpenRC init script
  template.system.service systemd system unit
  template.user.service   systemd user unit
```

## Version Bump

`bin/serviceman` lines 7–8:

```sh
g_version='v1.0.0'
g_date='2026-04-21T00:28-06:00'
```

Date format: ISO 8601 with UTC offset (`YYYY-MM-DDTHH:MM±HH:MM`).
Bump both on every release commit.

## Branch Rules

- **Never commit directly to `main`.** All changes go through a PR branch.
- Merges are **ff-only** — no merge commits, no squash.
- Branch naming: `feat/`, `fix/`, `docs/`, `chore/` prefixes.

## Testing Changes

Run `serviceman` directly — no build step required. Install via webi if needed:

```sh
source ~/.config/envman/PATH.env
serviceman add --name 'myapp' --workdir ~/srv/myapp --daemon -- ~/bin/myapp serve
serviceman list --all --daemon
```

Test on the relevant platform (macOS for launchctl, Linux for systemd/OpenRC).
There are no automated tests — manual verification on the target OS is required.

## Non-Obvious Facts

1. **Never `sudo serviceman`** — it sudo's internally. Running as root breaks
   user-context paths.
2. **`--` is required** before the command — without it, command flags bleed into
   serviceman's parser.
3. **`--workdir` must exist at add-time** (or pass `--force`).
4. **`--agent`** runs only during user login sessions (not always-on); **`--daemon`**
   runs at system boot and survives logout. Auto-detection is safe for most cases.
5. **`list` only shows serviceman-managed services** by default (greps for
   "Generated for serviceman"). Pass `--all` to see everything.
6. **NOPASSWD**: `install`, `rc-service`, `rc-update`, and `systemctl` can all be
   granted NOPASSWD — see README for the sudoers snippet.
7. **`list` writes to stderr** in v1.0.0 — capture with `2>&1` or redirect; stdout
   is empty. Exit codes: `0` success, non-zero on error.
