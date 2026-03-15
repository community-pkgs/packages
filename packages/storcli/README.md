# storcli APT Repository

[StorCLI](https://www.broadcom.com/support/download-search?dk=StorCLI) is the official command-line management tool for Broadcom MegaRAID RAID controllers. It provides complete control over RAID configuration, monitoring, firmware updates, and drive health — and is the successor to the legacy MegaCLI utility.

This repository provides **unofficial** Debian/Ubuntu `.deb` packages for StorCLI,
built automatically from official upstream releases published by Broadcom and distributed as an APT repository
at [pkgs.bil.co.ua](https://pkgs.bil.co.ua) via Cloudflare R2.

> **Note:** StorCLI is **proprietary software** owned by Broadcom Inc. and distributed under the
> [Broadcom End User License Agreement](https://www.broadcom.com/support/download-search?dk=StorCLI).
> Redistribution is not permitted. By installing this package you agree to Broadcom's EULA.

---

## Compatibility

This package repackages the official pre-built upstream binaries from
[Broadcom's StorCLI download page](https://www.broadcom.com/support/download-search?dk=StorCLI).
The binaries are compiled for `amd64` and `arm64` and work on any reasonably modern Debian or Ubuntu release.

---

## Packages

| Package    | Description                                              |
|------------|----------------------------------------------------------|
| `storcli`  | StorCLI binary installed as `/usr/sbin/storcli`          |

---

## Installation

### 1. Add the GPG signing key

```sh
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.bil.co.ua/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/storcli.gpg
```

### 2. Add the repository

```sh
echo "deb [signed-by=/etc/apt/keyrings/storcli.gpg] https://pkgs.bil.co.ua storcli main" \
  | sudo tee /etc/apt/sources.list.d/storcli.list
```

### 3. Pin the repository

```sh
echo -e 'Package: *\nPin: release a=storcli\nPin-Priority: 1001' \
  | sudo tee /etc/apt/preferences.d/storcli
```

### 4. Update and install

```sh
sudo apt update
sudo apt install storcli
```

---

## Package details

### `storcli`

- Installs the `storcli64` binary to `/usr/sbin/storcli`
- No configuration files or systemd units
- Runs as **root** — required for direct hardware access to RAID controllers

---

## Usage

```sh
# Show all controllers
storcli show

# Show controller 0
storcli /c0 show

# Show all virtual drives on controller 0
storcli /c0/vall show

# Show all physical drives on controller 0
storcli /c0/eall/sall show

# Check controller 0 event log
storcli /c0/el show
```

---

## Updating

StorCLI is released by Broadcom irregularly. New packages are built manually when a new upstream version is published.
Check [Broadcom's download page](https://www.broadcom.com/support/download-search?dk=StorCLI) for the latest release.

---

## Build details

- Packages repackage the official pre-built upstream binaries from [Broadcom's StorCLI download page](https://www.broadcom.com/support/download-search?dk=StorCLI)
- Packages are GPG-signed
- New versions are built manually via `workflow_dispatch` — there is no automated release schedule
