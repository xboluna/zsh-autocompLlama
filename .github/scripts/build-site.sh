#!/usr/bin/env bash
# Build the GitHub Pages site into a directory (default: _site):
#   index.html     the README, rendered
#   llms.txt       a short index for language models (llms.txt convention)
#   llms-full.txt  the whole project in one text file: README, install.sh
#                  and the plugin source, for pasting into an assistant
# Needs python3 with the 'markdown' package for index.html; without it a
# plain page that links to the text files is written instead.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$root/_site}
site=https://xboluna.github.io/zsh-autocompLlama
repo=https://github.com/xboluna/zsh-autocompLlama
mkdir -p "$out"

# ---- llms-full.txt --------------------------------------------------------
{
  echo "# zsh-autocompLlama: full project text"
  echo
  echo "> Local AI command completion for zsh, powered by ollama, your command history"
  echo "> and the directory you are in. This file is the README, the installer and the"
  echo "> plugin source in one, generated from $repo"
  echo "> (commit $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown), $(date -u +%Y-%m-%d))."
  echo
  echo "Install or update: curl -fsSL $repo/raw/main/install.sh | zsh"
  echo
  echo "---"
  echo
  echo "# README.md"
  echo
  cat "$root/README.md"
  echo
  echo "---"
  echo
  echo "# install.sh"
  echo
  echo '```zsh'
  cat "$root/install.sh"
  echo '```'
  echo
  echo "---"
  echo
  echo "# zsh-autocompllama.zsh (the plugin)"
  echo
  echo '```zsh'
  cat "$root/zsh-autocompllama.zsh"
  echo '```'
  echo
  echo "---"
  echo
  echo "# cli.zsh (the zsh-autocompllama command: update, configure, check)"
  echo
  echo '```zsh'
  cat "$root/cli.zsh"
  echo '```'
} > "$out/llms-full.txt"

# ---- llms.txt -------------------------------------------------------------
cat > "$out/llms.txt" <<EOF
# zsh-autocompLlama

> Local AI command completion for zsh: an oh-my-zsh plugin that suggests the
> next command from your history and a local ollama model, as grey text to
> accept with the right arrow, with rewrites of mistyped or described
> commands shown on a line under the prompt.

## Docs

- [Full project text](${site}/llms-full.txt): README, installer and plugin source in one file
- [README](${site}/): installation, configuration, how it works
- [install.sh]($repo/raw/main/install.sh): idempotent installer and updater (pipe to zsh)

## Source

- [Repository]($repo)
EOF

# ---- index.html -----------------------------------------------------------
if python3 -c 'import markdown' 2>/dev/null; then
  python3 - "$root/README.md" "$out/index.html" "$site" <<'PY'
import sys, html, markdown
src, dst, site = sys.argv[1:4]
body = markdown.markdown(open(src, encoding='utf-8').read(),
                         extensions=['fenced_code', 'tables', 'toc'])
page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>zsh-autocompLlama</title>
<link rel="alternate" type="text/plain" href="{site}/llms-full.txt" title="llms-full.txt">
<style>
:root {{ color-scheme: light dark; --fg: #1b1b1b; --bg: #fff; --muted: #666; --code: #f3f3f3; --line: #ddd; --link: #0b57d0; }}
@media (prefers-color-scheme: dark) {{ :root {{ --fg: #e6e6e6; --bg: #121212; --muted: #9a9a9a; --code: #1e1e1e; --line: #333; --link: #8ab4f8; }} }}
body {{ margin: 0 auto; padding: 24px 16px 64px; max-width: 46rem; font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: var(--fg); background: var(--bg); }}
a {{ color: var(--link); }}
nav {{ font-size: 14px; color: var(--muted); border-bottom: 1px solid var(--line); padding-bottom: 12px; margin-bottom: 24px; }}
nav a {{ margin-right: 14px; }}
pre {{ background: var(--code); padding: 12px 14px; overflow-x: auto; border-radius: 6px; font-size: 13.5px; line-height: 1.45; }}
code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.92em; }}
:not(pre) > code {{ background: var(--code); padding: 1px 5px; border-radius: 4px; }}
table {{ border-collapse: collapse; width: 100%; font-size: 14px; display: block; overflow-x: auto; }}
th, td {{ text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }}
h1, h2, h3 {{ line-height: 1.25; }} h2 {{ margin-top: 2.2em; }}
</style></head><body>
<nav><a href="{site}/llms-full.txt">llms-full.txt</a><a href="{site}/llms.txt">llms.txt</a><a href="https://github.com/xboluna/zsh-autocompLlama">GitHub</a></nav>
{body}
</body></html>
"""
open(dst, 'w', encoding='utf-8').write(page)
PY
else
  cat > "$out/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>zsh-autocompLlama</title>
<p>zsh-autocompLlama: see the <a href="$repo">repository</a>,
<a href="llms-full.txt">llms-full.txt</a> or <a href="llms.txt">llms.txt</a>.</p>
EOF
  echo "note: python3 'markdown' package not found; wrote a plain index.html" >&2
fi

echo "built $out:"; ls -l "$out" | tail -n +2 | awk '{ printf "  %-16s %8d bytes\n", $NF, $5 }'
