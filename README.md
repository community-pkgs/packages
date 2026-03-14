# APT Packages

Unofficial Debian/Ubuntu `.deb` packages built automatically from upstream releases
and published as a signed APT repository at [pkgs.bil.co.ua](https://pkgs.bil.co.ua) via Cloudflare R2.

---

## Packages

| Package | Description | README |
|---------|-------------|--------|
| [Valkey](https://valkey.io) | High-performance key-value store (BSD-licensed Redis fork) | [Installation & details](packages/valkey/README.md) |
| [etcd](https://etcd.io) | Distributed reliable key-value store for the most critical data of a distributed system | [Installation & details](packages/etcd/README.md) |
| [containerd](https://containerd.io) | Industry-standard container runtime (CNCF graduated project) | [Installation & details](packages/containerd/README.md) |

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
3. Packages are added to the signed APT repository with `dpkg-scanpackages`.
4. The existing repository state is pulled from Cloudflare R2, updated, and synced back with [`s3sync`](https://github.com/nidor1998/s3sync).
5. The repository is served from [pkgs.bil.co.ua](https://pkgs.bil.co.ua) via Cloudflare R2.
