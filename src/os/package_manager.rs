use std::env;
use std::process::{Command, Stdio};

use anyhow::{Result, bail};

#[derive(Debug, Clone)]
pub struct InstallCommand {
    pub program: String,
    pub args: Vec<String>,
}

impl InstallCommand {
    pub fn new(program: impl Into<String>, args: Vec<String>) -> Self {
        Self {
            program: program.into(),
            args,
        }
    }

    pub fn render(&self) -> String {
        let mut parts = Vec::with_capacity(self.args.len() + 1);
        parts.push(quote_for_display(&self.program));
        for arg in &self.args {
            parts.push(quote_for_display(arg));
        }
        parts.join(" ")
    }
}

pub trait PackageManager {
    fn name(&self) -> &'static str;
    fn executable(&self) -> &'static str;
    fn config_keys(&self) -> &'static [&'static str];

    fn is_available(&self) -> bool {
        command_exists(self.executable())
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand>;

    fn apply_yes_flag(&self, _command: &mut InstallCommand) {}
}

pub fn detect_package_manager() -> Result<Box<dyn PackageManager>> {
    if let Ok(raw_override) = env::var("QBIT_PACKAGE_MANAGER") {
        let override_name = raw_override.trim();
        if override_name.is_empty() {
            bail!(
                "QBIT_PACKAGE_MANAGER is set but empty. Set it to a supported manager name (for example `apt-get`, `brew`, `winget`) or unset it."
            );
        }

        let pm = package_manager_from_name(override_name).ok_or_else(|| {
            anyhow::anyhow!(
                "Unknown package manager `{override_name}` in QBIT_PACKAGE_MANAGER. Supported values: apt-get, dnf, pacman, zypper, brew, winget, choco, scoop."
            )
        })?;

        if !pm.is_available() {
            bail!(
                "QBIT_PACKAGE_MANAGER is `{}`, but executable `{}` is not available in PATH. Install it or unset QBIT_PACKAGE_MANAGER.",
                override_name,
                pm.executable()
            );
        }

        return Ok(pm);
    }

    let mut checked = Vec::new();
    for pm in detection_candidates() {
        checked.push(pm.name());
        if pm.is_available() {
            return Ok(pm);
        }
    }

    bail!(
        "No supported package manager detected in PATH. Checked: {}. Install one of them or set QBIT_PACKAGE_MANAGER.",
        checked.join(", ")
    )
}

pub(crate) fn package_manager_from_name(name: &str) -> Option<Box<dyn PackageManager>> {
    match name.trim().to_ascii_lowercase().as_str() {
        "apt" | "apt-get" => Some(Box::new(AptGet)),
        "dnf" => Some(Box::new(Dnf)),
        "pacman" => Some(Box::new(Pacman)),
        "zypper" => Some(Box::new(Zypper)),
        "brew" | "homebrew" => Some(Box::new(Brew)),
        "winget" => Some(Box::new(Winget)),
        "choco" | "chocolatey" => Some(Box::new(Chocolatey)),
        "scoop" => Some(Box::new(Scoop)),
        _ => None,
    }
}

fn detection_candidates() -> Vec<Box<dyn PackageManager>> {
    #[cfg(target_os = "linux")]
    let candidates: Vec<Box<dyn PackageManager>> = vec![
        Box::new(AptGet),
        Box::new(Dnf),
        Box::new(Pacman),
        Box::new(Zypper),
    ];

    #[cfg(target_os = "macos")]
    let candidates: Vec<Box<dyn PackageManager>> = vec![Box::new(Brew)];

    #[cfg(target_os = "windows")]
    let candidates: Vec<Box<dyn PackageManager>> =
        vec![Box::new(Winget), Box::new(Chocolatey), Box::new(Scoop)];

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    let candidates: Vec<Box<dyn PackageManager>> = vec![
        Box::new(AptGet),
        Box::new(Dnf),
        Box::new(Pacman),
        Box::new(Zypper),
        Box::new(Brew),
        Box::new(Winget),
        Box::new(Chocolatey),
        Box::new(Scoop),
    ];

    candidates
}

fn command_exists(executable: &str) -> bool {
    Command::new(executable)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

fn validate_identifier<'a>(identifier: &'a str, manager: &str) -> Result<&'a str> {
    let trimmed = identifier.trim();
    if trimmed.is_empty() {
        bail!(
            "Resolved identifier is empty for `{manager}`. Define a valid identifier in qbit.yml under install.<target>."
        );
    }
    Ok(trimmed)
}

fn validate_version<'a>(version: Option<&'a str>, manager: &str) -> Result<Option<&'a str>> {
    let Some(raw) = version else {
        return Ok(None);
    };

    let trimmed = raw.trim();
    if trimmed.is_empty() {
        bail!(
            "Version is empty for `{manager}`. Use `qbit install <target>` or provide a non-empty version."
        );
    }
    if trimmed.chars().any(char::is_whitespace) {
        bail!(
            "Version `{trimmed}` contains whitespace, which is not valid for `{manager}`. Use a compact version like `3.12`."
        );
    }

    Ok(Some(trimmed))
}

fn with_optional_sudo(executable: &str, args: Vec<String>) -> InstallCommand {
    if cfg!(windows) {
        return InstallCommand::new(executable.to_string(), args);
    }

    if command_exists("sudo") {
        let mut sudo_args = Vec::with_capacity(args.len() + 1);
        sudo_args.push(executable.to_string());
        sudo_args.extend(args);
        return InstallCommand::new("sudo", sudo_args);
    }

    InstallCommand::new(executable.to_string(), args)
}

fn insert_after_subcommand(command: &mut InstallCommand, subcommand: &str, flag: &str) {
    if command.args.iter().any(|arg| arg == flag) {
        return;
    }

    if let Some(index) = command.args.iter().position(|arg| arg == subcommand) {
        command.args.insert(index + 1, flag.to_string());
    } else {
        command.args.push(flag.to_string());
    }
}

fn quote_for_display(input: &str) -> String {
    if input.is_empty() {
        return "\"\"".to_string();
    }

    if input
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '@' | '='))
    {
        return input.to_string();
    }

    format!("\"{}\"", input.replace('\\', "\\\\").replace('"', "\\\""))
}

struct AptGet;

impl PackageManager for AptGet {
    fn name(&self) -> &'static str {
        "apt-get"
    }

    fn executable(&self) -> &'static str {
        "apt-get"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["apt-get", "apt"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;
        let package_spec = match version {
            Some(v) => format!("{identifier}={v}"),
            None => identifier.to_string(),
        };

        Ok(with_optional_sudo(
            self.executable(),
            vec!["install".to_string(), package_spec],
        ))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "install", "-y");
    }
}

struct Dnf;

impl PackageManager for Dnf {
    fn name(&self) -> &'static str {
        "dnf"
    }

    fn executable(&self) -> &'static str {
        "dnf"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["dnf"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;
        let package_spec = match version {
            Some(v) => format!("{identifier}-{v}"),
            None => identifier.to_string(),
        };

        Ok(with_optional_sudo(
            self.executable(),
            vec!["install".to_string(), package_spec],
        ))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "install", "-y");
    }
}

struct Pacman;

impl PackageManager for Pacman {
    fn name(&self) -> &'static str {
        "pacman"
    }

    fn executable(&self) -> &'static str {
        "pacman"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["pacman"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        if version.is_some() {
            bail!(
                "`pacman` does not support reliable direct version pinning in a single install command. Remove `:<version>` or install the required package version manually."
            );
        }

        Ok(with_optional_sudo(
            self.executable(),
            vec!["-S".to_string(), identifier.to_string()],
        ))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "-S", "--noconfirm");
    }
}

struct Zypper;

impl PackageManager for Zypper {
    fn name(&self) -> &'static str {
        "zypper"
    }

    fn executable(&self) -> &'static str {
        "zypper"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["zypper"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;
        let package_spec = match version {
            Some(v) => format!("{identifier}={v}"),
            None => identifier.to_string(),
        };

        Ok(with_optional_sudo(
            self.executable(),
            vec!["install".to_string(), package_spec],
        ))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "install", "-y");
    }
}

struct Brew;

impl PackageManager for Brew {
    fn name(&self) -> &'static str {
        "brew"
    }

    fn executable(&self) -> &'static str {
        "brew"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["brew", "homebrew"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;
        let package_spec = build_brew_identifier(identifier, version)?;

        Ok(InstallCommand::new(
            self.executable().to_string(),
            vec!["install".to_string(), package_spec],
        ))
    }
}

fn build_brew_identifier(identifier: &str, version: Option<&str>) -> Result<String> {
    let Some(version) = version else {
        return Ok(identifier.to_string());
    };

    if let Some((_, existing)) = identifier.rsplit_once('@') {
        if existing == version {
            return Ok(identifier.to_string());
        }
        bail!(
            "Homebrew identifier `{identifier}` already includes version `{existing}`. Remove inline version `:{version}` or update your `identifiers.brew` value."
        );
    }

    if identifier.ends_with('/') || identifier.contains(char::is_whitespace) {
        bail!(
            "Cannot derive a versioned Homebrew formula from `{identifier}`. Set an explicit `identifiers.brew` value like `<formula>@{version}`."
        );
    }

    Ok(format!("{identifier}@{version}"))
}

struct Winget;

impl PackageManager for Winget {
    fn name(&self) -> &'static str {
        "winget"
    }

    fn executable(&self) -> &'static str {
        "winget"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["winget"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;

        let mut args = vec![
            "install".to_string(),
            "--id".to_string(),
            identifier.to_string(),
            "--exact".to_string(),
            "--accept-source-agreements".to_string(),
            "--accept-package-agreements".to_string(),
        ];
        if let Some(v) = version {
            args.push("--version".to_string());
            args.push(v.to_string());
        }

        Ok(InstallCommand::new(self.executable().to_string(), args))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "install", "--silent");
    }
}

struct Chocolatey;

impl PackageManager for Chocolatey {
    fn name(&self) -> &'static str {
        "choco"
    }

    fn executable(&self) -> &'static str {
        "choco"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["choco", "chocolatey"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        let version = validate_version(version, self.name())?;

        let mut args = vec!["install".to_string(), identifier.to_string()];
        if let Some(v) = version {
            args.push("--version".to_string());
            args.push(v.to_string());
        }

        Ok(InstallCommand::new(self.executable().to_string(), args))
    }

    fn apply_yes_flag(&self, command: &mut InstallCommand) {
        insert_after_subcommand(command, "install", "-y");
    }
}

struct Scoop;

impl PackageManager for Scoop {
    fn name(&self) -> &'static str {
        "scoop"
    }

    fn executable(&self) -> &'static str {
        "scoop"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["scoop"]
    }

    fn build_install_cmd(&self, identifier: &str, version: Option<&str>) -> Result<InstallCommand> {
        let identifier = validate_identifier(identifier, self.name())?;
        if version.is_some() {
            bail!(
                "`scoop` version pinning is not reliable through a single install command. Remove `:<version>` and install the required bucket/package version manually, or switch to `winget`/`choco`."
            );
        }

        Ok(InstallCommand::new(
            self.executable().to_string(),
            vec!["install".to_string(), identifier.to_string()],
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brew_builds_versioned_formula_when_not_already_versioned() {
        let id = build_brew_identifier("python", Some("3.12")).expect("brew id");
        assert_eq!(id, "python@3.12");
    }

    #[test]
    fn brew_rejects_conflicting_version() {
        let err = build_brew_identifier("python@3.11", Some("3.12")).expect_err("must fail");
        assert!(err.to_string().contains("already includes version"));
    }
}
