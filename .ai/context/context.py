#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

TRANSFER_KIND = "qbit-ai-context-transfer"
OFFLINE_KIND = "qbit-ai-context-offline"
SECRET_VALUE = re.compile(
    r"(-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._\-+/=]{8,}|glpat-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,})",
    re.I,
)


def run_git(root: Path | None, args: list[str], allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    command = ["git"] + (["-C", str(root)] if root is not None else []) + args
    cp = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if cp.returncode and not allow_failure:
        raise RuntimeError(f"Git command failed: git {' '.join(args)}")
    return cp


def normalize_remote(value: str, repo_root: Path) -> str:
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", value):
        return value.rstrip("/")
    path = Path(value)
    if not path.is_absolute():
        path = repo_root / path
    return str(path.resolve()).rstrip("/\\")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        raise RuntimeError(f"{label} is invalid JSON.") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"{label} must be a JSON object.")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_head(root: Path) -> str:
    return run_git(root, ["rev-parse", "HEAD"]).stdout.strip()


def git_branch(root: Path) -> str:
    return run_git(root, ["rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()


def assert_clean_context(cache_path: Path, purpose: str) -> None:
    if run_git(cache_path, ["status", "--porcelain"]).stdout.strip():
        raise RuntimeError(f"AI context cache must be clean before offline {purpose}.")


def inherit_git_identity(member_root: Path, cache_path: Path) -> None:
    cache_name = run_git(cache_path, ["config", "--get", "user.name"], True).stdout.strip()
    cache_email = run_git(cache_path, ["config", "--get", "user.email"], True).stdout.strip()
    if cache_name and cache_email:
        return
    member_name = run_git(member_root, ["config", "--get", "user.name"], True).stdout.strip()
    member_email = run_git(member_root, ["config", "--get", "user.email"], True).stdout.strip()
    if member_name and member_email:
        run_git(cache_path, ["config", "user.name", member_name])
        run_git(cache_path, ["config", "user.email", member_email])


def assert_export_content_safe(cache_path: Path) -> None:
    staged = run_git(cache_path, ["ls-files", "--stage", "-z"]).stdout
    for record in staged.split("\0"):
        if not record:
            continue
        match = re.match(r"^(\d{6})\s+[0-9a-fA-F]+\s+\d+\t(.+)$", record, re.S)
        if not match:
            raise RuntimeError("AI context export encountered an unrecognized Git index entry.")
        mode, relative = match.groups()
        if mode not in {"100644", "100755"}:
            raise RuntimeError(f"AI context export rejects non-regular tracked entries: {relative}")
        candidate = (cache_path / relative).resolve()
        try:
            candidate.relative_to(cache_path.resolve())
        except ValueError as exc:
            raise RuntimeError("AI context export path escaped the context repository.") from exc
        if (cache_path / relative).is_symlink():
            raise RuntimeError(f"AI context export rejects symlink entries: {relative}")
        try:
            text = (cache_path / relative).read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise RuntimeError(f"AI context export only supports UTF-8 text context files: {relative}") from exc
        if SECRET_VALUE.search(text):
            raise RuntimeError(f"AI context export refused secret-like material in tracked file: {relative}")


def continuity_summary(cache_path: Path, repository: str) -> dict[str, Any] | None:
    manifest_path = cache_path / "manifests" / "repositories" / f"{repository}.json"
    if not manifest_path.is_file():
        return None
    manifest = read_json(manifest_path, "Repository context manifest")
    continuity = manifest.get("continuity")
    if not isinstance(continuity, dict):
        return None
    return {
        "mode": continuity.get("mode"),
        "workstreamId": continuity.get("workstreamId"),
        "workstreamStatus": continuity.get("workstreamStatus"),
        "currentItemId": continuity.get("currentItemId"),
        "workstreamPath": continuity.get("workstreamPath"),
        "validationLedgerPath": continuity.get("validationLedgerPath"),
    }


def transfer_paths(repo_root: Path) -> tuple[Path, Path, Path]:
    bridge = repo_root / ".ai-bridge"
    transfer = bridge / "context-transfer"
    return transfer, transfer / "manifest.json", transfer / "context.bundle"


def marker_path(repo_root: Path) -> Path:
    return repo_root / ".ai-bridge" / "context-offline.json"


def export_transfer(repo_root: Path, cache_path: Path, config: dict[str, Any], branch: str) -> None:
    if not (cache_path / ".git").exists():
        raise RuntimeError("Central AI context cache must exist before offline export.")
    if git_branch(cache_path) != branch:
        raise RuntimeError(f"AI context cache must remain on configured branch '{branch}'.")
    assert_clean_context(cache_path, "export")
    assert_export_content_safe(cache_path)

    transfer, _manifest_path, _bundle_path = transfer_paths(repo_root)
    bridge = transfer.parent
    bridge.mkdir(parents=True, exist_ok=True)
    temp = bridge / f"context-transfer.tmp-{os.getpid()}"
    backup = bridge / f"context-transfer.backup-{os.getpid()}"
    shutil.rmtree(temp, ignore_errors=True)
    shutil.rmtree(backup, ignore_errors=True)
    temp.mkdir(parents=True)
    bundle = temp / "context.bundle"
    run_git(cache_path, ["bundle", "create", str(bundle), branch])
    verified = run_git(cache_path, ["bundle", "verify", str(bundle)], True)
    if verified.returncode:
        raise RuntimeError("Generated AI context bundle failed Git verification.")

    context_head = git_head(cache_path)
    member_head = git_head(repo_root)
    member_branch = git_branch(repo_root)
    bundle_hash = sha256_file(bundle)
    manifest = {
        "schemaVersion": 1,
        "kind": TRANSFER_KIND,
        "createdAt": dt.datetime.now().astimezone().isoformat(),
        "project": str(config["project"]),
        "repository": str(config["repository"]),
        "contextBranch": branch,
        "source": {
            "contextHead": context_head,
            "memberHead": member_head,
            "memberBranch": member_branch,
        },
        "bundle": {
            "file": "context.bundle",
            "sha256": bundle_hash,
            "bytes": bundle.stat().st_size,
        },
        "continuity": continuity_summary(cache_path, str(config["repository"])),
    }
    write_json(temp / "manifest.json", manifest)

    try:
        if transfer.exists():
            os.replace(transfer, backup)
        os.replace(temp, transfer)
        shutil.rmtree(backup, ignore_errors=True)
    except Exception:
        if not transfer.exists() and backup.exists():
            os.replace(backup, transfer)
        shutil.rmtree(temp, ignore_errors=True)
        raise
    print(f"AI context offline export ready: {transfer}")


def validate_transfer_manifest(manifest: dict[str, Any], config: dict[str, Any], branch: str) -> None:
    required = {"schemaVersion", "kind", "createdAt", "project", "repository", "contextBranch", "source", "bundle", "continuity"}
    if set(manifest) != required:
        raise RuntimeError("AI context transfer manifest shape is invalid.")
    if int(manifest["schemaVersion"]) != 1 or str(manifest["kind"]) != TRANSFER_KIND:
        raise RuntimeError("Unsupported AI context transfer manifest.")
    if str(manifest["project"]) != str(config["project"]):
        raise RuntimeError("AI context transfer project does not match this repository config.")
    if str(manifest["repository"]) != str(config["repository"]):
        raise RuntimeError("AI context transfer repository does not match this repository config.")
    if str(manifest["contextBranch"]) != branch:
        raise RuntimeError("AI context transfer branch does not match this repository config.")
    source = manifest["source"]
    bundle = manifest["bundle"]
    if not isinstance(source, dict) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", str(source.get("contextHead") or "")):
        raise RuntimeError("AI context transfer source contextHead is invalid.")
    if not isinstance(bundle, dict) or str(bundle.get("file")) != "context.bundle":
        raise RuntimeError("AI context transfer bundle path is invalid.")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", str(bundle.get("sha256") or "")):
        raise RuntimeError("AI context transfer bundle hash is invalid.")
    if not isinstance(bundle.get("bytes"), int) or int(bundle["bytes"]) <= 0:
        raise RuntimeError("AI context transfer bundle size is invalid.")


def write_offline_marker(repo_root: Path, config: dict[str, Any], branch: str, remote: str, source_head: str, current_head: str, bundle_hash: str) -> None:
    marker = {
        "schemaVersion": 1,
        "kind": OFFLINE_KIND,
        "importedAt": dt.datetime.now().astimezone().isoformat(),
        "project": str(config["project"]),
        "repository": str(config["repository"]),
        "contextBranch": branch,
        "contextRemote": remote,
        "sourceContextHead": source_head,
        "currentContextHead": current_head,
        "bundleSha256": bundle_hash,
    }
    write_json(marker_path(repo_root), marker)


def import_transfer(repo_root: Path, cache_path: Path, config: dict[str, Any], branch: str, remote: str) -> None:
    transfer, manifest_path, bundle_path = transfer_paths(repo_root)
    if not transfer.is_dir() or not manifest_path.is_file() or not bundle_path.is_file():
        raise RuntimeError("AI context offline transfer is incomplete; expected .ai-bridge/context-transfer/manifest.json and context.bundle.")
    manifest = read_json(manifest_path, "AI context transfer manifest")
    validate_transfer_manifest(manifest, config, branch)
    bundle_info = manifest["bundle"]
    if bundle_path.stat().st_size != int(bundle_info["bytes"]):
        raise RuntimeError("AI context transfer bundle size does not match the manifest.")
    bundle_hash = sha256_file(bundle_path)
    if bundle_hash.lower() != str(bundle_info["sha256"]).lower():
        raise RuntimeError("AI context transfer bundle SHA-256 does not match the manifest.")
    verify = run_git(repo_root, ["bundle", "verify", str(bundle_path)], True)
    if verify.returncode:
        raise RuntimeError("AI context transfer Git bundle verification failed.")
    heads = run_git(repo_root, ["bundle", "list-heads", str(bundle_path), f"refs/heads/{branch}"]).stdout.strip().splitlines()
    if len(heads) != 1:
        raise RuntimeError("AI context transfer bundle does not contain exactly the configured context branch.")
    bundle_head = heads[0].split()[0]
    source_head = str(manifest["source"]["contextHead"])
    if bundle_head.lower() != source_head.lower():
        raise RuntimeError("AI context transfer bundle HEAD does not match the manifest provenance.")

    if (cache_path / ".git").exists():
        assert_clean_context(cache_path, "import")
        if git_branch(cache_path) != branch:
            raise RuntimeError(f"AI context cache must remain on configured branch '{branch}'.")
        current = git_head(cache_path)
        if current.lower() != source_head.lower():
            raise RuntimeError("AI context offline import conflicts with the existing context cache HEAD; destructive reconciliation was refused.")
        actual_remote = normalize_remote(run_git(cache_path, ["remote", "get-url", "origin"]).stdout.strip(), repo_root)
        if actual_remote != remote:
            run_git(cache_path, ["remote", "set-url", "origin", remote])
    else:
        if cache_path.exists() and any(cache_path.iterdir()):
            raise RuntimeError("AI context cache path exists but is not an empty import target.")
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        clone = run_git(repo_root, ["clone", "--branch", branch, "--single-branch", "--", str(bundle_path), str(cache_path)], True)
        if clone.returncode:
            raise RuntimeError("Unable to import central AI context from the verified offline bundle.")
        if git_head(cache_path).lower() != source_head.lower():
            shutil.rmtree(cache_path, ignore_errors=True)
            raise RuntimeError("Imported AI context HEAD does not match transfer provenance.")
        run_git(cache_path, ["remote", "set-url", "origin", remote])
        run_git(cache_path, ["branch", "--unset-upstream"], True)

    if not (cache_path / "tooling" / "context-lifecycle.py").is_file():
        raise RuntimeError("Imported AI context bundle is missing POSIX lifecycle tooling.")
    inherit_git_identity(repo_root, cache_path)
    write_offline_marker(repo_root, config, branch, remote, source_head, git_head(cache_path), bundle_hash)
    print(f"AI context offline import ready: {git_head(cache_path)}")


def load_offline_marker(repo_root: Path, cache_path: Path, config: dict[str, Any], branch: str, remote: str) -> dict[str, Any] | None:
    path = marker_path(repo_root)
    if not path.is_file():
        return None
    marker = read_json(path, "AI context offline marker")
    required = {"schemaVersion", "kind", "importedAt", "project", "repository", "contextBranch", "contextRemote", "sourceContextHead", "currentContextHead", "bundleSha256"}
    if set(marker) != required or int(marker["schemaVersion"]) != 1 or str(marker["kind"]) != OFFLINE_KIND:
        raise RuntimeError("AI context offline marker is invalid.")
    if str(marker["project"]) != str(config["project"]) or str(marker["repository"]) != str(config["repository"]):
        raise RuntimeError("AI context offline marker does not match this repository config.")
    if str(marker["contextBranch"]) != branch or normalize_remote(str(marker["contextRemote"]), repo_root) != remote:
        raise RuntimeError("AI context offline marker remote/branch does not match this repository config.")
    if not (cache_path / ".git").exists():
        raise RuntimeError("AI context offline marker exists but the imported context cache is missing.")
    if git_head(cache_path).lower() != str(marker["currentContextHead"]).lower():
        raise RuntimeError("AI context offline marker does not match the imported context cache HEAD.")
    return marker


def reconnect_offline(repo_root: Path, cache_path: Path, config: dict[str, Any], branch: str, remote: str) -> None:
    marker = load_offline_marker(repo_root, cache_path, config, branch, remote)
    if marker is None:
        raise RuntimeError("AI context reconnect requires an imported offline context marker.")
    assert_clean_context(cache_path, "reconnect")
    run_git(cache_path, ["remote", "set-url", "origin", remote])
    fetched = run_git(cache_path, ["fetch", "origin", branch], True)
    if fetched.returncode:
        raise RuntimeError("Unable to reconnect AI context remote; offline state was preserved.")

    remote_ref = f"origin/{branch}"
    remote_head_result = run_git(cache_path, ["rev-parse", remote_ref], True)
    if remote_head_result.returncode:
        raise RuntimeError("AI context reconnect could not resolve the configured remote branch; offline state was preserved.")
    remote_head = remote_head_result.stdout.strip()
    local_head = git_head(cache_path)

    remote_is_ancestor = run_git(cache_path, ["merge-base", "--is-ancestor", remote_head, local_head], True).returncode == 0
    local_is_ancestor = run_git(cache_path, ["merge-base", "--is-ancestor", local_head, remote_head], True).returncode == 0

    if remote_is_ancestor:
        pushed = run_git(cache_path, ["push", "origin", f"HEAD:{branch}"], True)
        if pushed.returncode:
            run_git(cache_path, ["fetch", "origin", branch], True)
            raise RuntimeError("AI context offline reconnect push was rejected because the remote changed; offline state was preserved for explicit reconciliation.")
        run_git(cache_path, ["fetch", "origin", branch], True)
    elif local_is_ancestor:
        ff = run_git(cache_path, ["merge", "--ff-only", remote_ref], True)
        if ff.returncode:
            raise RuntimeError("AI context offline reconnect fast-forward failed; offline state was preserved.")
    else:
        raise RuntimeError("AI context offline reconciliation conflict: local and remote context histories diverged; automatic merge/rebase was refused.")

    run_git(cache_path, ["branch", "--set-upstream-to", remote_ref, branch], True)
    marker_path(repo_root).unlink(missing_ok=True)
    print(f"AI context reconnected: {git_head(cache_path)}")


def refresh_online_cache(repo_root: Path, cache_path: Path, remote: str, branch: str, action: str) -> None:
    if not (cache_path / ".git").exists():
        if cache_path.exists() and any(cache_path.iterdir()):
            raise RuntimeError("AI context cache path exists but is not a Git repository.")
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        clone = run_git(None, ["clone", "--branch", branch, "--single-branch", "--", remote, str(cache_path)], True)
        if clone.returncode:
            raise RuntimeError("Unable to clone central AI context. Check Git authentication/network access.")
        return

    actual_remote_raw = run_git(cache_path, ["remote", "get-url", "origin"]).stdout.strip()
    actual_remote = normalize_remote(actual_remote_raw, repo_root)
    actual_branch = git_branch(cache_path)
    if actual_branch != branch:
        raise RuntimeError(f"AI context cache must remain on configured branch '{branch}'.")
    dirty = bool(run_git(cache_path, ["status", "--porcelain"]).stdout.strip())
    if actual_remote != remote:
        if dirty:
            raise RuntimeError("AI context cache origin differs from the configured central remote and the cache is dirty; automatic origin migration was refused.")
        run_git(cache_path, ["remote", "set-url", "origin", remote])
        fetched = run_git(cache_path, ["fetch", "origin", branch], True)
        if fetched.returncode:
            run_git(cache_path, ["remote", "set-url", "origin", actual_remote_raw], True)
            raise RuntimeError("AI context cache origin migration failed; the previous origin was restored.")
    else:
        run_git(cache_path, ["fetch", "origin", branch])

    dirty = bool(run_git(cache_path, ["status", "--porcelain"]).stdout.strip())
    if dirty:
        if action == "checkpoint":
            raise RuntimeError("Automated checkpoint refused because the AI context cache has pre-existing uncommitted changes.")
        print("WARNING: AI context cache is dirty; refresh skipped and local context will be loaded read-only.", file=sys.stderr)
    else:
        ff = run_git(cache_path, ["merge", "--ff-only", f"origin/{branch}"], True)
        if ff.returncode:
            if action == "checkpoint":
                raise RuntimeError("AI context cache diverged from origin; automated checkpoint cannot continue safely.")
            print("WARNING: AI context cache diverged from origin; destructive synchronization was refused. Local context will be loaded read-only.", file=sys.stderr)


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "start"
    if action not in {"start", "status", "checkpoint", "audit", "export", "import", "reconnect"}:
        raise RuntimeError("Action must be start, status, checkpoint, audit, export, import, or reconnect.")
    if shutil.which("git") is None:
        raise RuntimeError("Git is required for AI context lifecycle.")

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent.resolve()
    config_path = script_dir / "config.json"
    if not config_path.is_file():
        raise RuntimeError("AI context config is missing.")
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    if int(config.get("schemaVersion", 0)) != 1:
        raise RuntimeError("Unsupported AI context config schemaVersion.")

    context = config.get("context") or {}
    configured_remote = str(context.get("remote") or "")
    branch = str(context.get("branch") or "")
    cache_relative = str(context.get("cachePath") or "")
    if not configured_remote or not branch or not cache_relative:
        raise RuntimeError("AI context config is incomplete.")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@", configured_remote):
        raise RuntimeError("AI context remote URL must not embed credentials.")

    remote = normalize_remote(configured_remote, repo_root)
    cache_path = Path(cache_relative)
    if cache_path.is_absolute():
        raise RuntimeError("AI context cachePath must be repository-relative.")
    cache_path = (repo_root / cache_path).resolve()
    try:
        relative_cache = cache_path.relative_to(repo_root)
    except ValueError as exc:
        raise RuntimeError("AI context cachePath must remain inside the member repository.") from exc
    if not relative_cache.parts:
        raise RuntimeError("AI context cachePath must remain inside the member repository.")

    if action == "import":
        import_transfer(repo_root, cache_path, config, branch, remote)
        return 0
    if action == "export":
        export_transfer(repo_root, cache_path, config, branch)
        return 0
    if action == "reconnect":
        reconnect_offline(repo_root, cache_path, config, branch, remote)
        return 0

    offline_marker = load_offline_marker(repo_root, cache_path, config, branch, remote)
    if offline_marker is None:
        refresh_online_cache(repo_root, cache_path, remote, branch, action)
    else:
        if git_branch(cache_path) != branch:
            raise RuntimeError(f"AI context cache must remain on configured branch '{branch}'.")
        if action == "checkpoint" and run_git(cache_path, ["status", "--porcelain"]).stdout.strip():
            raise RuntimeError("Automated checkpoint refused because the imported AI context cache has pre-existing uncommitted changes.")

    tool_path = cache_path / "tooling" / "context-lifecycle.py"
    if not tool_path.is_file():
        raise RuntimeError("Central AI context POSIX tooling is missing. Refresh or re-import the central context repository.")
    command = [sys.executable, str(tool_path), "--action", action, "--repository-root", str(repo_root), "--config-path", str(config_path)]
    if offline_marker is not None:
        command.append("--offline")
    cp = subprocess.run(command)
    if cp.returncode == 0 and offline_marker is not None and action == "checkpoint":
        write_offline_marker(
            repo_root,
            config,
            branch,
            remote,
            str(offline_marker["sourceContextHead"]),
            git_head(cache_path),
            str(offline_marker["bundleSha256"]),
        )
    return cp.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(12)
