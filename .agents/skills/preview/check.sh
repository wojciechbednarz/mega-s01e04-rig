#!/usr/bin/env bash
# Check a preview link before it is sent to the reviewer (skill: preview, ADR 0003).
# Usage: LANE_MARKER=<marker> check.sh <url> <saved-file> marker|clean
# The marker is read from the environment and never printed.
set -uo pipefail
url=${1:?url}; file=${2:?saved file}; mode=${3:?marker|clean}
fails=0; out=()
ok()   { out+=("ok   $1"); }
fail() { out+=("FAIL $1"); fails=$((fails+1)); }

# 1. real HTTPS host, not an IP, not localhost
host=$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$url")
if [[ $url != https://* ]]; then fail "not https"
elif [[ $host =~ ^[0-9.]+$ || $host == *:* || $host == localhost* ]]; then fail "host is an IP or localhost: $host"
else ok "https, real host $host"; fi

# 2. 200 text/html, bytes on the link = the saved file
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
meta=$(curl -sS -H 'Cache-Control: no-cache' -o "$tmp" -w '%{http_code} %{content_type}' "$url") || meta="000 -"
code=${meta%% *}; ctype=${meta#* }
[[ $code == 200 ]] && ok "200 from this machine" || fail "status $code from this machine"
[[ $ctype == text/html* ]] && ok "Content-Type $ctype" || fail "Content-Type $ctype"
if cmp -s "$tmp" "$file"; then ok "link serves the saved file ($(wc -c <"$file") B)"; else fail "link bytes differ from $file"; fi

# 3. self-contained: no script, no outside resources (ADR 0001)
if grep -qiE '<script|(src|href)="(https?:)?//' "$tmp"; then fail "page loads script or outside resources"; else ok "self-contained"; fi

# 4. marker state
if [[ $mode == marker ]]; then
  [[ -n ${LANE_MARKER:-} ]] || { fail "LANE_MARKER not set"; }
  [[ -n ${LANE_MARKER:-} ]] && grep -qF "$LANE_MARKER" "$tmp" && ok "lane marker on the page" || fail "lane marker missing"
else
  grep -qF "no marker set" "$tmp" && ok "banner: no marker set" || fail "banner has no 'no marker set'"
  [[ -n ${LANE_MARKER:-} ]] && grep -qF "$LANE_MARKER" "$tmp" && fail "old marker still on the page"
fi

# 5. opens from outside: public check nodes on other networks (check-host.net)
nodes=${NODES:-5}
req=$(curl -sS -H 'Accept: application/json' "https://check-host.net/check-http?host=$url&max_nodes=$nodes") || req=""
id=$(python3 -Ic 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("request_id",""))' <<<"$req" 2>/dev/null)
if [[ -z $id ]]; then fail "outside check could not start"
else
  sleep 8
  res=$(curl -sS -H 'Accept: application/json' "https://check-host.net/check-result/$id")
  summary=$(python3 -Ic '
import json,sys
r=json.loads(sys.stdin.read()); good=0; lines=[]
for node,v in r.items():
    st = v[0][3] if v and v[0] and len(v[0])>3 else "no answer"
    good += str(st) == "200";lines.append(node.split(".")[0] + "=" + str(st))
print(f"{good}/{len(r)} " + " ".join(sorted(lines)))' <<<"$res")
  n_ok=${summary%%/*}; rest=${summary#*/}; n_all=${rest%% *}
  [[ $n_all -gt 0 && $n_ok == "$n_all" ]] && ok "opens from outside: $summary" || fail "outside: $summary"
fi

echo "preview check · $(date -u +%FT%TZ) · $url · mode $mode"
printf '%s\n' "${out[@]}"
[[ $fails -eq 0 ]] && echo "PASS" || { echo "FAIL ($fails)"; exit 1; }
