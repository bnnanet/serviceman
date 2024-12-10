# [Serviceman](https://github.com/bnnanet/serviceman-sh)

Cross-platform service management made easy.

```sh
serviceman add --name 'api' -- node ./server.js
```

# Table of Contents

-   [Why?](#why)
-   [Install](#install)
    -   [Webi](#webi)
    -   [Manual](#manual)
-   [Usage](#usage)
    -   [Help](#help)
    -   [add](#add)
-   [Changes in v1\.0](#changes-in-v10)

# Why?

To have a daemon manager that Just Works™

(because it sucks to debug `launchctl`, `systemd`, and `openrc`)

# Install

## Webi

```sh
curl -sS https://webi.sh/serviceman | sh
source ~/.config/envman/PATH.env
```

## Manual

1. Clone
    ```sh
    mkdir -p ~/.local/opt/
    git clone https://github.com/bnnanet/serviceman-sh ~/.local/opt/serviceman
    ```
2. Add to `PATH`
    ```sh
    echo 'export PATH="$HOME/.local/opt/serviceman/bin:$PATH"' >> ~/.profile
    ```

# Usage

```sh
serviceman add --name 'foo' -- foo --bar ./baz/
```

## Help

```text
USAGE
    serviceman <subcommand> --help

EXAMPLES
    serviceman add --name 'foo' -- ./foo-app --bar
    serviceman list --all
    serviceman logs 'foo'

    serviceman disable 'foo'
    serviceman enable 'foo'
    serviceman start 'foo'
    serviceman stop 'foo'
    serviceman restart 'foo'

    serviceman help
    serviceman version

GLOBAL FLAGS
    --help can be used with any subcommand
    --daemon (Linux, BSD default)  act as system boot service (sudo)
    --agent (macOS default)  act as user login service
```

## add

```text
USAGE
    serviceman add [add-opts] -- <command> [command-opts]

FLAGS
    --no-cap-net-bind (Linux only)  do not set cap net bind for privileged ports
    --dryrun  output service file without modifying disk
    --force  install even if command or directory does not exist
    --daemon (Linux, BSD default)  sudo, install system boot service
    --agent (macOS default)  no sudo, install user login service
    --  stop reading flags (to prevent conflict with command)

OPTIONS
    --name <name>  the service name, defaults to binary, or otherwise workdir name
    --desc <description>  a brief description of the service
    --group <groupname>  defaults to 'staff'
    --path <PATH>  defaults to current $PATH value (set to '' to disable)
    --rdns <reverse-domain> (macOS only)  set launchctl rdns name
    --title <title>  the service name, stylized
    --url <link-to-docs>  link to documentation or homepage
    --user <username>  defaults to 'aj'
    --workdir <dirpath>  where the command runs, defaults to current directory

DEPRECATED (DO NOT USE)
    --system  alias of --daemon, for compatibility
    --username  alias of --user, for compatibility
    --groupname  alias of --group, for compatibility

EXAMPLES
    caddy:   serviceman add -- caddy run --envfile ./.env --config ./Caddyfile --adapter caddyfile
    node:    serviceman add --workdir . --name 'api' -- node ./server.js
    pg:      serviceman add --workdir ~/.local/share/postgres/var -- postgres -D ~/.local/share/postgres/var -p 5432
    python:  serviceman add --name 'thing' -- python3 ./thing.py
    shell:   serviceman add --name 'foo' -- ./foo.sh --bar ./baz
```

# Changes in v1.0

-   add OpenRC (Alpine Linux) support
-   rewritten as a POSIX script
-   `--agent` is the default for macOS
-   `--daemon` (previously `--system`) is the default for Linux
    -   `sudo` is used internally to add and manage service files
-   `$PATH` is mirrored by default

In short, this common pattern:

```sh
sudo env PATH="$PATH" \
    serviceman add --path "$PATH" --system --name 'foo' \
    -- foo --bar ./baz/qux
```

Becomes much simpler:

```sh
serviceman add --name 'foo' -- foo --bar ./baz/qux
```

# Legal

[serviceman](https://github.com/bnnanet/serviceman) |
MPL-2.0 |
[Terms of Use](https://therootcompany.com/legal/#terms) |
[Privacy Policy](https://therootcompany.com/legal/#privacy)

Copyright 2019-2024 AJ ONeal.
