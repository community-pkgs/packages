# APT Packages

Unofficial Debian/Ubuntu `.deb` packages built automatically from upstream releases
and published as a signed APT repository via GitHub Pages.

---

## Packages

| Package | Description | README |
|---------|-------------|--------|
| [Valkey](https://valkey.io) | High-performance key-value store (BSD-licensed Redis fork) | [Installation & details](packages/valkey/README.md) |

---

## APT Repository

All packages share a single APT repository served via GitHub Pages from the `apt` branch.

```sh
# Add the signing key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://community-pkgs.github.io/packages/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/packages.gpg

# Add the repository (replace SUITE for the desired package)
echo "deb [signed-by=/etc/apt/keyrings/packages.gpg] https://community-pkgs.github.io/packages SUITE $(. /etc/os-release && echo "$VERSION_CODENAME")" | sudo tee /etc/apt/sources.list.d/packages.list
sudo apt update
```

See each package's README for the exact `SUITE`, and package names.

---

## Contributing a New Package

Want to see a package added to this repository? You're welcome to request it or contribute it yourself.

### Open an Issue

If you'd like to request a package, [open an issue](../../issues/new) and describe:

- the upstream project (name, URL, licence);
- why it would be useful to have as a `.deb` package;
- which Debian/Ubuntu versions and architectures should be supported.

### Submit a Pull Request

A PR is even better! To add a new package:

1. Fork the repository and create a feature branch.
2. Add a `packages/<slug>/` directory following the structure of an existing package (e.g. `packages/valkey/`):
   - `Dockerfile` — build environment;
   - `debian/` — packaging files (`control`, `changelog`, `rules`, …);
   - `README.md.in` — installation guide template;
   - `logo.svg` *(optional)* — square SVG logo.
3. Make sure the package builds locally with `docker build`.
4. Open a PR with a short description of the package and a link to the upstream project.

---

## How It Works

1. A scheduled workflow (daily) or `workflow_dispatch` checks for a new upstream release.
2. `.deb` packages are compiled inside Docker for each supported OS/arch combination.
3. Packages are added to the signed APT repository with `reprepro`.
4. The repository is pushed to the `apt` branch and served via GitHub Pages.
