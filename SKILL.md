---
name: serviceman
description: Deploy and manage system services with serviceman. Use when adding, checking, or managing daemons on Linux (systemd/OpenRC) or macOS (launchctl).
---

# serviceman Skill

## Install Check

```sh
command -v serviceman || curl -sS https://webi.sh/serviceman | sh
source ~/.config/envman/PATH.env
```

## Critical Rules

1. **Never `sudo serviceman`** — it sudo's internally. Running as root breaks
   user-context paths.
2. **`--` is required** before the command — without it, command flags bleed into
   serviceman's parser.
3. **`--workdir` must exist at add-time** (or pass `--force`).

## Add a Service

Auto-detection is safe. Use `--daemon` for always-on system boot services, `--agent`
for user login session services (not always-on).

```sh
serviceman add --name 'myapp' --workdir ~/srv/myapp -- ~/bin/myapp serve
```

## Output and Exit Codes

- Informational output (what serviceman is doing) goes to **stderr**
- `list` output goes to **stderr** — capture with `serviceman list 2>&1`
- Exit `0` = success; non-zero = error

## List Managed Services

```sh
# Show serviceman-managed services only (default)
serviceman list --daemon

# Show all services (not just serviceman-managed)
serviceman list --all --daemon
```

## Common Operations

```sh
# Restart
serviceman restart myapp --daemon

# View logs
serviceman logs myapp

# Disable (stop + remove from boot)
serviceman disable myapp --daemon
```

## sudoers for Passwordless Operation

```sudoers
# /etc/sudoers.d/serviceman
%wheel ALL=(ALL) NOPASSWD: /usr/bin/install
# OpenRC
%wheel ALL=(ALL) NOPASSWD: /sbin/rc-service
%wheel ALL=(ALL) NOPASSWD: /sbin/rc-update
# systemd
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl
```

`install` handles file placement and can be NOPASSWD. `rc-service`, `rc-update`,
and `systemctl` control running services and require sudo but can also be NOPASSWD.

## Manager Detection

- `--agent` — user login session; only runs while logged in (macOS default)
- `--daemon` — system boot service; always-on, survives logout (Linux default)

Auto-detection is safe for most deployments.
