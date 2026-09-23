# frp-manager

A Bash script to install, update and manage [frp](https://github.com/fatedier/frp) (`frpc` and `frps`) on Linux – with an interactive menu, systemd service setup, checksum verification and automatic rollback.

It works with your existing setup: the script lives next to your frp binaries and never touches your `frpc.toml` / `frps.toml`.

## Features

- **Interactive menu** – see installed versions, service state and available updates at a glance
- **Install & update** `frpc` and `frps` to the latest release or a specific version
- **Checksum verification** against the official `frp_sha256_checksums.txt`
- **Automatic rollback** – if the service doesn't start with the new version, the previous binary is restored
- **systemd service setup** – installs a hardened unit, creates a dedicated `frp` system user and locks down config permissions
- Detects the CPU architecture automatically (`amd64`, `arm64`, `arm`, `386`, `riscv64`)
- Fully scriptable – every menu action is also available as a command (e.g. for cron)

## Requirements

- Linux with `bash`, `curl`, `tar`
- `systemd` for service management (updating the binary works without it)
- Root / `sudo` for everything except `status`

## Quick start

Download the script into your frp directory and start the menu:

```bash
sudo mkdir -p /opt/frp && cd /opt/frp
sudo curl -fsSLO https://raw.githubusercontent.com/YOUR_USER/frp-manager/main/frp-manager.sh
sudo chmod +x frp-manager.sh
sudo ./frp-manager.sh
```

### Run without downloading

You can also pipe the script straight into Bash. In that case the **current directory** is used as the frp directory, so `cd` into it first:

```bash
cd /opt/frp
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/frp-manager/main/frp-manager.sh | sudo bash
```

Pass commands after `-s --`, e.g. `... | sudo bash -s -- update server`.

> As with any `curl | bash` command: read the script before you run it.

## Usage

### Interactive menu

The menu only shows what is installed on the current machine – on a client you'll only see `frpc`, on a server only `frps`:

```
===== frp manager =====
  frp directory:  /opt/frp
  latest release: 0.71.0

  frpc   0.61.0          service: active, enabled       update available

  1) Update frpc
  2) Install specific frpc version
  3) Repair frpc service
  4) Remove frpc service
  q) Quit
```

If no frp installation is found, the menu offers to install either `frpc` or `frps`.

### Commands

```bash
./frp-manager.sh                                  # interactive menu
./frp-manager.sh status                           # versions, service state, updates
./frp-manager.sh update         [client|server]   # install or update the binary
./frp-manager.sh install-service client|server    # install and enable the systemd service
./frp-manager.sh remove-service [client|server]   # stop, disable and remove the service
```

`client` / `server` can be omitted if only one of them is installed – `sudo ./frp-manager.sh update` just updates whatever is there.

| Option            | Description                                                   |
| ----------------- | ------------------------------------------------------------- |
| `--version X.Y.Z` | Use a specific frp version (also works for downgrades)        |
| `--force`         | Reinstall even if the version is already up to date           |
| `--dir PATH`      | frp directory (default: the directory of the script)          |
| `-y`, `--yes`     | Answer all questions with yes (non-interactive)               |
| `-h`, `--help`    | Show help                                                     |

### Examples

```bash
sudo ./frp-manager.sh update server                    # update frps
sudo ./frp-manager.sh update client --version 0.61.0   # install a specific version
sudo ./frp-manager.sh install-service client           # set up frpc as a service
./frp-manager.sh status                                # no root needed
```

### Setting up a new machine

On a machine without frp, `install-service` does everything in one go: it offers to download the binary, installs the systemd unit, creates the `frp` user and starts the service.

```bash
cd /opt/frp
# create your frpc.toml first, then:
sudo ./frp-manager.sh install-service client
```

### Automatic updates (cron)

```cron
0 4 * * 1  /opt/frp/frp-manager.sh update -y >> /var/log/frp-manager.log 2>&1
```

## systemd services

The repository contains hardened unit files in `systemd/`:

- `frpc.service` – client
- `frps.service` – server

When installing a service, the script looks for the unit file next to itself (`systemd/<name>.service` or `<name>.service`) and falls back to downloading it from this repository. The units assume frp lives in `/opt/frp`; if you use a different directory, the paths are adjusted automatically.

During installation the script also:

1. creates the `frp` system user if the unit uses `User=frp`
2. sets the config to `root:frp` with mode `640` (it contains your token)
3. enables and starts the service, then checks that it's running

If a unit already exists and differs from the repository version, you'll see a diff and can decide whether to overwrite it. Removing a service keeps the binary and config.

> **frps on ports below 1024:** if `frps` binds ports like 80/443 directly, add `AmbientCapabilities=CAP_NET_BIND_SERVICE` to the `[Service]` section of `frps.service`, since it doesn't run as root.

## How an update works

1. Compare the installed version with the latest release (or `--version`)
2. Download `frp_<version>_linux_<arch>.tar.gz` and verify its SHA-256 checksum
3. Check that the new binary reports the expected version
4. Stop the service if it's running
5. Back up the current binary to `<name>.bak` and replace it atomically
6. Start the service and verify it's running – otherwise roll back to the backup

Logs: `journalctl -u frpc -n 50` (or `frps`).

### Manual rollback

```bash
sudo systemctl stop frps
sudo mv /opt/frp/frps.bak /opt/frp/frps
sudo systemctl start frps
```

## Configuration

Settings at the top of `frp-manager.sh`:

| Variable             | Default                   | Description                                                  |
| -------------------- | ------------------------- | ------------------------------------------------------------ |
| `FRP_DIR`            | directory of the script   | Where the binaries and configs live (also via env or `--dir`) |
| `KEEP_BACKUP`        | `true`                    | Keep the old binary as `<name>.bak` (required for rollback)  |
| `SERVICE_SOURCE_URL` | this repository           | Where unit files are downloaded from if not found locally    |

## Repository layout

```
frp-manager/
├── frp-manager.sh
├── systemd/
│   ├── frpc.service
│   └── frps.service
├── README.md
└── LICENSE
```

## Tip

Update the server (`frps`) first, then the clients. frp generally tolerates small version differences, but keeping both close together avoids surprises.

## License

MIT