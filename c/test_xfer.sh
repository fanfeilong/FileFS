#!/usr/bin/env bash
# Binary import/export smoke test for FileXfer.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf test_xfer_host test_xfer_out test_xfer.ffs
mkdir -p test_xfer_host/assets

# Binary payload with NULs and high bytes
printf 'hello\x00\x01\x02\xff\xfe binary' > test_xfer_host/blob.bin
printf 'plain text\n' > test_xfer_host/readme.txt
printf '\x89PNG\r\n\x1a\nfake' > test_xfer_host/assets/pic.png

make demo >/dev/null

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

./demo >"$OUT" <<EOF
mkfs test_xfer.ffs
mount test_xfer.ffs
import test_xfer_host/blob.bin blob.bin
import test_xfer_host/readme.txt readme.txt
importtree test_xfer_host/assets assets
ls
ls assets
filesize blob.bin
export blob.bin test_xfer_out_blob.bin
exporttree / test_xfer_out
git init
git add blob.bin
git add assets/pic.png
git commit import binary assets
git log
q
EOF

echo "==== demo output ===="
cat "$OUT"
echo "==== checks ===="

grep -q "import test_xfer_host/blob.bin -> blob.bin" "$OUT"
grep -q "import-tree" "$OUT"
grep -q "export blob.bin -> test_xfer_out_blob.bin" "$OUT"
grep -q "Initialized empty FileGit repository" "$OUT"
grep -q "\[main " "$OUT"

# Byte-identical round trip
cmp -s test_xfer_host/blob.bin test_xfer_out_blob.bin
cmp -s test_xfer_host/blob.bin test_xfer_out/blob.bin
cmp -s test_xfer_host/readme.txt test_xfer_out/readme.txt
cmp -s test_xfer_host/assets/pic.png test_xfer_out/assets/pic.png

# Ensure NULs survived (file size must match)
HOST_SZ=$(wc -c < test_xfer_host/blob.bin)
OUT_SZ=$(wc -c < test_xfer_out_blob.bin)
test "$HOST_SZ" -eq "$OUT_SZ"

echo "FileXfer binary smoke test PASSED"
