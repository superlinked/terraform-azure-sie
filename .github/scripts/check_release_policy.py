"""Keep support-only pull requests out of Terraform module releases."""

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


SUPPORT_DIRECTORIES = frozenset({".github", "docs", "examples", "tests"})
SUPPORT_FILES = frozenset({
    ".gitignore",
    ".tflint.hcl",
    ".release-please-manifest.json",
    "release-please-config.json",
})
NON_RELEASING_TITLE = re.compile(r"^(docs|chore|ci|test|style)(\([^()\r\n]+\))?: \S")
RELEASE_OVERRIDE = re.compile(
    r"BEGIN_(?:COMMIT_OVERRIDE|NESTED_COMMIT)|BREAKING[ -]CHANGE\s*[:#]|^\s*(?:release-as\b|"
    r"(?:feat|feature|fix|perf|revert)(?:\([^()\r\n]*\))?:|"
    r"[a-z][a-z0-9_-]*(?:\([^()\r\n]*\))?!:)",
    re.IGNORECASE | re.MULTILINE,
)
COMMIT_SHA = re.compile(r"[0-9a-f]{40}")


class PolicyError(Exception):
    pass


def is_support_file(path):
    parts = PurePosixPath(path).parts
    return bool(parts) and (
        parts[0] in SUPPORT_DIRECTORIES
        or path in SUPPORT_FILES
        or path.lower().endswith(".md")
    )


def check_message(message, label):
    if not isinstance(message, str) or not NON_RELEASING_TITLE.match(message):
        raise PolicyError(
            f"{label} must use docs:, chore:, ci:, test:, or style: "
            "for a support-only change."
        )
    if RELEASE_OVERRIDE.search(message):
        raise PolicyError(f"{label} must not request a release or breaking change.")


def run_git(args):
    try:
        return subprocess.run(
            ["git", "--no-replace-objects", *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        ).stdout
    except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
        raise PolicyError("Could not inspect the complete pull request Git history.") from error


def validate_event(event, git=run_git):
    try:
        pull_request = event["pull_request"]
        title = pull_request["title"]
        body = pull_request.get("body")
        if body is None:
            body = ""
        base_sha = pull_request["base"]["sha"]
        head_sha = pull_request["head"]["sha"]
    except (KeyError, TypeError) as error:
        raise PolicyError("Missing pull request title or base/head commit metadata.") from error
    if (
        not isinstance(title, str)
        or not title.strip()
        or "\n" in title
        or "\r" in title
        or not isinstance(body, str)
        or any(not isinstance(sha, str) or not COMMIT_SHA.fullmatch(sha) for sha in (base_sha, head_sha))
    ):
        raise PolicyError("Invalid pull request title, body, or commit metadata.")

    merge_base = git(["merge-base", base_sha, head_sha]).strip()
    if not COMMIT_SHA.fullmatch(merge_base):
        raise PolicyError("Could not resolve a unique pull request merge base.")
    changed = git(["diff", "--name-only", "-z", "--no-renames", merge_base, head_sha, "--"])
    if not changed or not changed.endswith("\0"):
        raise PolicyError("Could not enumerate the pull request changed files.")
    paths = changed[:-1].split("\0")
    if any(not path for path in paths):
        raise PolicyError("Invalid pull request changed-file metadata.")
    if any(not is_support_file(path) for path in paths):
        return "Module payload changed; normal release classification applies."

    check_message(title, "Pull request title")
    if RELEASE_OVERRIDE.search(body):
        raise PolicyError("Support-only pull request bodies must not override release classification.")
    messages = git(["log", "--format=%B%x00", "--reverse", f"{merge_base}..{head_sha}", "--"])
    if not messages.rstrip("\n").endswith("\0"):
        raise PolicyError("Could not enumerate the pull request commit messages.")
    commits = [message.strip("\n") for message in messages.rstrip("\n").split("\0")[:-1]]
    if not commits:
        raise PolicyError("No pull request commits were found.")
    for number, message in enumerate(commits, start=1):
        check_message(message, f"Commit {number}")
    return f"Support-only change: title and {len(commits)} commit messages do not request a release."


def main():
    try:
        event_path = os.environ["GITHUB_EVENT_PATH"]
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
        print(validate_event(event))
    except (KeyError, OSError, UnicodeError, json.JSONDecodeError, PolicyError) as error:
        print(f"Release policy failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
