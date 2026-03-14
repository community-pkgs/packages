# etcd APT Repository

[etcd](https://etcd.io) is a distributed, reliable key-value store for the most critical data of a distributed system — the backbone of Kubernetes cluster state, service discovery, and distributed configuration.

This repository provides **unofficial** Debian/Ubuntu `.deb` packages for etcd,
built automatically from official upstream releases and published as an APT repository
via GitHub Pages.

---

## Compatibility

This package uses the official pre-built upstream binaries from
[etcd-io/etcd releases](https://github.com/etcd-io/etcd/releases).
The binaries are statically compiled Go executables with no distribution-specific
dependencies, and work on any reasonably modern Debian or Ubuntu release
(`amd64` and `arm64`).

---

## Packages

| Package       | Description                                                   |
|---------------|---------------------------------------------------------------|
| `etcd`        | The etcd server daemon                                        |
| `etcd-client` | Client tools: `etcdctl`, `etcdutl`                           |

---

## Installation

### 1. Add the GPG signing key

```sh
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://community-pkgs.github.io/packages/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/etcd.gpg
```

### 2. Add the repository

```sh
echo "deb [signed-by=/etc/apt/keyrings/etcd.gpg] https://community-pkgs.github.io/packages etcd main" \
  | sudo tee /etc/apt/sources.list.d/etcd.list
```

### 3. Pin the repository

```sh
echo -e 'Package: *\nPin: release a=etcd\nPin-Priority: 990' \
  | sudo tee /etc/apt/preferences.d/etcd
```

### 4. Update and install

```sh
sudo apt update
```

Install the server:

```sh
sudo apt install etcd
```

Install only the client tools (no server):

```sh
sudo apt install etcd-client
```

---

## Package details

### `etcd`

- Installs the `etcd` binary to `/usr/bin/`
- Default data directory: `/var/lib/etcd/`
- Log directory: `/var/log/etcd/`
- Configuration directory: `/etc/etcd/`
- systemd unit: `etcd.service` (installed but **not enabled** by default)
- Runs as the `etcd` system user (created automatically on install)

### `etcd-client`

- `etcdctl` — primary CLI for interacting with an etcd cluster
- `etcdutl` — offline utility for defragmentation, snapshot restore, and migration

---

## Build details

- Packages use the official pre-built upstream binaries from [etcd-io/etcd releases](https://github.com/etcd-io/etcd/releases)
- Packages are GPG-signed
