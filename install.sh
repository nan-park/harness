#!/usr/bin/env bash
#
# harness installer. Existing user-owned files are never replaced by default.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CONSTITUTION="$REPO_DIR/constitution.md"
SKILLS_SRC="$REPO_DIR/skills"
JOURNAL_TPL="$REPO_DIR/journal/drift-log.template.md"
LEGACY_JOURNAL="$REPO_DIR/journal/private/drift-log.md"
DATA_DIR="${HARNESS_DATA_DIR:-$CLAUDE_DIR/harness}"
JOURNAL_LOG="$DATA_DIR/journal/drift-log.md"
TARGET_MD="$CLAUDE_DIR/CLAUDE.md"
BEGIN_MARK="<!-- HARNESS BEGIN -->"
END_MARK="<!-- HARNESS END -->"
OWNER_FILE=".harness-managed"

MODE="merge"
OVERWRITE_SKILLS=0
for arg in "$@"; do
  case "$arg" in
    --fresh) MODE="fresh" ;;
    --verify) MODE="verify" ;;
    --uninstall) MODE="uninstall" ;;
    --overwrite-skills) OVERWRITE_SKILLS=1 ;;
    *) echo "[install] 알 수 없는 인자: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "[install] 실패: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3가 필요합니다."
[ -f "$CONSTITUTION" ] || fail "헌법 원본이 없습니다: $CONSTITUTION"
[ -d "$SKILLS_SRC" ] || fail "스킬 디렉터리가 없습니다: $SKILLS_SRC"
[ -f "$JOURNAL_TPL" ] || fail "이탈 장부 서식이 없습니다: $JOURNAL_TPL"

tree_digest() {
  ROOT="$1" OWNER_FILE="$OWNER_FILE" python3 <<'PY'
import hashlib, os
root, owner = os.environ["ROOT"], os.environ["OWNER_FILE"]
h = hashlib.sha256()
for base, dirs, names in os.walk(root):
    dirs.sort()
    for name in sorted(names):
        if name == owner:
            continue
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root).encode()
        h.update(len(rel).to_bytes(8, "big") + rel)
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
print(h.hexdigest())
PY
}

verify_installation() {
  local status=0 name d
  if TARGET_MD="$TARGET_MD" CONSTITUTION="$CONSTITUTION" DATA_DIR="$DATA_DIR" \
     BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" python3 <<'PY'
import os, sys
p = os.environ["TARGET_MD"]
if not os.path.isfile(p):
    print("[verify] 헌법: 없음")
    sys.exit(1)
text = open(p, encoding="utf-8").read()
begin, end = os.environ["BEGIN_MARK"], os.environ["END_MARK"]
if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
    print("[verify] 헌법: 마커 손상")
    sys.exit(1)
actual = text.split(begin, 1)[1].split(end, 1)[0].strip()
expected = open(os.environ["CONSTITUTION"], encoding="utf-8").read().strip()
expected = expected.replace("{{HARNESS_DATA_DIR}}", os.environ["DATA_DIR"])
if actual != expected:
    print("[verify] 헌법: 오래되었거나 수정됨")
    sys.exit(1)
print("[verify] 헌법: 최신")
PY
  then :; else status=1; fi

  for d in "$SKILLS_SRC"/*/; do
    name="$(basename "$d")"
    if [ ! -f "$CLAUDE_DIR/skills/$name/$OWNER_FILE" ]; then
      echo "[verify] 스킬 $name: 없거나 harness 소유가 아님"
      status=1
    elif [ "$(tree_digest "$CLAUDE_DIR/skills/$name")" != "$(cat "$CLAUDE_DIR/skills/$name/$OWNER_FILE")" ]; then
      echo "[verify] 스킬 $name: 설치 후 수정됨"
      status=1
    elif SRC="$d" DST="$CLAUDE_DIR/skills/$name" OWNER_FILE="$OWNER_FILE" python3 <<'PY'
import filecmp, os, sys
src, dst, owner = os.environ["SRC"], os.environ["DST"], os.environ["OWNER_FILE"]
def files(root):
    out = {}
    for base, _, names in os.walk(root):
        for name in names:
            if name == owner:
                continue
            path = os.path.join(base, name)
            out[os.path.relpath(path, root)] = path
    return out
a, b = files(src), files(dst)
ok = a.keys() == b.keys() and all(filecmp.cmp(a[k], b[k], shallow=False) for k in a)
sys.exit(0 if ok else 1)
PY
    then
      echo "[verify] 스킬 $name: 최신"
    else
      echo "[verify] 스킬 $name: 오래되었거나 수정됨"
      status=1
    fi
  done
  if [ -f "$JOURNAL_LOG" ]; then
    echo "[verify] 이탈 장부: 있음 ($JOURNAL_LOG)"
  else
    echo "[verify] 이탈 장부: 없음"
    status=1
  fi
  return "$status"
}

if [ "$MODE" = "verify" ]; then
  verify_installation
  exit $?
fi

mkdir -p "$CLAUDE_DIR"
LOCK_DIR="$CLAUDE_DIR/.harness-install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "다른 설치·제거 작업이 실행 중입니다: $LOCK_DIR (실행 중인 작업이 없다면 이 디렉터리를 지우고 다시 시도하세요)"
fi
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

if [ "$MODE" = "uninstall" ]; then
  if [ -f "$TARGET_MD" ]; then
    TARGET_MD="$TARGET_MD" BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" python3 <<'PY'
import os, sys, tempfile
# 설치와 같은 이유로 심볼릭 링크를 따라간다 — 링크가 아니면 경로가 그대로다.
p = os.path.realpath(os.environ["TARGET_MD"])
begin, end = os.environ["BEGIN_MARK"], os.environ["END_MARK"]
text = open(p, encoding="utf-8").read()
if begin not in text and end not in text:
    print("[uninstall] 헌법 블록: 없음")
    sys.exit()
if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
    sys.exit("[uninstall] 실패: 마커가 손상되어 자동 제거할 수 없습니다.")
head, rest = text.split(begin, 1)
_, tail = rest.split(end, 1)
out = (head.rstrip() + "\n\n" + tail.lstrip()).strip()
out = out + "\n" if out else ""
fd, tmp = tempfile.mkstemp(prefix=".CLAUDE.md.", dir=os.path.dirname(p) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(out)
os.replace(tmp, p)
print("[uninstall] 헌법 블록: 제거됨")
PY
  fi
  for d in "$SKILLS_SRC"/*/; do
    name="$(basename "$d")"
    target="$CLAUDE_DIR/skills/$name"
    if [ -f "$target/$OWNER_FILE" ] && [ "$(tree_digest "$target")" = "$(cat "$target/$OWNER_FILE")" ]; then
      rm -rf -- "$target"
      echo "[uninstall] 스킬 제거: $name"
    elif [ -f "$target/$OWNER_FILE" ]; then
      echo "[uninstall] 수정된 harness 스킬 보존: $name"
    elif [ -e "$target" ]; then
      echo "[uninstall] 사용자 소유 스킬 보존: $name"
    fi
  done
  echo "[uninstall] 이탈 장부는 보존했습니다: $JOURNAL_LOG"
  exit 0
fi

# Preflight all conflicts before changing CLAUDE.md.
for d in "$SKILLS_SRC"/*/; do
  name="$(basename "$d")"
  [ -f "$d/SKILL.md" ] || fail "스킬 $name 에 SKILL.md가 없습니다"
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && [ ! -f "$target/$OWNER_FILE" ] && [ "$OVERWRITE_SKILLS" -ne 1 ]; then
    fail "사용자 소유 스킬과 충돌합니다: $target (교체하려면 --overwrite-skills; 기존 파일은 백업됩니다)"
  elif [ -f "$target/$OWNER_FILE" ] && [ "$(tree_digest "$target")" != "$(cat "$target/$OWNER_FILE")" ] && [ "$OVERWRITE_SKILLS" -ne 1 ]; then
    fail "설치 후 수정된 스킬을 보존했습니다: $target (백업 후 교체하려면 --overwrite-skills)"
  fi
done

if [ "$MODE" = "fresh" ] && [ -s "$TARGET_MD" ]; then
  fail "--fresh는 CLAUDE.md가 없거나 빈 경우에만 사용할 수 있습니다. 기존 파일에는 기본 모드를 사용하세요."
fi

# dotfiles 저장소로 심볼릭 링크된 CLAUDE.md는 링크를 유지한다. 링크 자리에
# 일반 파일을 덮어쓰면 사용자의 dotfiles 동기화가 조용히 끊긴다.
if [ -L "$TARGET_MD" ]; then
  RESOLVED_MD="$(TARGET_MD="$TARGET_MD" python3 -c 'import os; print(os.path.realpath(os.environ["TARGET_MD"]))')"
  [ -d "$(dirname "$RESOLVED_MD")" ] || fail "심볼릭 링크가 가리키는 위치가 없습니다: $RESOLVED_MD"
  echo "[install] 심볼릭 링크 유지: $TARGET_MD -> $RESOLVED_MD"
else
  RESOLVED_MD="$TARGET_MD"
fi

mkdir -p "$CLAUDE_DIR" "$CLAUDE_DIR/skills" "$(dirname "$JOURNAL_LOG")"
STAGE_ROOT="$(mktemp -d "$CLAUDE_DIR/skills/.harness-stage.XXXXXX")"
ROLLBACK_ROOT="$STAGE_ROOT/.rollback"
STAGED_MD="$STAGE_ROOT/.CLAUDE.md.new"
mkdir -p "$ROLLBACK_ROOT/skills" "$ROLLBACK_ROOT/deployed"
TRANSACTION_ACTIVE=0
TARGET_EXISTED=0
JOURNAL_CREATED=0
target_tmp=""

cleanup_or_rollback() {
  status=$?
  trap - EXIT
  if [ "$TRANSACTION_ACTIVE" -eq 1 ] && [ "$status" -ne 0 ]; then
    set +e
    rollback_failed=0
    echo "[install] 배포 실패 — 변경을 되돌리는 중입니다" >&2
    if [ "$TARGET_EXISTED" -eq 1 ]; then
      cp "$ROLLBACK_ROOT/CLAUDE.md" "$RESOLVED_MD" || rollback_failed=1
    else
      rm -f -- "$RESOLVED_MD" || rollback_failed=1
    fi
    for source_dir in "$SKILLS_SRC"/*/; do
      rollback_name="$(basename "$source_dir")"
      if [ -e "$ROLLBACK_ROOT/skills/$rollback_name" ]; then
        rm -rf -- "$CLAUDE_DIR/skills/$rollback_name" || rollback_failed=1
        mv "$ROLLBACK_ROOT/skills/$rollback_name" "$CLAUDE_DIR/skills/$rollback_name" || rollback_failed=1
      elif [ -e "$ROLLBACK_ROOT/deployed/$rollback_name" ]; then
        rm -rf -- "$CLAUDE_DIR/skills/$rollback_name" || rollback_failed=1
      fi
    done
    if [ "$JOURNAL_CREATED" -eq 1 ]; then
      rm -f -- "$JOURNAL_LOG" || rollback_failed=1
    fi
    if [ "$rollback_failed" -eq 0 ]; then
      echo "[install] 기존 파일 상태로 복구했습니다" >&2
    else
      echo "[install] 경고: 일부 항목을 복구하지 못했습니다. 위 오류와 백업을 확인하세요." >&2
    fi
  fi
  if [ -n "$target_tmp" ]; then
    rm -f -- "$target_tmp"
  fi
  rm -rf -- "$STAGE_ROOT"
  release_lock
  exit "$status"
}
trap cleanup_or_rollback EXIT

for d in "$SKILLS_SRC"/*/; do
  name="$(basename "$d")"
  mkdir -p "$STAGE_ROOT/$name"
  cp -R "$d"/. "$STAGE_ROOT/$name"/
  tree_digest "$STAGE_ROOT/$name" > "$STAGE_ROOT/$name/$OWNER_FILE"
done

if [ -f "$TARGET_MD" ]; then
  TARGET_EXISTED=1
  cp "$TARGET_MD" "$ROLLBACK_ROOT/CLAUDE.md"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$TARGET_MD.bak.$stamp"
  n=1
  while [ -e "$backup" ]; do backup="$TARGET_MD.bak.$stamp-$n"; n=$((n + 1)); done
  cp "$ROLLBACK_ROOT/CLAUDE.md" "$backup"
  echo "[install] 백업: $backup"
else
  : > "$ROLLBACK_ROOT/CLAUDE.md"
  backup=""
fi

# Preserve user-owned or locally modified skills before changing deployment
# targets. These backups intentionally remain even if a later step fails.
for d in "$SKILLS_SRC"/*/; do
  name="$(basename "$d")"
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && { [ ! -f "$target/$OWNER_FILE" ] || [ "$(tree_digest "$target")" != "$(cat "$target/$OWNER_FILE")" ]; }; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    skill_backup="$target.bak.$stamp"
    n=1
    while [ -e "$skill_backup" ]; do skill_backup="$target.bak.$stamp-$n"; n=$((n + 1)); done
    cp -R "$target" "$skill_backup"
    echo "[install] 기존 스킬 백업: $skill_backup"
  fi
done

TARGET_MD="$TARGET_MD" STAGED_MD="$STAGED_MD" CONSTITUTION="$CONSTITUTION" DATA_DIR="$DATA_DIR" \
BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" MODE="$MODE" python3 <<'PY'
import os, sys
p = os.environ["TARGET_MD"]
begin, end = os.environ["BEGIN_MARK"], os.environ["END_MARK"]
body = open(os.environ["CONSTITUTION"], encoding="utf-8").read().strip()
body = body.replace("{{HARNESS_DATA_DIR}}", os.environ["DATA_DIR"])
block = f"{begin}\n{body}\n{end}"
existing = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
if os.environ["MODE"] == "fresh":
    out, action = block + "\n", "전체 교체(--fresh)"
else:
    bc, ec = existing.count(begin), existing.count(end)
    if bc != ec or bc > 1 or (bc == 1 and existing.index(begin) > existing.index(end)):
        sys.exit("[install] 실패: 마커가 중복되었거나 손상되었습니다.")
    if bc == 1:
        head, rest = existing.split(begin, 1)
        _, tail = rest.split(end, 1)
        out, action = head + block + tail, "블록 교체"
    elif existing.strip():
        out, action = block + "\n\n" + existing.lstrip("\n"), "블록 추가"
    else:
        out, action = block + "\n", "블록 기록"
with open(os.environ["STAGED_MD"], "w", encoding="utf-8") as f: f.write(out)
print(f"[install] 헌법 {action}")
PY

# Everything above is preparation. From here on, any failure restores the
# original CLAUDE.md, skills, and newly-created journal.
TRANSACTION_ACTIVE=1

if [ ! -f "$JOURNAL_LOG" ]; then
  JOURNAL_CREATED=1
  if [ -f "$LEGACY_JOURNAL" ]; then
    cp "$LEGACY_JOURNAL" "$JOURNAL_LOG"
    echo "[install] 기존 이탈 장부 이전: $LEGACY_JOURNAL -> $JOURNAL_LOG"
  else
    cp "$JOURNAL_TPL" "$JOURNAL_LOG"
    echo "[install] 이탈 장부 생성: $JOURNAL_LOG"
  fi
else
  echo "[install] 이탈 장부 보존: $JOURNAL_LOG"
fi

target_tmp="$(mktemp "$(dirname "$RESOLVED_MD")/.CLAUDE.md.XXXXXX")"
cp "$STAGED_MD" "$target_tmp"
mv "$target_tmp" "$RESOLVED_MD"

for d in "$SKILLS_SRC"/*/; do
  name="$(basename "$d")"
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && { [ ! -f "$target/$OWNER_FILE" ] || [ "$(tree_digest "$target")" != "$(cat "$target/$OWNER_FILE")" ]; }; then
    mv "$target" "$ROLLBACK_ROOT/skills/$name"
  elif [ -e "$target" ]; then
    mv "$target" "$ROLLBACK_ROOT/skills/$name"
  fi
  : > "$ROLLBACK_ROOT/deployed/$name"
  mv "$STAGE_ROOT/$name" "$target"
  echo "[install] 스킬 배포: $name"
done

verify_installation || fail "설치 후 검증에 실패했습니다"

TRANSACTION_ACTIVE=0
echo "[install] 완료 — 배포본: $CLAUDE_DIR"
