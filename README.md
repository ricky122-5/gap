# gap

`git add -p` with on-demand AI explanations for each hunk, powered by [Claude Code](https://claude.ai/code).

## Demo

```
gap  2 file(s)  4 hunk(s)

────────────────────────────────────────────────────────────
src/escrow.rs  (3 hunks)
────────────────────────────────────────────────────────────

Hunk 1/3
@@ -42,6 +42,12 @@
     let amount = escrow.amount;
+    if amount == 0 {
+        return Err(EscrowError::InvalidAmount);
+    }

Stage this hunk? [y/n/a/d/e/q/?] e
AI:   Adds a guard that rejects zero-amount escrows before processing,
      preventing a class of no-op transactions that would still consume fees.

Stage this hunk? [y/n/a/d/e/q/?] y
✓ Staged 1/3 hunk(s) from src/escrow.rs
```

## Requirements

- Python 3.9+
- [Claude Code](https://claude.ai/code) installed and authenticated (`claude` on your PATH)
- Git

## Install

```sh
curl -o /usr/local/bin/gap https://raw.githubusercontent.com/ricky122-5/gap/main/gap
chmod +x /usr/local/bin/gap
```

Or clone and copy manually:

```sh
git clone https://github.com/ricky122-5/gap
cp gap/gap /usr/local/bin/gap
```

## Usage

```sh
gap                  # all unstaged changes
gap src/main.rs      # specific file(s)
```

### Keys

| Key | Action |
|-----|--------|
| `y` | Stage this hunk |
| `n` | Skip this hunk |
| `a` | Stage this and all remaining hunks in this file |
| `d` | Skip remaining hunks in this file |
| `e` | Fetch AI explanation for this hunk |
| `q` | Quit |
| `?` | Help |

Press `e` only when you want an explanation — no API call is made otherwise.

### Model

Defaults to `claude-haiku-4-5` (fast). Override with:

```sh
GAP_MODEL=claude-sonnet-4-6 gap
```

### Resuming

Already-staged hunks don't appear in `git diff`, so quitting mid-session and re-running `gap` picks up exactly where you left off.

## How it works

1. Runs `git diff` and splits the output into hunks grouped by file
2. For each hunk, shows the diff and prompts immediately
3. If you press `e`, sends the **full file diff** to Claude with the focus hunk marked — so the explanation understands all changes in context, not just the isolated hunk
4. Accepted hunks are staged via `git apply --cached`

## Privacy

When you press `e`, the diff content for that file is sent to Anthropic's servers via the `claude` CLI. Don't use on diffs containing secrets.
