#!/usr/bin/env python3
"""验证 Pro fork 身份、二开清单与发布前测试，并生成可审计清单。"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
from typing import Any


DEFAULT_MANIFEST = pathlib.Path("deploy/pro/customizations.yaml")


class GuardError(RuntimeError):
    """表示发布门禁未满足。"""


def run_git(repo_root: pathlib.Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise GuardError(f"git {' '.join(args)} 失败: {detail}")
    return result.stdout.strip()


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GuardError(f"无法解析二开清单 {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise GuardError("二开清单顶层必须是对象")
    return data


def validate_manifest(data: dict[str, Any]) -> None:
    if data.get("schema_version") != 1 or data.get("product") != "pro":
        raise GuardError("二开清单 schema_version/product 非法")

    canonical = data.get("canonical_repository")
    tests = data.get("release_tests")
    customizations = data.get("customizations")
    runtime = data.get("runtime_contract")
    if not isinstance(canonical, dict) or not isinstance(runtime, dict):
        raise GuardError("二开清单缺少 canonical_repository 或 runtime_contract")
    if not isinstance(tests, list) or not isinstance(customizations, list):
        raise GuardError("二开清单 release_tests/customizations 必须是数组")

    test_ids = set()
    for test in tests:
        if not isinstance(test, dict) or not isinstance(test.get("id"), str):
            raise GuardError("release_tests 中存在无效项目")
        if test["id"] in test_ids:
            raise GuardError(f"重复测试 ID: {test['id']}")
        test_ids.add(test["id"])
        command = test.get("command")
        if not isinstance(command, list) or not command or not all(isinstance(v, str) for v in command):
            raise GuardError(f"测试 {test['id']} 的 command 必须是非空字符串数组")

    customization_ids = set()
    for item in customizations:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise GuardError("customizations 中存在无效项目")
        if item["id"] in customization_ids:
            raise GuardError(f"重复二开 ID: {item['id']}")
        customization_ids.add(item["id"])
        unknown = set(item.get("test_ids", [])) - test_ids
        if unknown:
            raise GuardError(f"二开 {item['id']} 引用了未知测试: {sorted(unknown)}")
        if not item.get("test_ids") and not item.get("runtime_http_paths"):
            raise GuardError(f"二开 {item['id']} 既没有测试也没有运行时检查")


def ensure_ancestor(repo_root: pathlib.Path, ancestor: str, head: str, label: str) -> None:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, head],
        cwd=repo_root,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        suffix = f": {detail}" if detail else ""
        raise GuardError(f"{label} {ancestor} 不在当前提交历史中{suffix}")


def changed_migrations(repo_root: pathlib.Path, base_ref: str | None, head: str) -> list[str]:
    if not base_ref:
        return []
    output = run_git(repo_root, "diff", "--name-only", f"{base_ref}..{head}", "--", "backend/migrations")
    return [line for line in output.splitlines() if line.endswith(".sql")]


def changed_database_paths(repo_root: pathlib.Path, base_ref: str | None, head: str) -> list[str]:
    if not base_ref:
        return []
    output = run_git(
        repo_root,
        "diff",
        "--name-only",
        f"{base_ref}..{head}",
        "--",
        "backend/migrations",
        "backend/ent/schema",
    )
    return [line for line in output.splitlines() if line]


def verify_repository(
    repo_root: pathlib.Path,
    data: dict[str, Any],
    development: bool,
) -> dict[str, Any]:
    canonical = data["canonical_repository"]
    origin = run_git(repo_root, "remote", "get-url", "origin")
    if origin not in canonical["origin_urls"]:
        raise GuardError(f"origin 不是 Pro fork: {origin}")

    head = run_git(repo_root, "rev-parse", "HEAD")
    tree = run_git(repo_root, "rev-parse", "HEAD^{tree}")
    branch = run_git(repo_root, "branch", "--show-current")
    status = run_git(repo_root, "status", "--porcelain")

    if not development:
        if status:
            raise GuardError("工作区不干净，禁止生成发布产物")
        if branch and branch != canonical["branch"]:
            raise GuardError(f"当前分支必须是 {canonical['branch']}: {branch}")
        origin_head = run_git(repo_root, "rev-parse", f"origin/{canonical['branch']}")
        if head != origin_head:
            raise GuardError(f"HEAD {head} 与 origin/{canonical['branch']} {origin_head} 不一致")

    upstream = canonical["upstream_commit"]
    ensure_ancestor(repo_root, upstream, head, f"上游 {canonical['upstream_release']}")
    for ancestor in canonical["protected_ancestors"]:
        ensure_ancestor(repo_root, ancestor, head, "Pro 二开基线")

    for item in data["customizations"]:
        for relative in item.get("required_paths", []):
            if not (repo_root / relative).exists():
                raise GuardError(f"二开 {item['id']} 缺少文件: {relative}")

    return {
        "origin": origin,
        "branch": branch or "detached",
        "commit": head,
        "tree": tree,
        "dirty": bool(status),
        "upstream_release": canonical["upstream_release"],
        "upstream_commit": upstream,
    }


def run_release_tests(repo_root: pathlib.Path, data: dict[str, Any]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for test in data["release_tests"]:
        command = test["command"]
        workdir = (repo_root / test.get("working_directory", ".")).resolve()
        print(f"[pro-guard] 运行 {test['id']}: {' '.join(command)}", flush=True)
        started = dt.datetime.now(dt.timezone.utc)
        result = subprocess.run(command, cwd=workdir, check=False)
        elapsed = (dt.datetime.now(dt.timezone.utc) - started).total_seconds()
        if result.returncode != 0:
            raise GuardError(f"测试失败: {test['id']} (exit={result.returncode})")
        results.append({"id": test["id"], "status": "passed", "duration_seconds": round(elapsed, 3)})
    return results


def write_release_manifest(
    path: pathlib.Path,
    source: dict[str, Any],
    data: dict[str, Any],
    tests: list[dict[str, Any]],
    base_ref: str,
    migrations: list[str],
    database_paths: list[str],
) -> None:
    payload = {
        "schema_version": 1,
        "product": "pro",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": source,
        "base_ref": base_ref,
        "changed_migrations": migrations,
        "changed_database_paths": database_paths,
        "automatic_app_rollback_allowed": not database_paths,
        "customization_ids": [item["id"] for item in data["customizations"]],
        "tests": tests,
        "image": None,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="验证 TokenRouter Pro 发布门禁")
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--development", action="store_true", help="允许脏工作区或非 main，仅用于开发验证")
    parser.add_argument("--skip-tests", action="store_true", help="只检查元数据；不能生成发布清单")
    parser.add_argument("--base-ref", help="当前线上版本对应提交；生成发布清单时必填")
    parser.add_argument("--output", type=pathlib.Path, help="输出 release-manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    manifest_path = args.manifest if args.manifest.is_absolute() else repo_root / args.manifest
    try:
        data = load_manifest(manifest_path)
        validate_manifest(data)
        source = verify_repository(repo_root, data, args.development)
        if args.output and (args.development or args.skip_tests or not args.base_ref):
            raise GuardError("正式发布清单要求干净 main、完整测试和 --base-ref")
        resolved_base = None
        if args.base_ref:
            resolved_base = run_git(repo_root, "rev-parse", f"{args.base_ref}^{{commit}}")
            ensure_ancestor(repo_root, resolved_base, source["commit"], "当前线上基线")
        migrations = changed_migrations(repo_root, resolved_base, source["commit"])
        database_paths = changed_database_paths(repo_root, resolved_base, source["commit"])
        tests = [] if args.skip_tests else run_release_tests(repo_root, data)
        if args.output:
            output = args.output if args.output.is_absolute() else repo_root / args.output
            write_release_manifest(output, source, data, tests, resolved_base, migrations, database_paths)
            print(f"[pro-guard] 发布清单: {output}")
        print("[pro-guard] PASS")
        return 0
    except GuardError as exc:
        print(f"[pro-guard] FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
