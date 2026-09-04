#!/usr/bin/env python3
"""Pro 发布门禁的无网络单元测试。"""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "tools/pro_release_guard.py"
SPEC = importlib.util.spec_from_file_location("pro_release_guard", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class ManifestValidationTest(unittest.TestCase):
    def test_repository_manifest_is_valid(self) -> None:
        data = GUARD.load_manifest(REPO_ROOT / "deploy/pro/customizations.yaml")
        GUARD.validate_manifest(data)

    def test_unknown_test_reference_is_rejected(self) -> None:
        data = {
            "schema_version": 1,
            "product": "pro",
            "canonical_repository": {},
            "runtime_contract": {},
            "release_tests": [],
            "customizations": [{"id": "x", "test_ids": ["missing"]}],
        }
        with self.assertRaisesRegex(GUARD.GuardError, "未知测试"):
            GUARD.validate_manifest(data)

    def test_changed_migrations_only_returns_sql(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "backend/migrations").mkdir(parents=True)
            GUARD.subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            GUARD.subprocess.run(["git", "config", "user.name", "test"], cwd=root, check=True)
            GUARD.subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            (root / "backend/migrations/001_initial.sql").write_text("select 1;\n", encoding="utf-8")
            GUARD.subprocess.run(["git", "add", "."], cwd=root, check=True)
            GUARD.subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
            base = GUARD.run_git(root, "rev-parse", "HEAD")
            (root / "backend/migrations/002_next.sql").write_text("select 2;\n", encoding="utf-8")
            GUARD.subprocess.run(["git", "add", "."], cwd=root, check=True)
            GUARD.subprocess.run(["git", "commit", "-qm", "next"], cwd=root, check=True)
            head = GUARD.run_git(root, "rev-parse", "HEAD")
            self.assertEqual(
                GUARD.changed_migrations(root, base, head),
                ["backend/migrations/002_next.sql"],
            )

    def test_strict_repository_gate_rejects_dirty_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            GUARD.subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
            GUARD.subprocess.run(["git", "config", "user.name", "test"], cwd=root, check=True)
            GUARD.subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            (root / "tracked.txt").write_text("clean\n", encoding="utf-8")
            GUARD.subprocess.run(["git", "add", "."], cwd=root, check=True)
            GUARD.subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
            head = GUARD.run_git(root, "rev-parse", "HEAD")
            GUARD.subprocess.run(
                ["git", "remote", "add", "origin", "https://github.com/aether-shell/RootFlowTokenRouter.git"],
                cwd=root,
                check=True,
            )
            GUARD.subprocess.run(["git", "update-ref", "refs/remotes/origin/main", head], cwd=root, check=True)
            data = {
                "canonical_repository": {
                    "origin_urls": ["https://github.com/aether-shell/RootFlowTokenRouter.git"],
                    "branch": "main",
                    "upstream_release": "test",
                    "upstream_commit": head,
                    "protected_ancestors": [head],
                },
                "customizations": [],
            }
            source = GUARD.verify_repository(root, data, development=False)
            self.assertFalse(source["dirty"])
            (root / "tracked.txt").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(GUARD.GuardError, "工作区不干净"):
                GUARD.verify_repository(root, data, development=False)


if __name__ == "__main__":
    unittest.main()
