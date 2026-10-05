#!/usr/bin/env bash
# OpenHelix 工具鏈重現腳本：依 manifest.txt 驗證並安裝 debs
# 用法: bash tools/reproduce.sh [安裝前綴，預設為本 tools/ 目錄]
set -euo pipefail
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${1:-$TOOLS}"
MANIFEST="$TOOLS/manifest.txt"

echo "== 驗證 SHA256 =="
while read -r name ver size sha file; do
  [ "$name" = "#" ] || [ -z "$name" ] && continue
  deb="$TOOLS/${file#file:}"
  echo "$sha  $deb" | sha256sum -c -
done < <(grep -v '^#' "$MANIFEST" | grep -v '^$')

echo "== 解包至 $PREFIX =="
for d in "$TOOLS"/debs/*.deb; do
  dpkg -x "$d" "$PREFIX"
done
echo "== 完成。執行: source $TOOLS/env.sh =="
