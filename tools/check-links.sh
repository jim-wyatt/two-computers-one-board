#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Do the external links in the documentation still resolve?
#
#   tools/check-links.sh
#
# Requests every http(s) URL in docs/**/*.md and README.md once, and lists the
# ones that did not answer 2xx or 3xx, each with the file:line it came from.
#
# Exit status: 0 nothing dead, 1 at least one dead link, 2 could not run at all
# (no curl, or no network - see the end of this file).
#
# NOT PART OF check.sh, AND THAT IS DELIBERATE
# --------------------------------------------
# check.sh has to pass offline, on a board with no uplink, and give the same
# answer twice. This needs the network and depends on a hundred other people's
# servers; as a gate it would be a flaky one, and a dead third-party link is not
# a reason to block a merge anyway. `zensical --strict` already checks the
# INTERNAL links, against the real directory tree, with no network.
#
# So it runs on a schedule instead: .github/workflows/links.yml, monthly, which
# files one issue with whatever this prints. Run it by hand before adding to
# docs/further-reading.md.
#
# WHAT IT CANNOT TELL YOU
# -----------------------
# That a page still says what the annotation beside it claims. A 200 for a
# parked domain or a "this article has moved" page counts as alive here.
#
# A #fragment is not checked either: it is never sent to the server, so the page
# is requested once however many anchors into it the docs use.
set -uo pipefail

case "${1:-}" in
  "") ;;
  -h | --help)
    sed -n '4,12p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$PROJECT" || exit 2
command -v curl >/dev/null 2>&1 || {
  echo "curl is missing" >&2
  exit 2
}

# A browser's, because the default "curl/8.x" is refused outright by a good many
# sites. It is a courtesy request for one page a month, not a crawl.
#
# It is also not the whole answer, and cuts both ways: a site with a real bot
# detector sees a "Chrome" that does not behave like Chrome and refuses THAT,
# while letting an honest curl straight through. www.freedesktop.org (418) and
# developer.arm.com (403) both did exactly this. So a link that fails with this
# is asked once more as plain curl before anything is concluded - see status_of.
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

# Hosts that answer 403 to anything automated and work fine in a browser. A 403
# from one of these is reported as UNVERIFIABLE - look at it by hand - rather
# than as dead, because a checker that cries wolf every month stops being read.
#
# Only a 403 is excused. A 404 or no answer at all from the same host is still
# a dead link. A subdomain matches too: st.com covers www.st.com.
#
# Keep this short. Every entry is a link nobody is checking; add one only after
# opening the page in a browser, and say here what was seen.
BLOCKS_AUTOMATION=(
  linuxjourney.com # 403 to curl with any User-Agent; fine in a browser
  wiki.osdev.org   # same - sits behind a bot challenge
  st.com           # 403 or a hang, depending on the day; fine in a browser
  # 403 to GitHub's runners only: 200 from a home connection, plain curl and a
  # browser User-Agent alike (checked from the board, 2026-11-01, #192).
  cppreference.com
  explainshell.com
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# https://www.st.com:443/a/b?c -> www.st.com
host_of() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"
  echo "${host%%:*}"
}

# --- 1. Find them ------------------------------------------------------------
#
# Every URL, not only [text](url): a bare link in a code block is just as much a
# promise to the reader. The pattern stops at whitespace and at the characters
# Markdown wraps a URL in; what it cannot know is where a sentence ends, so the
# trailing punctuation comes off afterwards - "(see https://x.org/a)." and
# "**[x](https://x.org/)**" both have to come out clean. A closing bracket is
# only stripped while it is unbalanced, which keeps .../wiki/Foo_(bar) whole.
# An apostrophe ends a URL too: "[prj.conf](https://x.org/prj.conf)'s" is real.
#
# Out: "url<TAB>file:line", one per occurrence.
find_links() {
  local where url opens closes
  grep -rnoE --include='*.md' "https?://[^][:space:]<>\"'\`|\\\\]+" docs README.md 2>/dev/null |
    while IFS= read -r hit; do
      url="${hit#*:*:}"
      where="${hit%":$url"}"
      while :; do
        case "$url" in
          *[.,\;:\!\?\*_])
            url="${url%?}"
            ;;
          *\))
            opens="${url//[^(]/}"
            closes="${url//[^)]/}"
            [ "${#closes}" -gt "${#opens}" ] || break
            url="${url%?}"
            ;;
          *) break ;;
        esac
      done
      printf '%s\t%s\n' "$url" "$where"
    done
}

# Not external, or not a real address: this machine, a board on a LAN, the
# reserved example domains, and anything with a shell variable or a placeholder
# still in it (https://github.com/.../download/v$SDK_VERSION is not a page).
checkable() {
  local host
  host="$(host_of "$1")"
  case "$1" in *[\$\{\}\*]*) return 1 ;; esac
  case "$host" in
    localhost | *.local | *.lan | *.internal | *.test | *.invalid) return 1 ;;
    example.com | example.org | example.net | *.example.com | *.example.org | *.example.net | *.example) return 1 ;;
    127.* | 10.* | 192.168.* | 169.254.* | 0.0.0.0) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;; # no dot: a bare hostname, not something on the internet
  esac
}

find_links >"$TMP/all"
: >"$TMP/links"
while IFS=$'\t' read -r url where; do
  checkable "$url" && printf '%s\t%s\n' "${url%%#*}" "$where" >>"$TMP/links"
done <"$TMP/all"
# Round-robin across hosts rather than alphabetical: every first link to a
# host, then every second, and so on. Sorted plainly, the twenty github.com
# links arrive back to back, and GitHub answers a burst like that with 429 and
# then 503 - for pages that are perfectly fine.
cut -f1 "$TMP/links" | sort -u |
  awk '{ h = $0; sub(/^[a-z]*:\/\//, "", h); sub(/[\/?#:].*/, "", h); print ++n[h] "\t" $0 }' |
  sort -s -n -k1,1 | cut -f2 >"$TMP/urls"
total="$(wc -l <"$TMP/urls")"
if [ "$total" -eq 0 ]; then
  echo "found no external links under docs/ or in README.md - that is not right" >&2
  exit 2
fi

# --- 2. Ask ------------------------------------------------------------------

# One request. Prints the final status after redirects, or 000 when there was
# no HTTP answer at all, in which case $TMP/err says why.
request() {
  curl -sS -o /dev/null -w '%{http_code}' -L --max-redirs 10 \
    --connect-timeout 10 --max-time 30 \
    -H 'Accept: text/html,application/xhtml+xml,*/*;q=0.8' -H 'Accept-Language: en' \
    "$@" 2>"$TMP/err"
}

alive() { [[ "$1" =~ ^[23] ]]; }

# HEAD first: it is the polite one, no body. Then GET, because plenty of servers
# answer HEAD with 403, 404 or 405 for a page they serve happily. Then GET as
# plain curl, for the sites that object to the disguise rather than to curl.
# Then all of that once more after a pause, because one failure in a hundred
# requests is usually the network and not the link. The pause is longer after a
# 429, which is a server asking for exactly that.
#
# The status reported is the browser-like GET's: it is the one a reader's
# browser is most likely to see.
status_of() {
  local code plain attempt
  for attempt in 1 2; do
    code="$(request -A "$UA" -I "$1")"
    alive "$code" || code="$(request -A "$UA" "$1")"
    alive "$code" && break
    plain="$(request "$1")"
    alive "$plain" && code="$plain" && break
    if [ "$attempt" = 1 ]; then
      if [ "$code" = 429 ]; then sleep 30; else sleep 10; fi
    fi
  done
  echo "$code"
}

blocks_automation() {
  local host h
  host="$(host_of "$1")"
  for h in "${BLOCKS_AUTOMATION[@]}"; do
    case "$host" in "$h" | *."$h") return 0 ;; esac
  done
  return 1
}

# "code  url", then every place it is linked from. Those are what you edit.
report() {
  local url="$1" code="$2" why="${3:-}"
  printf '  %s  %s%s\n' "$code" "$url" "${why:+  ($why)}"
  awk -F'\t' -v u="$url" '$1 == u { print "         " $2 }' "$TMP/links" | sort -u -t: -k1,1 -k2,2n
}

OWN_BLOB="https://github.com/jim-wyatt/two-computers-one-board/blob/main/"
echo "checking $total external links..."
# Two counts, not one. `ok` is every link found good. `answered` is only the
# ones a server said so about, and it is the one that can tell an outage from
# a bad month - see the end of this file for what happened while they were the
# same number.
ok=0
answered=0
asked_network=0
: >"$TMP/dead"
: >"$TMP/unverifiable"
# When each host was last asked, in seconds since this script started. The
# round-robin above spreads a host's links out; this is the floor under it, for
# the tail of the list where only one or two hosts are left.
declare -A asked=()
PACE=3
while IFS= read -r url; do
  host="$(host_of "$url")"
  if [ -n "${asked[$host]:-}" ]; then
    since=$((SECONDS - asked[$host]))
    [ "$since" -lt "$PACE" ] && sleep $((PACE - since))
  fi
  # A link to a file in this repository is checked against this checkout, not
  # by asking GitHub. It is quicker, it works offline, and it is the right
  # question: a link to a file this branch has just renamed is dead the moment
  # the branch merges, however cheerfully main still answers 200 today. It also
  # takes twenty-odd requests off the one host that throttles a burst, which is
  # how eight perfectly good links came back 503 in one run.
  if [[ "$url" == "$OWN_BLOB"* ]]; then
    path="${url#"$OWN_BLOB"}"
    path="${path%%[?#]*}"
    if [ -e "$PROJECT/$path" ]; then
      ok=$((ok + 1))
    else
      report "$url" "---" "no such file in this checkout: $path" >>"$TMP/dead"
    fi
    continue
  fi
  code="$(status_of "$url")"
  asked[$host]=$SECONDS
  asked_network=$((asked_network + 1))
  # Any HTTP status is a server answering, a 404 as much as a 200. Only 000 -
  # curl got nothing back at all - is silence. Counting just the good answers
  # here meant a run where every link was a real 404 was reported as "no
  # network" and its dead links never listed.
  [ "$code" = 000 ] || answered=$((answered + 1))
  if alive "$code"; then
    ok=$((ok + 1))
  elif [ "$code" = 403 ] && blocks_automation "$url"; then
    report "$url" "$code" >>"$TMP/unverifiable"
  elif [ "$code" = 429 ]; then
    # "Too many requests" is the server saying it is there. Whether the page is
    # cannot be told from here; it is not evidence of a dead link.
    report "$url" "$code" "rate limited" >>"$TMP/unverifiable"
  elif [[ "$code" =~ ^5 ]]; then
    # The server is there and having a bad moment. That is its problem, not
    # evidence that the page has gone.
    report "$url" "$code" "server error" >>"$TMP/unverifiable"
  elif [ "$code" = 000 ]; then
    report "$url" "---" "$(sed -n '1s/^curl: ([0-9]*) //p' "$TMP/err")" >>"$TMP/dead"
  else
    report "$url" "$code" >>"$TMP/dead"
  fi
done <"$TMP/urls"

# --- 3. Say ------------------------------------------------------------------

dead="$(grep -c '^  [^ ]' "$TMP/dead")"
unverifiable="$(grep -c '^  [^ ]' "$TMP/unverifiable")"

# Nothing answered at all. That is this machine having no network, not a
# hundred sites dying in the same month - and reporting it as the second would
# have the scheduled job file an issue listing every link in the docs.
#
# Asked of `answered`, not of `ok`. When the links into this repository started
# being checked against the checkout they were counted as ok too, and they are
# ok with the cable pulled out - so `ok` was never 0 again, this never fired,
# and an offline run did exactly what the paragraph above says it must not. A
# file being on this disk says nothing about whether the network is there.
if [ "$asked_network" -gt 0 ] && [ "$answered" -eq 0 ]; then
  echo "none of the $asked_network links that needed the network answered - no network? Nothing can be concluded." >&2
  exit 2
fi

if [ "$dead" -gt 0 ]; then
  echo
  echo "DEAD ($dead) - no answer, or not 2xx/3xx, twice:"
  cat "$TMP/dead"
fi
if [ "$unverifiable" -gt 0 ]; then
  echo
  echo "UNVERIFIABLE ($unverifiable) - could not be checked from here; open these in a browser:"
  cat "$TMP/unverifiable"
fi
echo
echo "$total links: $ok ok, $unverifiable unverifiable, $dead dead"
[ "$dead" -eq 0 ]
