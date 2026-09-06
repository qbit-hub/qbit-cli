# Qbit CLI – Unified Dev Environment & Package Automation

Qbit is a cross-platform developer command line that turns repetitive environment setup into a single command. Install system tools, bootstrap Python/JavaScript/Dart projects, and run your own scripts from one `qbit` binary that works on Windows, macOS, and Linux.

## Why Qbit?

- **Install anything with one command**
  ```bash
  qbit install java
  qbit install chrome:127.0.0.0
  ```
  Qbit detects an available native package manager at runtime (`apt-get`, `dnf`, `pacman`, `zypper`, `brew`, `winget`, `choco`, `scoop`), maps the logical name to the correct package ID, and installs the requested version when the manager supports pinning.

- **Project bootstrapping**
  ```bash
  qbit py init
  qbit js init
  qbit dart init
  ```
  Scaffold virtual environments, `requirements.txt`, `package.json`, entry files, and other boilerplate instantly.

- **Language-aware dependency management**
  ```bash
  qbit py add pandas
  qbit js add react
  ```
  Python packages are installed inside the managed venv, frozen back into `requirements.txt`, and JavaScript packages are added through whichever manager (npm/pnpm/yarn/bun/bun) is detected.

- **Script automation with `qbit run`**
  Define workflows inside `qbit.yml`/`qbit.toml` and execute them anywhere:
  ```bash
  qbit run dev
  qbit js run start
  ```
  Front-end builds, backend migrations, or multi-step CI recipes all become reusable commands.

## Power of `qbit.yml`

Qbit looks at `qbit.yml` (or `qbit.toml`) in your project root. Running `qbit js init` generates a starter file like this:

```yaml
scripts:
  dev: "npm run dev"
  build-all:
    - "qbit js run build"
    - "cargo build --release"

install:
  postgres:
    version: "15"
    identifiers:
      apt: "postgresql"
      winget: "PostgreSQL.PostgreSQL"
      default: "postgresql"
  redis:
    version: "7.2"
    identifiers:
      apt: "redis-server"
      winget: "Redis.Redis-CLI"
```

- `qbit run build-all` executes the commands sequentially.
- `qbit install postgres` installs version 15 and automatically chooses the correct package ID for each platform.
- Inline overrides are supported: `qbit install chrome:127.0.0.0`.
- `install.<name>: "Some.Identifier"` is treated as a shared identifier for all package managers.
- Use `qbit install <name[:version]> --dry-run` to print the exact installer command without executing it.
- Version pinning is package-manager dependent; unsupported cases return a clear actionable error.

## Installers & PATH integration

Each release publishes native, OS-standard installers — no archives to extract.

| Platform | Asset | Installer type |
|----------|-------|-----------------|
| Windows  | `qbit-cli-<version>-windows-<arch>.msi` | MSI, per-user |
| macOS    | `qbit-cli-<version>-macos-<arch>.pkg` | PKG |
| Linux    | `qbit-cli_<version>_<arch>.deb` | DEB |

Every asset ships alongside a matching `<asset>.sha256` checksum file.

### Install

**Linux (DEB):**
```bash
sudo dpkg -i qbit-cli_<version>_amd64.deb
qbit --help
```

**macOS (PKG):**
```bash
sudo installer -pkg qbit-cli-<version>-macos-<arch>.pkg -target /
qbit --help
```
Installs to `/usr/local/bin/qbit`.

**Windows (MSI):**
Double-click the `.msi`, or install silently:
```powershell
msiexec /i qbit-cli-<version>-windows-<arch>.msi /qn
```
Installs per-user to `%LOCALAPPDATA%\Programs\Qbit CLI\bin\qbit.exe` and adds that folder to your user `PATH` automatically — no administrator privileges required. Open a new terminal and run `qbit --help`.

### Uninstall

- **Linux:** `sudo dpkg -r qbit-cli`
- **macOS:** uninstall via the payload path, or see `TESTING.md` for the documented removal procedure
- **Windows:** remove via *Settings → Apps → Installed apps*, or `msiexec /x <path-to-msi> /qn`

### Upgrading

```bash
qbit upgrade
```
Reads the latest official GitHub release, downloads the correct installer for your OS/architecture, verifies its SHA-256 checksum, and installs it using your OS's native installer (`dpkg`, `installer`, or `msiexec`). If elevated privileges are required, you'll be prompted automatically.

**Stable releases only.** `qbit upgrade` never installs a prerelease or draft release, and there is no flag to opt into one — this is a deliberate scope decision, not a missing feature. If you need a prerelease build, download and install it manually from the [Releases page](https://github.com/qbit-click/qbit-cli/releases).

### Automatic update checks

`qbit` checks for a newer version at most once every 24 hours, before running your command. The check:
- has a short timeout and never blocks or fails your command if it can't reach GitHub
- only ever prints to **stderr** (never stdout), so it never interferes with scripts parsing `qbit`'s output
- looks like: `A new version of qbit is available: v1.2.3 (run \`qbit upgrade\` to install it)`

Disable the automatic check with:
```bash
QBIT_DISABLE_UPDATE_CHECK=1 qbit <command>
```
This only disables the automatic background check — running `qbit upgrade` yourself always works regardless of this setting.

## Supported Commands

- `qbit install <name[:version]> [--yes] [--dry-run]` – Install operating-system dependencies via detected package managers (`QBIT_PACKAGE_MANAGER` can force one).
- `qbit upgrade` – Download, checksum-verify, and install the latest official GitHub release for your platform.
- `qbit run <script>` – Execute custom workflows defined in configuration.
- `qbit py <init|add|remove>` – Python virtualenv management with automatic `requirements.txt` updates.
- `qbit js <init|add|remove|run>` – JavaScript project scaffolding, npm/yarn/pnpm/bun integration, and script execution.
- `qbit dart ...` – Dart scaffolding (extensible for Flutter or server projects).

Use `qbit --help` or `qbit <command> --help` for details.

## Build from Source

```bash
git clone https://github.com/<your-org>/qbit-cli.git
cd qbit-cli
cargo build --release
./target/release/qbit --help
```

Rust 1.85+ (edition 2024) is required. The repository also includes `cargo dev` for sandbox testing inside `dev-sandbox/`, and `cargo dev-clean` to reset the sandbox directory.

## Contributing

Issues and pull requests are welcome. Before submitting a PR:
1. Run `cargo fmt && cargo clippy && cargo test`.
2. Test key workflows (`qbit py init`, `qbit install ...`, `qbit run ...`) in the dev sandbox.
3. Describe the motivation and behavior changes clearly.

## License

Distributed under the terms of the MIT License. See [LICENSE](LICENSE) for details.
