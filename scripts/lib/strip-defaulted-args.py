import sys

# 宣言から「末尾の既定値付き引数」を 1 つ落とす。
#
# 深さの数え方に 2 つの罠がある:
#   - `->` の `>` を閉じ括弧と数えると深さが狂う。先に潰す。
#   - 引数リストの `)` は「最後の )」ではない。戻り値に `)` が出るため、
#     開き `(` に対応する位置を数えて求める。
def _mask(decl):
    return decl.replace("->", "\x00\x00")

def _param_range(decl):
    m = _mask(decl)
    open_i = m.find("(")
    if open_i < 0:
        return None
    depth = 0
    for i in range(open_i, len(m)):
        ch = m[i]
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
            if depth == 0:
                return open_i, i
    return None

def drop_last_defaulted(decl):
    r = _param_range(decl)
    if r is None:
        return None
    open_i, close_i = r
    m = _mask(decl)
    depth = 0
    last_comma = -1
    for i in range(open_i, close_i):
        ch = m[i]
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        elif ch == "," and depth == 1:
            last_comma = i
    if last_comma < 0:
        return None
    depth = 0
    has_default = False
    for ch in m[last_comma:close_i]:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        elif ch == "=" and depth == 0:
            has_default = True
    if not has_default:
        return None
    return decl[:last_comma] + decl[close_i:]

for line in sys.stdin:
    d = line.rstrip("\n")
    while True:
        n = drop_last_defaulted(d)
        if n is None:
            break
        d = n
        print(d)
