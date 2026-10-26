# Native installer packaging (work in progress)

This directory contains **unreleased packaging foundations** retained for future work on standard Qbit CLI installers. These files are **not yet integrated** with `.github/workflows/ci.yml` or `.github/workflows/release.yml`.

## Source layout

| Platform | Package metadata | Builder |
|---|---|---|
| Windows MSI | `packaging/windows/QbitCli.wxs` | `scripts/package/build-windows.ps1` |
| macOS PKG | `packaging/macos/distribution.xml` | `scripts/package/build-macos.sh` |
| Linux DEB | `packaging/linux/debian/control.template` | `scripts/package/build-linux-deb.sh` |

Branding assets: `assets/icon.ico`, `assets/icon.icns`, `assets/icon.png`.

## Intended contract

- Rust crate: `qbit-cli`.
- Installed executable: `qbit` (`qbit.exe` on Windows).
- MSI: per-user under `%LOCALAPPDATA%\\Programs\\Qbit CLI\\bin`.
- PKG: `/usr/local/bin/qbit`.
- DEB: `/usr/bin/qbit`.
- Do not publish these artifacts until binary naming, version consistency, installer ownership, E2E installation/upgrade/removal, and security checks have been completed.

## Outstanding integration and verification

- The **current development branch still builds `qbit-cli`**. Builders in this directory expect `qbit`; the Cargo binary rename, tests, workflows, and updater need to be migrated together.
- Validate WiX v5 compilation, MSI install/uninstall and PATH cleanup on Windows.
- Validate `pkgbuild` / `productbuild` metadata, identifiers, signatures/notarization and actual payload installation on macOS.
- Validate DEB control metadata, maintainer contact, runtime dependencies, package ownership and upgrade/removal on Linux.
- Validate exact OS **and architecture** asset selection, version matching, checksums and native upgrade invocation.
- Harden release workflow permissions, toolchain/action pinning, final artifact verification, and install/upgrade/uninstall E2E gates.
- Do **not** assume these scripts are production-ready merely because they exist here.

The current release process and `qbit upgrade` implementation remain unchanged until the native-installer migration is complete.
