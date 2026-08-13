#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
CLAUDE_HOME="$TEST_ROOT/claude"
export CLAUDE_HOME

mkdir -p "$CLAUDE_HOME/skills/kickoff"
echo "user skill" > "$CLAUDE_HOME/skills/kickoff/SKILL.md"
if "$ROOT/install.sh" >/dev/null 2>&1; then
  echo "FAIL: user-owned skill conflict was overwritten" >&2
  exit 1
fi
grep -q "user skill" "$CLAUDE_HOME/skills/kickoff/SKILL.md"
[ ! -e "$CLAUDE_HOME/CLAUDE.md" ]

"$ROOT/install.sh" --overwrite-skills >/dev/null
test -f "$CLAUDE_HOME/skills/kickoff/.harness-managed"
test -f "$CLAUDE_HOME/harness/journal/drift-log.md"
test -d "$CLAUDE_HOME/skills/kickoff.bak."* 2>/dev/null
"$ROOT/install.sh" --verify >/dev/null

printf '\nuser rule\n' >> "$CLAUDE_HOME/CLAUDE.md"
"$ROOT/install.sh" >/dev/null
grep -q "user rule" "$CLAUDE_HOME/CLAUDE.md"
"$ROOT/install.sh" --verify >/dev/null

printf '\nmodified\n' >> "$CLAUDE_HOME/skills/kickoff/SKILL.md"
if "$ROOT/install.sh" --verify >/dev/null 2>&1; then
  echo "FAIL: verify accepted a modified skill" >&2
  exit 1
fi
if "$ROOT/install.sh" >/dev/null 2>&1; then
  echo "FAIL: update overwrote a user-modified managed skill" >&2
  exit 1
fi
grep -q modified "$CLAUDE_HOME/skills/kickoff/SKILL.md"
"$ROOT/install.sh" --overwrite-skills >/dev/null

"$ROOT/install.sh" --uninstall >/dev/null
grep -q "user rule" "$CLAUDE_HOME/CLAUDE.md"
! grep -q '<!-- HARNESS BEGIN -->' "$CLAUDE_HOME/CLAUDE.md"
[ ! -e "$CLAUDE_HOME/skills/kickoff" ]
test -f "$CLAUDE_HOME/harness/journal/drift-log.md"

echo "existing" > "$CLAUDE_HOME/CLAUDE.md"
if "$ROOT/install.sh" --fresh >/dev/null 2>&1; then
  echo "FAIL: --fresh replaced a non-empty CLAUDE.md" >&2
  exit 1
fi
grep -q '^existing$' "$CLAUDE_HOME/CLAUDE.md"

"$ROOT/install.sh" >/dev/null
printf '\nlocal edit\n' >> "$CLAUDE_HOME/skills/kickoff/SKILL.md"
"$ROOT/install.sh" --uninstall >/dev/null
grep -q 'local edit' "$CLAUDE_HOME/skills/kickoff/SKILL.md"

# A stale/concurrent install lock must stop before touching user files.
mkdir "$CLAUDE_HOME/.harness-install.lock"
cp "$CLAUDE_HOME/CLAUDE.md" "$TEST_ROOT/before-lock-test.md"
if "$ROOT/install.sh" >/dev/null 2>&1; then
  echo "FAIL: install ignored an existing lock" >&2
  exit 1
fi
cmp "$TEST_ROOT/before-lock-test.md" "$CLAUDE_HOME/CLAUDE.md"
rmdir "$CLAUDE_HOME/.harness-install.lock"

# A CLAUDE.md symlinked into a dotfiles repo must stay a symlink, and the
# constitution must land in the linked file rather than replacing the link.
LINK_HOME="$TEST_ROOT/link-claude"
DOTFILES="$TEST_ROOT/dotfiles"
mkdir -p "$LINK_HOME" "$DOTFILES"
echo "user rule" > "$DOTFILES/CLAUDE.md"
ln -s "$DOTFILES/CLAUDE.md" "$LINK_HOME/CLAUDE.md"
CLAUDE_HOME="$LINK_HOME" "$ROOT/install.sh" >/dev/null
test -L "$LINK_HOME/CLAUDE.md"
grep -q '<!-- HARNESS BEGIN -->' "$DOTFILES/CLAUDE.md"
grep -q '^user rule$' "$DOTFILES/CLAUDE.md"
CLAUDE_HOME="$LINK_HOME" "$ROOT/install.sh" >/dev/null
test -L "$LINK_HOME/CLAUDE.md"
[ "$(grep -c '<!-- HARNESS BEGIN -->' "$DOTFILES/CLAUDE.md")" = 1 ]
CLAUDE_HOME="$LINK_HOME" "$ROOT/install.sh" --verify >/dev/null
CLAUDE_HOME="$LINK_HOME" "$ROOT/install.sh" --uninstall >/dev/null
test -L "$LINK_HOME/CLAUDE.md"
! grep -q '<!-- HARNESS BEGIN -->' "$DOTFILES/CLAUDE.md"
grep -q '^user rule$' "$DOTFILES/CLAUDE.md"

# Force final verification to fail with two skills and confirm full rollback.
FIXTURE_ROOT="$TEST_ROOT/fixture-repo"
FIXTURE_HOME="$TEST_ROOT/fixture-claude"
mkdir -p "$FIXTURE_ROOT/skills" "$FIXTURE_ROOT/journal"
cp "$ROOT/install.sh" "$ROOT/constitution.md" "$FIXTURE_ROOT/"
cp "$ROOT/journal/drift-log.template.md" "$FIXTURE_ROOT/journal/"
cp -R "$ROOT/skills/kickoff" "$FIXTURE_ROOT/skills/kickoff"
cp -R "$ROOT/skills/kickoff" "$FIXTURE_ROOT/skills/second"
mkdir -p "$FIXTURE_HOME/skills/kickoff" "$FIXTURE_HOME/skills/second"
echo "original rules" > "$FIXTURE_HOME/CLAUDE.md"
echo "original kickoff" > "$FIXTURE_HOME/skills/kickoff/SKILL.md"
echo "original second" > "$FIXTURE_HOME/skills/second/SKILL.md"
cp "$FIXTURE_HOME/CLAUDE.md" "$TEST_ROOT/original-rules.md"
cp "$FIXTURE_HOME/skills/kickoff/SKILL.md" "$TEST_ROOT/original-kickoff.md"
cp "$FIXTURE_HOME/skills/second/SKILL.md" "$TEST_ROOT/original-second.md"
(
  attempts=0
  while [ ! -f "$FIXTURE_HOME/harness/journal/drift-log.md" ] && [ "$attempts" -lt 500 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ -f "$FIXTURE_HOME/harness/journal/drift-log.md" ]; then
    printf '\nforce verify mismatch\n' >> "$FIXTURE_ROOT/constitution.md"
  fi
) &
watcher_pid=$!
if CLAUDE_HOME="$FIXTURE_HOME" "$FIXTURE_ROOT/install.sh" --overwrite-skills >/dev/null 2>&1; then
  echo "FAIL: forced verification failure unexpectedly succeeded" >&2
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  exit 1
fi
wait "$watcher_pid"
cmp "$TEST_ROOT/original-rules.md" "$FIXTURE_HOME/CLAUDE.md"
cmp "$TEST_ROOT/original-kickoff.md" "$FIXTURE_HOME/skills/kickoff/SKILL.md"
cmp "$TEST_ROOT/original-second.md" "$FIXTURE_HOME/skills/second/SKILL.md"
[ ! -e "$FIXTURE_HOME/harness/journal/drift-log.md" ]
[ ! -e "$FIXTURE_HOME/.harness-install.lock" ]
! find "$FIXTURE_HOME/skills" -maxdepth 1 -name '.harness-stage.*' | grep -q .
test -f "$FIXTURE_HOME/CLAUDE.md.bak."*

echo "install tests: PASS"
