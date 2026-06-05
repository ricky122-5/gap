#!/usr/bin/env python3
"""gap — git add -p with per-hunk AI explanations via the claude CLI"""

import subprocess
import sys
import os
import re
import textwrap
from dataclasses import dataclass, field
from typing import List, Optional

RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[31m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
CYAN   = "\033[36m"


@dataclass
class Hunk:
    header: str
    lines: List[str]
    index: int  # 0-based within file


@dataclass
class FileDiff:
    path: str
    header_lines: List[str]  # diff --git …, index …, --- …, +++ …
    hunks: List[Hunk] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Diff parsing
# ---------------------------------------------------------------------------

def parse_diff(diff_text: str) -> List[FileDiff]:
    files: List[FileDiff] = []
    current_file: Optional[FileDiff] = None
    current_hunk: Optional[Hunk] = None
    in_hunk = False

    for line in diff_text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            _flush_file(files, current_file, current_hunk)
            current_hunk = None
            m = re.match(r"diff --git a/(.*) b/(.*)\n?", line)
            path = m.group(2) if m else line.strip()
            current_file = FileDiff(path=path, header_lines=[line])
            in_hunk = False

        elif line.startswith("@@") and current_file is not None:
            if current_hunk is not None:
                current_file.hunks.append(current_hunk)
            current_hunk = Hunk(header=line, lines=[], index=len(current_file.hunks))
            in_hunk = True

        elif in_hunk and current_hunk is not None:
            current_hunk.lines.append(line)

        elif current_file is not None and not in_hunk:
            current_file.header_lines.append(line)

    _flush_file(files, current_file, current_hunk)
    return files


def _flush_file(
    files: List[FileDiff],
    file_diff: Optional[FileDiff],
    hunk: Optional[Hunk],
) -> None:
    if file_diff is None:
        return
    if hunk is not None:
        file_diff.hunks.append(hunk)
    if file_diff.hunks:
        files.append(file_diff)


# ---------------------------------------------------------------------------
# AI explanation
# ---------------------------------------------------------------------------

def get_explanation(file_diff: FileDiff, hunk: Hunk) -> str:
    # Build full file diff, highlighting the focus hunk so the model has context
    # for the entire change set but knows exactly which hunk to explain.
    full_diff = "".join(file_diff.header_lines)
    for h in file_diff.hunks:
        if h.index == hunk.index:
            full_diff += "### FOCUS HUNK START ###\n"
        full_diff += h.header + "".join(h.lines)
        if h.index == hunk.index:
            full_diff += "### FOCUS HUNK END ###\n"

    prompt = (
        f"You are reviewing a git diff for `{file_diff.path}`.\n\n"
        f"All changes to this file:\n\n```diff\n{full_diff}```\n\n"
        f"In 2-3 sentences explain what the FOCUS HUNK does. "
        f"Focus on intent and impact, not just what lines changed. Be concise."
    )

    try:
        model = os.environ.get("GAP_MODEL", "claude-haiku-4-5-20251001")
        cmd = ["claude", "-p", prompt, "--model", model]
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=45,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        err = (result.stderr or "").strip()[:120]
        return f"(explanation unavailable: {err})"
    except subprocess.TimeoutExpired:
        return "(timed out after 45s)"
    except FileNotFoundError:
        return "(claude CLI not found — is Claude Code installed?)"


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

def print_hunk(hunk: Hunk) -> None:
    print(f"{CYAN}{hunk.header.rstrip()}{RESET}")
    for line in hunk.lines:
        s = line.rstrip("\n")
        if s.startswith("+"):
            print(f"{GREEN}{s}{RESET}")
        elif s.startswith("-"):
            print(f"{RED}{s}{RESET}")
        else:
            print(s)


HELP = f"""
  {BOLD}y{RESET} - stage this hunk
  {BOLD}n{RESET} - skip this hunk
  {BOLD}a{RESET} - stage this and all remaining hunks in this file
  {BOLD}d{RESET} - skip remaining hunks in this file
  {BOLD}e{RESET} - explain this hunk with AI
  {BOLD}q{RESET} - quit (stop processing)
  {BOLD}?{RESET} - show this help
"""


# ---------------------------------------------------------------------------
# Patch construction + application
# ---------------------------------------------------------------------------

def build_patch(file_diff: FileDiff, hunks: List[Hunk]) -> str:
    return "".join(file_diff.header_lines) + "".join(
        h.header + "".join(h.lines) for h in hunks
    )


def apply_patch(patch: str) -> bool:
    result = subprocess.run(
        ["git", "apply", "--cached", "-"],
        input=patch, text=True, capture_output=True,
    )
    if result.returncode != 0:
        print(f"{RED}Failed to stage: {result.stderr.strip()}{RESET}")
        return False
    return True


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main() -> None:
    file_args = sys.argv[1:]
    cmd = ["git", "diff"] + (["--"] + file_args if file_args else [])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"git diff failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    if not result.stdout.strip():
        print("No unstaged changes.")
        sys.exit(0)

    files = parse_diff(result.stdout)
    if not files:
        print("No changes to stage.")
        sys.exit(0)

    total = sum(len(f.hunks) for f in files)
    print(f"{BOLD}gap{RESET}  {len(files)} file(s)  {total} hunk(s)\n")

    quit_flag = False

    for file_diff in files:
        if quit_flag:
            break
        if not file_diff.hunks:
            continue

        n = len(file_diff.hunks)
        print(f"{BOLD}{'─' * 60}{RESET}")
        print(f"{BOLD}{file_diff.path}{RESET}  {DIM}({n} hunk{'s' if n != 1 else ''}){RESET}")
        print(f"{BOLD}{'─' * 60}{RESET}")

        selected: List[Hunk] = []
        stage_all = False
        skip_file = False

        for hunk in file_diff.hunks:
            if quit_flag or skip_file:
                break

            if stage_all:
                selected.append(hunk)
                continue

            print(f"\n{BOLD}Hunk {hunk.index + 1}/{n}{RESET}")
            print_hunk(hunk)
            print()

            while True:
                try:
                    choice = input("Stage this hunk? [y/n/a/d/e/q/?] ").strip().lower()
                except (EOFError, KeyboardInterrupt):
                    print()
                    quit_flag = True
                    break

                if choice == "e":
                    sys.stdout.write(f"{DIM}AI: thinking...{RESET}")
                    sys.stdout.flush()
                    explanation = get_explanation(file_diff, hunk)
                    wrapped = textwrap.fill(explanation, width=76, subsequent_indent="      ")
                    sys.stdout.write(f"\r\033[K{YELLOW}AI:{RESET}   {wrapped}\n\n")
                    continue
                elif choice == "y":
                    selected.append(hunk)
                    break
                elif choice == "n":
                    break
                elif choice == "a":
                    selected.append(hunk)
                    stage_all = True
                    break
                elif choice == "d":
                    skip_file = True
                    break
                elif choice == "q":
                    quit_flag = True
                    break
                elif choice == "?":
                    print(HELP)
                else:
                    print("  y / n / a / d / q / ?  (? for help)")

        if selected:
            patch = build_patch(file_diff, selected)
            if apply_patch(patch):
                print(
                    f"{GREEN}✓{RESET} Staged {len(selected)}/{n} hunk(s) "
                    f"from {BOLD}{file_diff.path}{RESET}"
                )

    print(f"\n{DIM}Done. Run 'git status' to see staged changes.{RESET}")


if __name__ == "__main__":
    main()
