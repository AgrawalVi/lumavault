#!/usr/bin/env python3
"""Antigravity SessionStart & PreToolUse hook enforcing Linear/chore branch names."""

import json
import os
import re
import subprocess
import sys

VALID_BRANCH_RE = re.compile(
    r"^(([a-z0-9._-]+/)?lum-[0-9]+(-[a-z0-9._-]+)?|(chore|docs|ci)/[a-z0-9][a-z0-9._-]*)$"
)


def is_subpath(path: str, parent: str) -> bool:
    if not path or not parent:
        return False
    real_path = os.path.realpath(os.path.abspath(path))
    real_parent = os.path.realpath(os.path.abspath(parent))
    try:
        return os.path.commonpath([real_path, real_parent]) == real_parent
    except ValueError:
        return False


def read_branch_from_gitfile(repo_dir: str) -> str:
    dot_git = os.path.join(repo_dir, ".git")
    git_dir = dot_git
    if os.path.isfile(dot_git):
        try:
            with open(dot_git, encoding="utf-8") as f:
                line = f.readline().strip()
            if line.startswith("gitdir:"):
                raw = line.split(":", 1)[1].strip()
                git_dir = (
                    raw
                    if os.path.isabs(raw)
                    else os.path.normpath(os.path.join(repo_dir, raw))
                )
        except OSError:
            return ""
    head_path = os.path.join(git_dir, "HEAD")
    try:
        with open(head_path, encoding="utf-8") as f:
            head = f.readline().strip()
    except OSError:
        return ""
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/") :]
    return "(detached HEAD)" if head else ""


def current_branch(repo_dir: str) -> str:
    if not repo_dir:
        return ""
    try:
        res = subprocess.run(
            ["git", "-C", repo_dir, "symbolic-ref", "--quiet", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0:
            return res.stdout.strip()
    except OSError:
        pass
    return read_branch_from_gitfile(repo_dir)


def main() -> None:
    raw = sys.stdin.read().strip()
    payload = json.loads(raw) if raw else {}

    event = payload.get("hookEventName", "")
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    workspaces = payload.get("workspacePaths") or [repo_root]
    cwd = payload.get("cwd") or workspaces[0]

    branch = current_branch(cwd) or current_branch(repo_root)
    branch_ok = bool(branch and VALID_BRANCH_RE.match(branch))

    if event == "SessionStart":
        if branch_ok:
            print("{}")
            return
        shown = branch or "(unknown)"
        msg = (
            f"Active git branch '{shown}' is not a valid Linear issue or chore branch. "
            "Before editing any repository files (Step 0): "
            "(1) for issue work, call Linear `get_issue` to read `gitBranchName` "
            "(or ask the user which `LUM-XX` issue applies) and run "
            "`git fetch origin && git checkout -B <gitBranchName> origin/main`; "
            "(2) for non-issue repo/docs/CI chores only, run "
            "`git fetch origin && git checkout -B chore/<slug> origin/main` "
            "(allowed prefixes: `chore/`, `docs/`, `ci/`)."
        )
        print(json.dumps({"injectSteps": [{"systemMessage": {"systemMessage": msg}}]}))
        return

    if event == "PreToolUse":
        target = (payload.get("toolCall") or {}).get("args", {}).get("Path", "")
        if target and not os.path.isabs(target):
            target = os.path.join(cwd, target)

        artifact_dir = payload.get("artifactDirectoryPath", "")
        if artifact_dir and is_subpath(target, artifact_dir):
            print(json.dumps({"decision": "allow"}))
            return

        in_workspace = any(is_subpath(target, ws) for ws in workspaces) or is_subpath(
            target, repo_root
        )
        if not in_workspace:
            print(json.dumps({"decision": "ask"}))
            return

        if branch_ok:
            print(json.dumps({"decision": "allow"}))
            return

        shown = branch or "(detached HEAD)"
        reason = (
            f"Blocked repo edit on branch '{shown}'. "
            "Switch to the Linear issue's `gitBranchName` first (`get_issue` -> "
            "`git fetch origin && git checkout -B <gitBranchName> origin/main`), "
            "or `chore/<slug>` / `docs/<slug>` / `ci/<slug>` for non-issue chores."
        )
        print(json.dumps({"decision": "deny", "reason": reason}))
        return

    print("{}")


if __name__ == "__main__":
    main()
