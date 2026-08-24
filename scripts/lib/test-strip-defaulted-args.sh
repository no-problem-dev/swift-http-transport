#!/bin/bash
# strip-defaulted-args.py の判定を固定する。
#
# ここが狂うと版計算が狂い、被依存側へ不要な major を配るか、
# 逆に本物の破壊を minor として通してしまう。後者の方が危ないので、
# 「相殺してはいけない」側のケースを厚めに置く。
set -eo pipefail
cd "$(dirname "$0")"
PASS=0; FAIL=0

check() { # removed added expected label
  local hit=0
  printf '%s\n' "$2" | python3 strip-defaulted-args.py | grep -qxF "$1" && hit=1
  if [ "$hit" = "$3" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $4 (相殺=$hit 期待=$3)" >&2
  fi
}

# 相殺してはいけない（本物の破壊）
check "func f(_ x: Int) -> Void" "func f(_ x: String) -> Void" 0 "引数の型が変わった"
check "func g(_ x: Int) -> Void" "func g(_ x: Int, y: Int) -> Void" 0 "必須引数を足した"
check "func gone() -> Void" "func other(_ x: Int = 0) -> Void" 0 "関数が消えた"
check "func m(_ a: Int, b: Int = 0) -> Void" "func m(_ a: Int) -> Void" 0 "既定値付き引数を消した"

# 相殺してよい（呼び出しは無変更で通る）
check "func h(_ x: Int) -> Void" "func h(_ x: Int, y: Int = 0) -> Void" 1 "既定値付きを 1 つ足した"
check "func k(_ a: Int) -> Void" "func k(_ a: Int, b: Int = 0, c: Int = 0) -> Void" 1 "既定値付きを 2 つ足した"
check "func n(_ a: Int) -> (Int, Int)" "func n(_ a: Int, b: Int = 0) -> (Int, Int)" 1 "戻り値に括弧がある"
check \
  "func sseEvents(_ request: HTTPRequest) -> AsyncThrowingStream<SSEEvent, any Error>" \
  "func sseEvents(_ request: HTTPRequest, onRawFrame: (@Sendable (Data) -> Void)? = nil) -> AsyncThrowingStream<SSEEvent, any Error>" \
  1 "クロージャの既定値（-> を含む型）"
check \
  "init(id: UUID = UUID(), at: Date = Date(), kind: Kind, summary: String, detail: String? = nil)" \
  "init(id: UUID = UUID(), at: Date = Date(), kind: Kind, summary: String, detail: String? = nil, deltas: [String] = [])" \
  1 "既存の既定値が複数ある宣言に 1 つ足した"

echo "strip-defaulted-args: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
