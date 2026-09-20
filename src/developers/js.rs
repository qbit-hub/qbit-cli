use std::env;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

/// Initialize a minimal JS/TS project by scaffolding package.json and src/index.js
pub fn init() -> Result<()> {
    ensure_project_config_file()?;
    ensure_package_json()?;
    ensure_src_tree()?;
    println!(
        "JavaScript project scaffolded. Run your package manager install command to add dependencies."
    );
    Ok(())
}

pub fn add_package(package: &str) -> Result<()> {
    ensure_package_json()?;
    let pm = resolve_package_manager()?;
    let command = build_add_command(pm, package)?;
    run_package_manager(&command)?;
    println!("Package `{package}` added via {}.", pm.name());
    Ok(())
}

pub fn remove_package(package: &str) -> Result<()> {
    ensure_package_json()?;
    let pm = resolve_package_manager()?;
    let command = build_remove_command(pm, package)?;
    run_package_manager(&command)?;
    println!("Package `{package}` removed via {}.", pm.name());
    Ok(())
}

pub fn run_script(script: &str, script_args: &[String]) -> Result<()> {
    ensure_package_json()?;
    let pm = resolve_package_manager()?;
    let command = build_run_command(pm, script, script_args)?;
    run_package_manager(&command)?;
    Ok(())
}

fn ensure_package_json() -> Result<()> {
    if Path::new("package.json").exists() {
        println!("package.json already exists");
        return Ok(());
    }

    let name = project_name();
    let package = format!(
        r#"{{
  "name": "{name}",
  "version": "0.1.0",
  "type": "module",
  "scripts": {{
    "start": "node src/index.js",
    "build": "echo \"Define build tooling\" && exit 0"
  }},
  "dependencies": {{}}
}}
"#
    );
    fs::write("package.json", package.as_bytes()).context("writing package.json")?;
    println!("Created package.json");
    Ok(())
}

fn ensure_src_tree() -> Result<()> {
    let src = Path::new("src");
    if !src.exists() {
        fs::create_dir_all(src).context("creating src directory")?;
        println!("Created src/ directory");
    }

    let entry = src.join("index.js");
    if !entry.exists() {
        let content = r#"console.log("Hello from qbit js init!");"#;
        fs::write(&entry, content.as_bytes()).context("writing src/index.js")?;
        println!("Created src/index.js");
    } else {
        println!("src/index.js already exists");
    }

    Ok(())
}

fn ensure_project_config_file() -> Result<()> {
    if Path::new("qbit.yml").exists()
        || Path::new("qbit.yaml").exists()
        || Path::new("qbit.toml").exists()
    {
        return Ok(());
    }

    let template = r#"scripts:
  dev: "npm run dev"
  lint:
    - "qbit py init"
    - "python -m flake8"

install:
  postgres:
    version: "15"
    identifiers:
      apt: "postgresql"
      winget: "PostgreSQL.PostgreSQL"
  redis:
    version: "7.2"
    identifiers:
      apt: "redis-server"
      winget: "Redis.Redis-CLI"
"#;
    fs::write("qbit.yml", template.as_bytes()).context("writing qbit.yml template")?;
    println!("Created qbit.yml");
    Ok(())
}

fn project_name() -> String {
    std::env::current_dir()
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().to_string())
        })
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "qbit-app".to_string())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct JsCommandSpec {
    pm: JsPackageManager,
    args: Vec<String>,
}

impl JsCommandSpec {
    fn render(&self) -> String {
        format!("{} {}", self.pm.executable(), self.args.join(" "))
    }
}

fn run_package_manager(command: &JsCommandSpec) -> Result<()> {
    println!("Using JavaScript package manager: {}", command.pm.name());
    println!("{}", command.render());
    let status = run_js_command(command.pm.executable(), &command.args)
        .with_context(|| format!("spawning {}", command.pm.executable()))?;

    if !status.success() {
        bail!(
            "{} command failed (code: {})",
            command.pm.name(),
            status.code().unwrap_or_default()
        );
    }
    Ok(())
}

fn run_js_command(executable: &str, args: &[String]) -> std::io::Result<std::process::ExitStatus> {
    #[cfg(windows)]
    {
        Command::new("cmd")
            .arg("/C")
            .arg(executable)
            .args(args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
    }

    #[cfg(not(windows))]
    {
        Command::new(executable)
            .args(args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
    }
}

fn resolve_package_manager() -> Result<JsPackageManager> {
    let env_override = env::var("QBIT_JS_PM").ok();
    let lockfile = detect_by_lockfile();
    resolve_package_manager_from_state(env_override.as_deref(), lockfile, |pm| {
        command_available(pm.executable())
    })
}

fn detect_by_lockfile() -> Option<(JsPackageManager, &'static str)> {
    lockfile_priority()
        .iter()
        .find(|(lockfile, _)| Path::new(lockfile).exists())
        .map(|(lockfile, pm)| (*pm, *lockfile))
}

fn lockfile_priority() -> [(&'static str, JsPackageManager); 4] {
    [
        ("bun.lockb", JsPackageManager::Bun),
        ("pnpm-lock.yaml", JsPackageManager::Pnpm),
        ("yarn.lock", JsPackageManager::Yarn),
        ("package-lock.json", JsPackageManager::Npm),
    ]
}

fn resolve_package_manager_from_state<F>(
    env_override: Option<&str>,
    detected_lockfile: Option<(JsPackageManager, &'static str)>,
    is_available: F,
) -> Result<JsPackageManager>
where
    F: Fn(JsPackageManager) -> bool,
{
    if let Some(raw) = env_override {
        let pm = JsPackageManager::parse(raw).ok_or_else(|| {
            anyhow::anyhow!(
                "Unsupported QBIT_JS_PM value `{raw}`. Supported values: bun, pnpm, yarn, npm."
            )
        })?;
        if !is_available(pm) {
            bail!(
                "QBIT_JS_PM is set to `{}`, but `{}` is not available in PATH. Install it or unset QBIT_JS_PM.",
                pm.name(),
                pm.executable()
            );
        }
        return Ok(pm);
    }

    if let Some((pm, lockfile)) = detected_lockfile {
        if is_available(pm) {
            return Ok(pm);
        }
        bail!(
            "Detected `{}` lockfile (`{}`), but `{}` is not available in PATH. Install {} or set QBIT_JS_PM to another installed manager.",
            pm.name(),
            lockfile,
            pm.executable(),
            pm.name()
        );
    }

    for pm in [
        JsPackageManager::Bun,
        JsPackageManager::Pnpm,
        JsPackageManager::Yarn,
        JsPackageManager::Npm,
    ] {
        if is_available(pm) {
            return Ok(pm);
        }
    }

    bail!(
        "No JavaScript package manager found in PATH. Install one of: bun, pnpm, yarn, npm. You can also set QBIT_JS_PM=bun|pnpm|yarn|npm."
    );
}

fn command_available(cmd: &str) -> bool {
    #[cfg(windows)]
    {
        Command::new("cmd")
            .args(["/C", cmd, "--version"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|st| st.success())
            .unwrap_or(false)
    }

    #[cfg(not(windows))]
    {
        Command::new(cmd)
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|st| st.success())
            .unwrap_or(false)
    }
}

fn build_add_command(pm: JsPackageManager, package: &str) -> Result<JsCommandSpec> {
    let package = package.trim();
    if package.is_empty() {
        bail!("Package name must be non-empty.");
    }
    Ok(JsCommandSpec {
        pm,
        args: pm.add_args([package]),
    })
}

fn build_remove_command(pm: JsPackageManager, package: &str) -> Result<JsCommandSpec> {
    let package = package.trim();
    if package.is_empty() {
        bail!("Package name must be non-empty.");
    }
    Ok(JsCommandSpec {
        pm,
        args: pm.remove_args([package]),
    })
}

fn build_run_command(
    pm: JsPackageManager,
    script: &str,
    script_args: &[String],
) -> Result<JsCommandSpec> {
    let script = script.trim();
    if script.is_empty() {
        bail!("Script name must be non-empty.");
    }
    Ok(JsCommandSpec {
        pm,
        args: pm.run_args(script, script_args),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JsPackageManager {
    Bun,
    Pnpm,
    Yarn,
    Npm,
}

impl JsPackageManager {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "bun" => Some(Self::Bun),
            "pnpm" => Some(Self::Pnpm),
            "yarn" => Some(Self::Yarn),
            "npm" => Some(Self::Npm),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Bun => "bun",
            Self::Pnpm => "pnpm",
            Self::Yarn => "yarn",
            Self::Npm => "npm",
        }
    }

    fn executable(self) -> &'static str {
        self.name()
    }

    fn add_args<I>(self, packages: I) -> Vec<String>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let mut args = vec![self.add_verb().to_string()];
        args.extend(packages.into_iter().map(|p| p.as_ref().to_string()));
        args
    }

    fn remove_args<I>(self, packages: I) -> Vec<String>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let mut args = vec![self.remove_verb().to_string()];
        args.extend(packages.into_iter().map(|p| p.as_ref().to_string()));
        args
    }

    fn run_args(self, script: &str, script_args: &[String]) -> Vec<String> {
        let mut args = vec!["run".to_string(), script.to_string()];
        if !script_args.is_empty() {
            args.push("--".to_string());
            args.extend(script_args.iter().cloned());
        }
        args
    }

    fn add_verb(self) -> &'static str {
        match self {
            Self::Npm => "install",
            Self::Pnpm => "add",
            Self::Yarn => "add",
            Self::Bun => "add",
        }
    }

    fn remove_verb(self) -> &'static str {
        match self {
            Self::Npm => "uninstall",
            Self::Pnpm => "remove",
            Self::Yarn => "remove",
            Self::Bun => "remove",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    use serial_test::serial;
    use tempfile::tempdir;

    use super::*;

    struct EnvGuard {
        key: &'static str,
        original: Option<OsString>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let original = std::env::var_os(key);
            // SAFETY: tests that mutate env vars use `#[serial]`, so there is no
            // concurrent mutation in this process.
            unsafe { std::env::set_var(key, value) };
            Self { key, original }
        }

        fn remove(key: &'static str) -> Self {
            let original = std::env::var_os(key);
            // SAFETY: tests that mutate env vars use `#[serial]`, so there is no
            // concurrent mutation in this process.
            unsafe { std::env::remove_var(key) };
            Self { key, original }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.original {
                Some(value) => {
                    // SAFETY: restoration runs in the same serial test context.
                    unsafe { std::env::set_var(self.key, value) };
                }
                None => {
                    // SAFETY: restoration runs in the same serial test context.
                    unsafe { std::env::remove_var(self.key) };
                }
            }
        }
    }

    struct CwdGuard {
        original: PathBuf,
    }

    impl CwdGuard {
        fn set(path: &Path) -> Self {
            let original = std::env::current_dir().expect("current dir");
            std::env::set_current_dir(path).expect("set current dir");
            Self { original }
        }
    }

    impl Drop for CwdGuard {
        fn drop(&mut self) {
            let _ = std::env::set_current_dir(&self.original);
        }
    }

    fn set_fake_path(fakebin: &Path) -> EnvGuard {
        let mut path = OsString::from(fakebin.as_os_str());
        if let Some(existing) = std::env::var_os("PATH") {
            path.push(if cfg!(windows) { ";" } else { ":" });
            path.push(existing);
        }
        EnvGuard::set("PATH", path)
    }

    fn create_fake_pm_executable(fakebin: &Path, name: &str) -> PathBuf {
        fs::create_dir_all(fakebin).expect("create fakebin");

        #[cfg(windows)]
        let executable = fakebin.join(format!("{name}.cmd"));
        #[cfg(not(windows))]
        let executable = fakebin.join(name);

        #[cfg(windows)]
        {
            let script = r#"@echo off
if not "%QBIT_FAKE_LOG%"=="" echo %*>>"%QBIT_FAKE_LOG%"
if "%1"=="--version" (
  echo 1.0.0
  exit /b 0
)
exit /b 0
"#;
            fs::write(&executable, script).expect("write fake cmd");
        }

        #[cfg(not(windows))]
        {
            let script = r#"#!/bin/sh
if [ -n "$QBIT_FAKE_LOG" ]; then
  printf "%s\n" "$*" >> "$QBIT_FAKE_LOG"
fi
if [ "$1" = "--version" ]; then
  echo "1.0.0"
  exit 0
fi
exit 0
"#;
            fs::write(&executable, script).expect("write fake script");
            let mut perms = fs::metadata(&executable).expect("metadata").permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&executable, perms).expect("set executable bit");
        }

        executable
    }

    fn read_log(log_path: &Path) -> String {
        fs::read_to_string(log_path)
            .unwrap_or_default()
            .replace("\r\n", "\n")
    }

    #[test]
    fn npm_and_yarn_use_expected_verbs() {
        assert_eq!(JsPackageManager::Npm.add_verb(), "install");
        assert_eq!(JsPackageManager::Npm.remove_verb(), "uninstall");
        assert_eq!(JsPackageManager::Yarn.add_verb(), "add");
        assert_eq!(JsPackageManager::Yarn.remove_verb(), "remove");
    }

    #[test]
    fn run_args_forward_extra_args_after_separator() {
        let args = JsPackageManager::Pnpm.run_args(
            "build",
            &[
                "--watch".to_string(),
                "--mode".to_string(),
                "dev".to_string(),
            ],
        );
        assert_eq!(
            args,
            vec![
                "run".to_string(),
                "build".to_string(),
                "--".to_string(),
                "--watch".to_string(),
                "--mode".to_string(),
                "dev".to_string()
            ]
        );
    }

    #[test]
    fn lockfile_priority_prefers_bun_over_others() {
        let resolved = lockfile_priority()
            .iter()
            .find(|(candidate, _)| {
                ["yarn.lock", "package-lock.json", "bun.lockb"]
                    .iter()
                    .any(|name| name == candidate)
            })
            .map(|(candidate, pm)| (*pm, *candidate));
        let (pm, lockfile) = resolved.expect("lockfile resolution");
        assert_eq!(pm.name(), "bun");
        assert_eq!(lockfile, "bun.lockb");
    }

    #[test]
    fn resolve_pm_prefers_env_override_when_available() {
        let pm = resolve_package_manager_from_state(
            Some("npm"),
            Some((JsPackageManager::Bun, "bun.lockb")),
            |candidate| candidate == JsPackageManager::Npm,
        )
        .expect("must resolve");
        assert_eq!(pm, JsPackageManager::Npm);
    }

    #[test]
    fn resolve_pm_uses_lockfile_when_no_override() {
        let pm = resolve_package_manager_from_state(
            None,
            Some((JsPackageManager::Yarn, "yarn.lock")),
            |candidate| candidate == JsPackageManager::Yarn,
        )
        .expect("must resolve");
        assert_eq!(pm, JsPackageManager::Yarn);
    }

    #[test]
    fn build_command_for_lockfile_selected_pm() {
        let pm = resolve_package_manager_from_state(
            None,
            Some((JsPackageManager::Pnpm, "pnpm-lock.yaml")),
            |_| true,
        )
        .expect("must resolve");
        let command = build_add_command(pm, "axios").expect("command");
        assert_eq!(command.pm, JsPackageManager::Pnpm);
        assert_eq!(command.args, vec!["add".to_string(), "axios".to_string()]);
    }

    #[test]
    #[serial]
    fn init_creates_scaffold_files() {
        let tmp = tempdir().expect("tempdir");
        let _cwd = CwdGuard::set(tmp.path());

        init().expect("js init");

        assert!(tmp.path().join("qbit.yml").exists());
        assert!(tmp.path().join("package.json").exists());
        assert!(tmp.path().join("src").join("index.js").exists());
    }

    #[test]
    #[serial]
    fn resolve_package_manager_prefers_first_available_candidate() {
        let tmp = tempdir().expect("tempdir");
        let _cwd = CwdGuard::set(tmp.path());
        let _clear_override = EnvGuard::remove("QBIT_JS_PM");
        let fakebin = tmp.path().join("fakebin");
        create_fake_pm_executable(&fakebin, "bun");
        create_fake_pm_executable(&fakebin, "pnpm");
        create_fake_pm_executable(&fakebin, "yarn");
        create_fake_pm_executable(&fakebin, "npm");
        let _path = set_fake_path(&fakebin);

        let pm = resolve_package_manager().expect("resolve package manager");
        assert_eq!(pm, JsPackageManager::Bun);
    }

    #[test]
    #[serial]
    fn add_remove_and_run_use_fake_pm_and_log_args() {
        let tmp = tempdir().expect("tempdir");
        let _cwd = CwdGuard::set(tmp.path());

        fs::write("package.json", "{}\n").expect("package.json");
        let log_path = tmp.path().join("pm.log");
        let fakebin = tmp.path().join("fakebin");
        create_fake_pm_executable(&fakebin, "npm");

        let _pm = EnvGuard::set("QBIT_JS_PM", "npm");
        let _path = set_fake_path(&fakebin);
        let _log = EnvGuard::set("QBIT_FAKE_LOG", log_path.as_os_str());

        add_package("left-pad").expect("add package");
        remove_package("left-pad").expect("remove package");
        run_script("build", &["--watch".to_string()]).expect("run script");

        let log = read_log(&log_path);
        assert!(log.contains("install left-pad"), "log was: {log}");
        assert!(log.contains("uninstall left-pad"), "log was: {log}");
        assert!(log.contains("run build -- --watch"), "log was: {log}");
    }

    #[test]
    #[serial]
    fn snapshot_generated_qbit_template() {
        let tmp = tempdir().expect("tempdir");
        let _cwd = CwdGuard::set(tmp.path());

        ensure_project_config_file().expect("write template");
        let content = fs::read_to_string("qbit.yml")
            .expect("template content")
            .replace("\r\n", "\n");

        insta::with_settings!({
            snapshot_path => "../../snapshots",
            prepend_module_to_snapshot => false,
        }, {
            insta::assert_snapshot!("js_qbit_yml_template", content);
        });
    }

    #[test]
    fn snapshot_npm_run_args_rendering() {
        let args = JsPackageManager::Npm
            .run_args(
                "build",
                &[
                    "--watch".to_string(),
                    "--mode".to_string(),
                    "dev".to_string(),
                ],
            )
            .join(" ");
        insta::with_settings!({
            snapshot_path => "../../snapshots",
            prepend_module_to_snapshot => false,
        }, {
            insta::assert_snapshot!("js_npm_run_args", args);
        });
    }

    #[test]
    #[ignore = "Future behavior: lockfile-based selection should be validated end-to-end with fake executables."]
    fn future_lockfile_based_detection_end_to_end() {
        let _ = detect_by_lockfile();
    }

    #[test]
    #[ignore = "Future behavior: assert yarn/bun verbs in full command execution matrix."]
    fn future_yarn_bun_verbs_end_to_end() {
        assert_eq!(JsPackageManager::Yarn.add_verb(), "add");
        assert_eq!(JsPackageManager::Bun.remove_verb(), "remove");
    }
}
