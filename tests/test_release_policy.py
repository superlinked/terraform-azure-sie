import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_policy", ROOT / ".github/scripts/check_release_policy.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
BASE_SHA = "a" * 40
HEAD_SHA = "b" * 40
MERGE_BASE = "c" * 40


def event(title="docs: update installation", body=""):
    return {"pull_request": {
        "title": title,
        "body": body,
        "base": {"sha": BASE_SHA},
        "head": {"sha": HEAD_SHA},
    }}


class FakeGit:
    def __init__(self, paths=None, messages=None):
        self.paths = paths if paths is not None else ["README.md"]
        self.messages = messages if messages is not None else ["docs: update installation"]
        self.calls = []

    def __call__(self, args):
        self.calls.append(args)
        if args == ["merge-base", BASE_SHA, HEAD_SHA]:
            return MERGE_BASE + "\n"
        if args == ["diff", "--name-only", "-z", "--no-renames", MERGE_BASE, HEAD_SHA, "--"]:
            return "".join(path + "\0" for path in self.paths)
        if args == ["log", "--format=%B%x00", "--reverse", f"{MERGE_BASE}..{HEAD_SHA}", "--"]:
            return "".join(message + "\0\n" for message in self.messages)
        raise AssertionError(f"Unexpected Git request: {args}")


class ReleasePolicyTests(unittest.TestCase):
    def test_non_releasing_titles_and_commits(self):
        for prefix in ("docs", "chore", "ci", "test", "style"):
            for suffix in ("", "(readme)"):
                message = f"{prefix}{suffix}: update support files"
                with self.subTest(message=message):
                    result = policy.validate_event(event(message), FakeGit(messages=[message]))
                    self.assertIn("Support-only", result)

    def test_support_paths(self):
        paths = [
            "README.md", "CONTRIBUTING.md", "CHANGELOG.md", "docs/guide.md",
            "nested/notes.MD", ".github/workflows/ci.yml", "examples/basic/main.tf",
            "tests/module.tftest.hcl", ".github/scripts/check_release_policy.py", ".gitignore",
            ".tflint.hcl", ".release-please-manifest.json", "release-please-config.json",
        ]
        self.assertTrue(all(policy.is_support_file(path) for path in paths))
        self.assertIn("Support-only", policy.validate_event(event(), FakeGit(paths)))

    def test_releasing_readme_title_is_rejected(self):
        for title in ("fix: correct README", "feat: update docs", "docs!: breaking docs", "build: tooling"):
            with self.subTest(title=title), self.assertRaises(policy.PolicyError):
                policy.validate_event(event(title), FakeGit())

    def test_every_branch_commit_is_checked(self):
        with self.assertRaisesRegex(policy.PolicyError, "Commit 2"):
            policy.validate_event(event(), FakeGit(messages=["docs: first", "fix: second", "docs: last"]))

    def test_breaking_and_release_overrides_are_rejected(self):
        for override in (
            "BREAKING CHANGE: changed", "BREAKING-CHANGE: changed",
            "BREAKING CHANGE #removed API", "BREAKING-CHANGE #removed API",
            "This is a BREAKING-CHANGE: incompatible command.",
            "This is a BREAKING CHANGE: incompatible command.",
            "Release-As: 2.0.0", "release-as: 2.0.0", "BEGIN_COMMIT_OVERRIDE\nfix: docs",
            "Release-As #2.0.0", "Release-As(scope): 2.0.0",
            "<!-- BEGIN_COMMIT_OVERRIDE\nfix: docs\nEND_COMMIT_OVERRIDE -->",
            "Text BEGIN_NESTED_COMMITfix: nestedEND_NESTED_COMMIT",
            "fix: nested footer", "feat(api): nested footer", "perf: nested footer",
            "chore!: nested breaking footer",
        ):
            with self.subTest(override=override):
                with self.assertRaises(policy.PolicyError):
                    policy.validate_event(event(body=override), FakeGit())
                with self.assertRaises(policy.PolicyError):
                    policy.validate_event(event(), FakeGit(messages=[f"docs: update\n\n{override}"]))

    def test_actual_mixed_and_unknown_payload_keep_normal_behavior(self):
        for path in ("main.tf", "versions.tf", "modules/network/main.tf", "runtime/entrypoint.sh",
                     "docs-runtime/config.json", "future-payload.json", "scripts/bootstrap.sh"):
            with self.subTest(path=path):
                git = FakeGit(paths=["README.md", path], messages=["fix!: module change"])
                self.assertIn("normal release", policy.validate_event(event("fix!: module"), git))
                self.assertEqual(len(git.calls), 2)

    def test_generated_release_pr_is_allowed(self):
        git = FakeGit(
            paths=["CHANGELOG.md", ".release-please-manifest.json", "README.md", "examples/basic/main.tf"],
            messages=["chore(main): release 1.0.2"],
        )
        self.assertIn("Support-only", policy.validate_event(event("chore(main): release 1.0.2"), git))

    def test_generated_major_release_body_is_allowed(self):
        body = (ROOT / "tests/fixtures/release-pr-major.md").read_text()
        self.assertIn("### ⚠ BREAKING CHANGES", body)
        git = FakeGit(
            paths=["CHANGELOG.md", ".release-please-manifest.json", "README.md", "examples/basic/main.tf"],
            messages=["chore(main): release 2.0.0"],
        )
        self.assertIn("Support-only", policy.validate_event(event("chore(main): release 2.0.0", body), git))

    def test_normal_breaking_changes_prose_is_allowed(self):
        prose = "This section explains how to review breaking changes before an upgrade."
        self.assertIn("Support-only", policy.validate_event(
            event(body=prose), FakeGit(messages=[f"docs: explain upgrades\n\n{prose}"])
        ))

    def test_exact_event_head_and_merge_base_are_used(self):
        git = FakeGit()
        policy.validate_event(event(), git)
        self.assertEqual(git.calls[0], ["merge-base", BASE_SHA, HEAD_SHA])
        self.assertIn(HEAD_SHA, git.calls[1])
        self.assertNotIn("HEAD", str(git.calls))
        self.assertIn("--no-renames", git.calls[1])

    def test_incomplete_event_fails_closed(self):
        for invalid in ({}, None, [], {"pull_request": None}, {"pull_request": {}}, {"pull_request": []}):
            with self.subTest(event=invalid), self.assertRaises(policy.PolicyError):
                policy.validate_event(invalid, FakeGit())

    def test_invalid_metadata_fails_closed(self):
        for field, invalid in (("title", None), ("title", ""), ("title", 1),
                               ("title", "docs: title\nfix: hidden"),
                               ("body", ["bad"]), ("body", []), ("body", False), ("body", 0)):
            value = event()
            value["pull_request"][field] = invalid
            with self.subTest(field=field), self.assertRaises(policy.PolicyError):
                policy.validate_event(value, FakeGit())
        for sha in ("--help", "", "not-a-commit", None, "a" * 39, "a" * 40 + "\n"):
            value = event()
            value["pull_request"]["head"]["sha"] = sha
            with self.subTest(sha=sha), self.assertRaises(policy.PolicyError):
                policy.validate_event(value, FakeGit())

    def test_missing_git_history_fails_closed(self):
        with self.assertRaises(policy.PolicyError):
            policy.validate_event(event(), lambda args: "")
        with self.assertRaises(policy.PolicyError):
            policy.validate_event(event(), FakeGit(paths=[]))
        with self.assertRaises(policy.PolicyError):
            policy.validate_event(event(), FakeGit(messages=[]))

    def test_git_errors_fail_closed(self):
        for error in (OSError("missing git"), subprocess.CalledProcessError(128, ["git"])):
            with patch.object(policy.subprocess, "run", side_effect=error):
                with self.assertRaises(policy.PolicyError):
                    policy.run_git(["merge-base", BASE_SHA, HEAD_SHA])

    def test_git_uses_argument_array_and_disables_replacements(self):
        with patch.object(policy.subprocess, "run") as run:
            run.return_value.stdout = MERGE_BASE
            policy.run_git(["merge-base", BASE_SHA, HEAD_SHA])
            self.assertEqual(run.call_args.args[0], ["git", "--no-replace-objects", "merge-base", BASE_SHA, HEAD_SHA])
            self.assertNotIn("shell", run.call_args.kwargs)

    def test_missing_event_environment_fails_closed(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(policy.main(), 1)

    def test_release_config_uses_only_expected_directory_exclusions(self):
        config = json.loads((ROOT / "release-please-config.json").read_text())
        package = config["packages"]["."]
        self.assertEqual(package["release-type"], "terraform-module")
        self.assertEqual(set(package["exclude-paths"]), policy.SUPPORT_DIRECTORIES)
        self.assertFalse(package.get("skip-github-release", False))
        for section in (config, package):
            for override in ("release-as", "changelog-sections"):
                self.assertNotIn(override, section)

    def test_release_workflow_remains_unfiltered(self):
        workflow = (ROOT / ".github/workflows/release-please.yml").read_text()
        self.assertIn("  push:\n    branches:\n      - main", workflow)
        for forbidden in ("paths:", "paths-ignore:", "skip-github-release:", "skip-github-pull-request:", "if:"):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7", workflow)

    def test_ci_executes_guard_and_tests_with_history_and_title_edits(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("types: [opened, synchronize, reopened, edited]", workflow)
        self.assertIn("python3 .github/scripts/check_release_policy.py", workflow)
        self.assertIn("python3 -m unittest discover -s tests -p 'test_release_policy.py'", workflow)


if __name__ == "__main__":
    unittest.main()
