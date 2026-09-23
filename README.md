# frp-manager

A Bash script to install, update and manage [frp](https://github.com/fatedier/frp) (`frpc` and `frps`) on Linux – with an interactive menu, systemd service setup, checksum verification and automatic rollback.

The script lives next to your frp binaries in `/opt/frp`. It runs frp as an unprivileged `frp` user and keeps config and state in `/opt/frp/config/` – see [Directory layout & security](#directory-layout--security).

## Features

- **Interactive menu** – see installed versions, service state and available updates at a glance
- **Install & update** `frpc` and `frps` to the latest release or a specific version
- **Checksum verification** against the official `frp_sha256_checksums.txt`
- **Automatic rollback** – if the service doesn't start with the new version, the previous binary is restored
- **systemd service setup** – installs a hardened unit, creates a dedicated `frp` system user, locks down permissions and migrates old setups
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
sudo curl -fsSLO https://raw.githubusercontent.com/BlueFire023/frp-manager/main/frp-manager.sh
sudo chmod +x frp-manager.sh
sudo ./frp-manager.sh
```

### Run without downloading

You can also pipe the script straight into Bash. In that case the **current directory** is used as the frp directory, so `cd` into it first:

```bash
cd /opt/frp
curl -fsSL https://raw.githubusercontent.com/BlueFire023/frp-manager/main/frp-manager.sh | sudo bash
```

Pass commands after `-s --`, e.g. `... | sudo bash -s -- update server`.

> As with any `curl | bash` command: read the script before you run it.

## Usage

### Interactive menu

The menu only shows what is installed on the current machine – on a client you'll only see `frpc`, on a server only `frps`:

```
===== frp manager =====
  frp directory:  /opt/frp
  config dir:     /opt/frp/config
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
# create /opt/frp/config/frpc.toml first, then:
sudo ./frp-manager.sh install-service client
```

### Automatic updates (cron)

```cron
0 4 * * 1  /opt/frp/frp-manager.sh update -y >> /var/log/frp-manager.log 2>&1
```

## Directory layout & security

frp runs as a dedicated, unprivileged system user called **`frp`** – not as root. frpc is the component that passes traffic from the internet into your network, so if it ever had a vulnerability, an attacker would only get the rights of this user instead of the whole machine.

```
/opt/frp/                         root:root  755
├── frpc  (or frps)               root       read-only for the service
├── frpc.bak                      previous version (rollback)
├── frp-manager.sh
└── config/                       frp:frp    700
    ├── frpc.toml                 frp        600  (contains your token)
    └── frpc_store.json           frp        600  (only if store is enabled)
```

**Why it's split like this:**

- The **binaries** belong to root. The `frp` user can neither modify nor replace them – that's why `/opt/frp` itself must be owned by root, not by `frp`.
- The **`config/` directory** belongs to `frp`, because frpc writes to it: the store file (proxies created at runtime) and config changes made through the admin UI.
- The systemd unit makes the entire file system read-only for the service (`ProtectSystem=strict`) and only unlocks `config/` via `ReadWritePaths`.

**What the `frp` user does *not* need:**

- **No sudo / root to reach your services.** frpc only opens normal TCP/UDP connections to `localIP:localPort`, which any user may do. Docker-published ports (`-p 9000:9000`) listen on the host and are reachable as well. Quick test: `sudo -u frp curl -I http://127.0.0.1:9000`
- **No Docker group.** Container names (e.g. `localIP = "portainer"`) can't be resolved on the host anyway – use `127.0.0.1` and the published port.

**Exception – frps on ports below 1024:** if `frps` binds ports like 80/443 directly, uncomment `AmbientCapabilities=CAP_NET_BIND_SERVICE` in `frps.service`. Connecting *to* such ports never needs this.

### Working with the config

```bash
sudo nano /opt/frp/config/frpc.toml                  # the directory is 700, so sudo is needed
sudo /opt/frp/frpc verify -c /opt/frp/config/frpc.toml
sudo systemctl restart frpc
```

Always use **absolute paths** inside the TOML (`store.path`, TLS certificates, `includes`). Relative paths are resolved against the service's working directory, not the config file:

```toml
store.path = "/opt/frp/config/frpc_store.json"
```

## systemd services

The repository contains hardened unit files in `systemd/` (`frpc.service`, `frps.service`). When installing a service, the script looks for the unit file next to itself (`systemd/<name>.service` or `<name>.service`) and falls back to downloading it from this repository. If frp lives somewhere other than `/opt/frp`, the paths are adjusted automatically.

`install-service` (menu: *Install / Repair service*) sets up everything described above:

1. creates the `frp` system user if it doesn't exist
2. stops the running service
3. **migrates an old setup:** moves `frpc.toml` from `/opt/frp` into `config/`, moves the store file there too and rewrites `store.path` to an absolute path
4. sets the ownership and permissions shown in the layout above
5. installs the unit, checks the config with `frpc verify` and (re)starts the service

If a unit already exists and differs from the repository version, you'll see a diff and can decide whether to overwrite it. Running it again on an already migrated setup is safe – it just re-applies the permissions. Removing a service keeps the binary and config.

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