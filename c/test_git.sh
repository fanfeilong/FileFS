#!/usr/bin/env bash
# Non-interactive smoke test for FileGit inside FileFS.
set -euo pipefail
cd "$(dirname "$0")"

rm -f test_git.ffs
make demo >/dev/null

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

./demo >"$OUT" <<'EOF'
mkfs test_git.ffs
mount test_git.ffs
git init
echo a.txt alpha
mkdir sub
echo sub/b.txt beta
git add a.txt
git add sub/b.txt
git status
git commit initial snapshot
git log
git branch topic
echo a.txt alpha2
git add a.txt
git commit change on main
git checkout topic
cat a.txt
git checkout main
cat a.txt
git show main
ls /.git
ls /.git/objs
q
EOF

echo "==== demo output ===="
cat "$OUT"
echo "==== checks ===="

grep -q "Initialized empty FileGit repository" "$OUT"
grep -q "add /a.txt" "$OUT"
grep -q "add /sub/b.txt" "$OUT"
grep -q "\[main " "$OUT"
grep -q "commit " "$OUT"
grep -q "branch topic" "$OUT"
grep -q "checkout topic" "$OUT"
grep -q "checkout main" "$OUT"
grep -q "alpha2" "$OUT"
grep -q "HEAD" "$OUT"
grep -q "objs" "$OUT"
grep -q "/.git/" "$OUT"

echo "FileGit smoke test PASSED"
