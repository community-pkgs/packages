# Valkey APT Repository

[Valkey](https://valkey.io) is a high-performance, open-source key-value data store —
a community-driven fork of Redis, licensed under BSD 3-Clause.

This repository provides **unofficial** Debian/Ubuntu `.deb` packages for Valkey,
built automatically from official upstream releases and published as an APT repository
via GitHub Pages.

---

## Supported Distributions

| Distribution | Codename | Architecture |
| ------------ | -------- | ------------ |
| Debian 13 | `trixie` | `amd64` |
| Ubuntu 24.04 LTS | `noble` | `amd64` |

---

## Packages

| Package            | Description                                                                 |
|--------------------|-----------------------------------------------------------------------------|
| `valkey-server`    | The Valkey server daemon                                                    |
| `valkey-sentinel`  | Valkey Sentinel — high availability monitoring and automatic failover       |
| `valkey-tools`     | Client tools: `valkey-cli`, `valkey-benchmark`, `valkey-check-aof`         |

---

## Installation

Replace `<PAGES_URL>` with the actual APT repository URL (e.g. `https://username.github.io/repo`).

### 1. Add the GPG signing key

```sh
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://github.com/community-pkgs/packages/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/valkey.gpg
```

### 2. Add the repository

```sh
echo "deb [signed-by=/etc/apt/keyrings/valkey.gpg] https://github.com/community-pkgs/packages valkey9 $(. /etc/os-release && echo "$VERSION_CODENAME")" | sudo tee /etc/apt/sources.list.d/valkey.list
```

> **Note:** The suite name (`valkey9`, `valkey8`, …) reflects the Valkey **major version**.
> When a new major release is published, a new suite is added — existing suites are never modified.

### Major-version suites

This repository uses a **major-version-based APT layout**.

Each Valkey major release is published in its own suite, such as `valkey9`.
The Debian/Ubuntu distribution codename is used as the APT component and is inserted dynamically from the current system.

Example:

```sh
echo "deb [signed-by=/etc/apt/keyrings/valkey.gpg] https://<PAGES_URL> valkey9 $(. /etc/os-release && echo "$VERSION_CODENAME")" | sudo tee /etc/apt/sources.list.d/valkey.list
```

This means:

- `valkey9` tracks the Valkey 9.x release line
- the component is resolved automatically from the current system codename, such as `noble` or `trixie`

This layout keeps each Valkey major version on its own upgrade channel, so users do not move to a new major release unless they explicitly switch suites.

### 3. Update and install

```sh
sudo apt update
```

Install the server only:

```sh
sudo apt install valkey-server
```

Install server + Sentinel:

```sh
sudo apt install valkey-server valkey-sentinel
```

Install only the CLI tools (no server):

```sh
sudo apt install valkey-tools
```

---

## Package details

### `valkey-server`

- Installs the `valkey-server` binary to `/usr/bin/`
- Default configuration at `/etc/valkey/valkey.conf`
- systemd unit: `valkey-server.service` (installed but **not enabled** by default)
- Multi-instance support via `valkey-server@<name>.service`
- Runs as the `valkey` system user (created automatically on install)
- Log directory: `/var/log/valkey/`
- Data directory: `/var/lib/valkey/`
- Logrotate config included

### `valkey-sentinel`

- Installs the `valkey-sentinel` binary to `/usr/bin/`
- Default configuration at `/etc/valkey/sentinel.conf`
- systemd unit: `valkey-sentinel.service` (installed but **not enabled** by default)
- Multi-instance support via `valkey-sentinel@<name>.service`

### `valkey-tools`

- `valkey-cli` — interactive CLI and scripting client
- `valkey-benchmark` — performance benchmarking tool
- `valkey-check-aof` — AOF file integrity checker and repair tool
- `valkey-check-rdb` — RDB snapshot integrity checker
- Bash completion for `valkey-cli` (auto-generated from upstream command definitions)

---

## Build details

- Packages are built inside a Docker multi-stage build using `dpkg-buildpackage`
- TLS support compiled in (`BUILD_TLS=yes`)
- systemd notify support compiled in (`USE_SYSTEMD=yes`)
- jemalloc allocator (`USE_JEMALLOC=yes`)
- RDMA support compiled in for Valkey ≥ 8 (`BUILD_RDMA=yes`)
- Hardening flags enabled (`hardening=+all`)
- LTO enabled (`optimize=+lto`)
- Packages are GPG-signed
