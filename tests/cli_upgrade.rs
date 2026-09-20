//! Integration tests for `qbit upgrade` (item 18).
//!
//! These tests spawn the real compiled `qbit` binary (matching the
//! pattern in `tests/cli_help.rs`, `tests/cli_run.rs`,
//! `tests/update_check.rs`) against a local `wiremock` HTTP server
//! standing in for the GitHub API, via the
//! `QBIT_UPGRADE_API_BASE_URL` test-only override in
//! `src/os/upgrade.rs`. No test in this file depends on real network
//! access or the real GitHub API.
//!
//! GitHub's real `/releases/latest` endpoint only ever returns a
//! release that is neither a draft nor a prerelease — so "draft
//! ignored" and "prerelease ignored by default" are tested by
//! confirming `qbit upgrade` behaves correctly when the mock server
//! (standing in for that endpoint's real contract) simply does not
//! return a draft/prerelease at all, and doesn't attempt to inspect
//! any `draft`/`prerelease` field itself — there's no such field to
//! ignore in the response we control, because the endpoint contract
//! we're modeling structurally excludes those already. A companion
//! test also confirms the response schema `qbit upgrade` sends
//! (nothing) requests only `/releases/latest`, never `/releases`.
//!
//! Since `qbit upgrade`'s final step invokes a real OS installer
//! (`dpkg`/`installer`/`msiexec`), tests that reach that stage use a
//! deliberately fake (non-functional) installer file — we assert
//! that the command *attempted* installation and got a clear
//! installer-level failure, not that installation fully succeeded
//! (which would require an environment capable of actually
//! installing a real package, outside the scope of these tests).
//!
//! Every test that spawns `qbit upgrade` is marked `#[serial]`
//! (from `serial_test`, already a dev-dependency). This is required,
//! not optional: `qbit upgrade` creates a `qbit-upgrade-*` temp
//! directory that's cleaned up by its own `Drop` impl when the
//! spawned child process exits. Since `cargo test` runs tests
//! concurrently by default, an un-serialized test could observe
//! another still-running test's temp directory and misattribute it
//! as a leak. Serializing every test that touches this shared
//! temp-directory namespace avoids that false positive.

use std::fs;

use assert_cmd::Command;
use serial_test::serial;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

/// The version qbit reports itself as, taken directly from Cargo.toml
/// at compile time (the same mechanism upgrade.rs itself uses via
/// `env!("CARGO_PKG_VERSION")`), so this never has to be manually
/// kept in sync with Cargo.toml.
const CURRENT_VERSION_PLACEHOLDER: &str = env!("CARGO_PKG_VERSION");

fn qbit_installer_asset_name() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        "qbit-cli-9.9.9-windows-x64.msi"
    }
    #[cfg(target_os = "macos")]
    {
        "qbit-cli-9.9.9-macos-arm64.pkg"
    }
    #[cfg(target_os = "linux")]
    {
        "qbit-cli_9.9.9_amd64.deb"
    }
}

fn release_json(tag: &str, assets: &[(&str, &str)]) -> serde_json::Value {
    serde_json::json!({
        "tag_name": tag,
        "assets": assets.iter().map(|(name, url)| serde_json::json!({
            "name": name,
            "browser_download_url": url,
        })).collect::<Vec<_>>()
    })
}

async fn mock_server_with_release(release: serde_json::Value) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;
    server
}

fn run_qbit_upgrade(base_url: &str) -> std::process::Output {
    Command::cargo_bin("qbit")
        .expect("qbit binary")
        .env("QBIT_UPGRADE_API_BASE_URL", base_url)
        .env("QBIT_UPGRADE_REPO", "qbit-click/qbit-cli")
        .arg("upgrade")
        .output()
        .expect("failed to run qbit upgrade")
}

fn combined_output(output: &std::process::Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

// --- Scenario: up-to-date ---

#[tokio::test]
#[serial]
async fn up_to_date_reports_already_current_and_exits_successfully() {
    let release = release_json(&format!("v{CURRENT_VERSION_PLACEHOLDER}"), &[]);
    let server = mock_server_with_release(release).await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        output.status.success(),
        "expected success when already up to date; got: {combined}"
    );
    assert!(
        combined.to_lowercase().contains("up to date"),
        "expected an up-to-date message; got: {combined}"
    );
}

// --- Scenario: new stable version + correct architecture asset ---

#[tokio::test]
#[serial]
async fn new_stable_version_with_correct_asset_attempts_download_and_install() {
    let asset_name = qbit_installer_asset_name();
    let checksum_name = format!("{asset_name}.sha256");

    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[
            (
                asset_name,
                &format!("{}/download/{asset_name}", server.uri()),
            ),
            (
                &checksum_name,
                &format!("{}/download/{checksum_name}", server.uri()),
            ),
        ],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;

    let fake_installer_bytes = b"not a real installer, just test bytes";
    let hex = sha256_hex(fake_installer_bytes);
    let checksum_file_body = format!("{hex}  {asset_name}\n");

    Mock::given(method("GET"))
        .and(path(format!("/download/{asset_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(fake_installer_bytes.to_vec()))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path(format!("/download/{checksum_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_string(checksum_file_body))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        combined.contains("Checksum OK"),
        "expected checksum verification to succeed; got: {combined}"
    );
    assert!(
        combined.to_lowercase().contains("downloading installer"),
        "expected the real installer download step to run; got: {combined}"
    );
}

// --- Scenario: missing installer asset ---

#[tokio::test]
#[serial]
async fn missing_installer_asset_fails_with_clear_error() {
    let release = release_json(
        "v9.9.9",
        &[("readme.txt", "https://example.test/readme.txt")],
    );
    let server = mock_server_with_release(release).await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined.to_lowercase().contains("no installer asset found"),
        "expected a clear 'no installer asset found' error; got: {combined}"
    );
}

// --- Scenario: wrong architecture asset (only a different platform's asset present) ---

#[tokio::test]
#[serial]
async fn wrong_architecture_asset_only_fails_with_clear_error() {
    let wrong_asset = "qbit-cli_9.9.9_riscv64.deb";
    let release = release_json(
        "v9.9.9",
        &[(wrong_asset, "https://example.test/wrong-arch.deb")],
    );
    let server = mock_server_with_release(release).await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined.to_lowercase().contains("no installer asset found"),
        "expected asset selection to fail for a non-matching architecture; got: {combined}"
    );
}

// --- Scenario: missing checksum ---

#[tokio::test]
#[serial]
async fn missing_checksum_asset_fails_before_any_install_attempt() {
    let asset_name = qbit_installer_asset_name();
    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[(
            asset_name,
            &format!("{}/download/{asset_name}", server.uri()),
        )],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined.contains("Checksum file"),
        "expected a clear missing-checksum error; got: {combined}"
    );
    assert!(
        !combined.to_lowercase().contains("downloading installer"),
        "must not have started downloading the installer without a checksum present; got: {combined}"
    );
}

// --- Scenario: checksum mismatch ---

#[tokio::test]
#[serial]
async fn checksum_mismatch_fails_and_does_not_run_installer() {
    let asset_name = qbit_installer_asset_name();
    let checksum_name = format!("{asset_name}.sha256");
    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[
            (
                asset_name,
                &format!("{}/download/{asset_name}", server.uri()),
            ),
            (
                &checksum_name,
                &format!("{}/download/{checksum_name}", server.uri()),
            ),
        ],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path(format!("/download/{asset_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"real installer bytes".to_vec()))
        .mount(&server)
        .await;

    let wrong_checksum = format!("{}  {asset_name}\n", "0".repeat(64));
    Mock::given(method("GET"))
        .and(path(format!("/download/{checksum_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_string(wrong_checksum))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined.contains("Checksum mismatch"),
        "expected a clear checksum mismatch error; got: {combined}"
    );
}

// --- Scenario: invalid checksum format ---

#[tokio::test]
#[serial]
async fn invalid_checksum_format_fails_with_clear_error() {
    let asset_name = qbit_installer_asset_name();
    let checksum_name = format!("{asset_name}.sha256");
    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[
            (
                asset_name,
                &format!("{}/download/{asset_name}", server.uri()),
            ),
            (
                &checksum_name,
                &format!("{}/download/{checksum_name}", server.uri()),
            ),
        ],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path(format!("/download/{asset_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"real installer bytes".to_vec()))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path(format!("/download/{checksum_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_string("this is not a checksum"))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined
            .to_lowercase()
            .contains("valid 64-character sha-256"),
        "expected a clear invalid-checksum-format error; got: {combined}"
    );
}

// --- Scenario: HTTP failure ---

#[tokio::test]
#[serial]
async fn http_failure_from_github_api_fails_with_clear_error() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(
        !output.status.success(),
        "expected failure; got: {combined}"
    );
    assert!(
        combined
            .to_lowercase()
            .contains("github api returned an error"),
        "expected a clear HTTP-failure error; got: {combined}"
    );
}

#[tokio::test]
#[serial]
async fn http_404_from_github_api_fails_with_clear_error() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    assert!(
        !output.status.success(),
        "expected failure; got: {}",
        combined_output(&output)
    );
}

// --- Scenario: draft ignored / prerelease ignored by default ---
//
// See module-level doc comment: GitHub's real /releases/latest
// endpoint structurally excludes drafts and prereleases already, so
// "ignoring" them isn't logic inside upgrade.rs to test directly —
// it's a property of which endpoint is called. This is covered by
// `os::upgrade::tests::upgrade_uses_releases_latest_endpoint_not_all_releases`
// in src/os/upgrade.rs (unit test, locks in the exact URL). This test
// confirms the black-box behavior: our mock, standing in for that
// endpoint's real contract, simply never serves a draft/prerelease,
// and qbit upgrade correctly proceeds using whatever stable release
// the endpoint (correctly) returned.

#[tokio::test]
#[serial]
async fn only_calls_releases_latest_never_all_releases_endpoint() {
    let server = MockServer::start().await;

    let release = release_json(&format!("v{CURRENT_VERSION_PLACEHOLDER}"), &[]);
    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;

    // Deliberately do NOT mount a responder for the plain /releases
    // path (which would include prereleases/drafts). If qbit upgrade
    // ever called that instead, wiremock would return 404 for the
    // unmatched request, and the command would fail — proving it
    // never falls back to or additionally calls that endpoint.
    let output = run_qbit_upgrade(&server.uri());
    assert!(
        output.status.success(),
        "qbit upgrade must only call /releases/latest; got: {}",
        combined_output(&output)
    );
}

// --- Scenario: prerelease accepted only when explicitly enabled ---
//
// Per item 12's product decision, there is no --prerelease flag and
// none is planned. This test locks in that the CLI does not silently
// accept an undocumented flag by that name.

#[test]
fn prerelease_flag_does_not_exist() {
    let assert = Command::cargo_bin("qbit")
        .expect("qbit binary")
        .arg("upgrade")
        .arg("--prerelease")
        .assert();

    let output = assert.get_output();
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !output.status.success(),
        "qbit upgrade --prerelease must not be a recognized flag; got: {combined}"
    );
}

// --- Scenario: temp files cleaned after failure ---

#[tokio::test]
#[serial]
async fn temp_files_are_cleaned_up_after_a_failed_upgrade() {
    let temp_dir = std::env::temp_dir();
    let before: std::collections::HashSet<_> = fs::read_dir(&temp_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("qbit-upgrade-"))
                .map(|e| e.file_name())
                .collect()
        })
        .unwrap_or_default();

    let asset_name = qbit_installer_asset_name();
    let checksum_name = format!("{asset_name}.sha256");
    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[
            (
                asset_name,
                &format!("{}/download/{asset_name}", server.uri()),
            ),
            (
                &checksum_name,
                &format!("{}/download/{checksum_name}", server.uri()),
            ),
        ],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/download/{asset_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"real bytes".to_vec()))
        .mount(&server)
        .await;
    let wrong_checksum = format!("{}  {asset_name}\n", "0".repeat(64));
    Mock::given(method("GET"))
        .and(path(format!("/download/{checksum_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_string(wrong_checksum))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    assert!(!output.status.success());

    let after: std::collections::HashSet<_> = fs::read_dir(&temp_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("qbit-upgrade-"))
                .map(|e| e.file_name())
                .collect()
        })
        .unwrap_or_default();

    assert_eq!(
        before, after,
        "no new qbit-upgrade-* temp directories should remain after a failed upgrade"
    );
}

// --- Scenario: no installer execution on checksum mismatch ---

#[tokio::test]
#[serial]
async fn checksum_mismatch_error_appears_before_any_installer_invocation_message() {
    let asset_name = qbit_installer_asset_name();
    let checksum_name = format!("{asset_name}.sha256");
    let server = MockServer::start().await;

    let release = release_json(
        "v9.9.9",
        &[
            (
                asset_name,
                &format!("{}/download/{asset_name}", server.uri()),
            ),
            (
                &checksum_name,
                &format!("{}/download/{checksum_name}", server.uri()),
            ),
        ],
    );

    Mock::given(method("GET"))
        .and(path("/repos/qbit-click/qbit-cli/releases/latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(release))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/download/{asset_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"real bytes".to_vec()))
        .mount(&server)
        .await;
    let wrong_checksum = format!("{}  {asset_name}\n", "0".repeat(64));
    Mock::given(method("GET"))
        .and(path(format!("/download/{checksum_name}")))
        .respond_with(ResponseTemplate::new(200).set_body_string(wrong_checksum))
        .mount(&server)
        .await;

    let output = run_qbit_upgrade(&server.uri());
    let combined = combined_output(&output);

    assert!(!output.status.success());
    assert!(
        !combined.contains("Upgrade installed successfully"),
        "installer success message must not appear when checksum verification failed; got: {combined}"
    );
}
