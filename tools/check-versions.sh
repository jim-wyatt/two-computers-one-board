#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Audit every toolchain dependency against what is currently released.
#
#   ~/two-computers-one-board/tools/check-versions.sh         # everything
#   ~/two-computers-one-board/tools/check-versions.sh pins    # only the project's own pins
#
# Extension auto-update is deliberately OFF on this board (it caused background
# churn on 3.6 GiB of RAM), so nothing here updates itself. Run this now and
# then. It only reports - it changes nothing.
#
# THINGS THAT LOOK OUT OF DATE BUT ARE NOT
# ----------------------------------------
#   pydantic-core   - pydantic pins it to one exact version. Never bump it
#                     alone; tools/update-constraints.sh --upgrade moves both.
#   Zephyr's venv   - Zephyr pins its own tool versions per release; `pip list
#                     --outdated` flags them, but they are deliberate, and
#                     mcu/requirements-zephyr-lock.txt holds the workspace
#                     to exactly what Zephyr asks for.
#   OpenOCD         - we build master on purpose: the newest *release* (0.12.0,
#                     2023) predates libgpiod v2, which this board needs.
#   arm64 extensions- the Marketplace "latest" is often x64-only. If a version
#                     bump reports "not found", that build has no linux-arm64
#                     package and you already have the newest usable one.
#   mkdocs          - held below 2.0 on purpose (python/pyproject.toml says why),
#                     so "latest is outside the range" there is not a to-do.
#
# THE PROJECT'S OWN PINS
# ----------------------
# Everything above the last section asks "is what is INSTALLED current?", which
# only means something on the board. The last section asks a different
# question: "is what this repository PINS current?" - the versions written into
# install-dev-tools.sh, pyproject.toml, west.yml, 25-zephyr-sdk.sh and the
# workflows. Those drift silently, and nothing here is installed from them, so
# `pins` runs that section alone and works on any machine with git and curl.
#
# It reports and never gates: "<-- behind" is information, and the exit status
# is 0 whatever it finds. A pin is bumped deliberately, with the board and CI
# moving together - an upstream release must not turn into a red tick.
#
# Set GH_TOKEN or GITHUB_TOKEN if you have one: the unauthenticated GitHub API
# allows 60 requests an hour. It is optional, and the pins section does not use
# the API at all.
set -uo pipefail

ONLY=""
case "${1:-}" in
  "") ;;
  pins) ONLY=pins ;;
  -h | --help)
    sed -n '4,7p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

# Derived from this file's location, like every other script here. It used to
# name $HOME/hybrid literally in two places, which only ever worked because a
# ~/hybrid symlink happened to exist on the board it was written on - the exact
# bug recorded as finding 6 in docs/reference/clean-board-findings.md, fixed in
# env.sh at the time and missed here.
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

# Sent only when there is a token to send. Without one the API still answers,
# 60 times an hour per address.
GH_AUTH=()
GH_API_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$GH_API_TOKEN" ] && GH_AUTH=(-H "Authorization: Bearer $GH_API_TOKEN")

gh_latest() { curl -sL --max-time 20 "${GH_AUTH[@]}" "https://api.github.com/repos/$1/releases/latest" 2>/dev/null |
  python3 -c "import json,sys;print(json.load(sys.stdin).get('tag_name','?'))" 2>/dev/null; }

# --- The project's own pins --------------------------------------------------
#
# Every pin is READ OUT OF the file that sets it. A second copy of the version
# numbers in here would be one more thing to drift, which is the problem this
# section exists to report.
#
# GitHub is asked with `git ls-remote`, not the REST API. It is not counted
# against the 60-an-hour limit, it needs no token, and it answers the question
# `uses:` actually asks - "does this ref exist" - which the releases API does
# not. "Latest" is therefore the highest version-shaped TAG. For these projects
# that is the newest release; pre-releases (-rc1 and friends) do not match.
#
# Every lookup has a timeout and may fail. The board often has no uplink, so a
# lookup that fails prints "(could not check)" and the next one runs.

# Sets REFS to "sha<TAB>ref" for every branch and tag of a GitHub repository,
# and fails, leaving it empty, when the repository could not be asked.
# GIT_TERMINAL_PROMPT=0 because git asks for a password when a repository does
# not exist, and would sit there.
#
# One TIMEOUT stops the asking. git has no connect timeout of its own, and a
# network that swallows packets rather than refusing them - a captive portal, a
# half-up link - would otherwise cost the full wait once per pin: minutes of
# nothing, to print a column of "(could not check)". A quick failure (no route,
# no DNS, no such repository) is not a timeout and does not trip this.
#
# It sets a variable rather than printing, so that it runs in this shell and
# the flag survives; inside $( ) it would be set in a subshell and forgotten.
GITHUB_UNREACHABLE=0
REFS=""
remote_refs() {
  REFS=""
  [ "$GITHUB_UNREACHABLE" = 1 ] && return 1
  REFS="$(GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote --heads --tags \
    "https://github.com/$1" 2>/dev/null)"
  case $? in
    0) [ -n "$REFS" ] ;;
    124)
      GITHUB_UNREACHABLE=1
      REFS=""
      return 1
      ;;
    *)
      REFS=""
      return 1
      ;;
  esac
}

# stdin: what remote_refs fetched. $1: an ERE the whole tag name must match.
# The peeled "^{}" twin of each annotated tag fails that match and drops out.
newest_tag() { sed -n 's|.*refs/tags/||p' | grep -xE "$1" | sort -V | tail -1; }
RELEASE_TAG='v?[0-9]+(\.[0-9]+)+' # v4.4.2, 1.0.1
MAJOR_TAG='v[0-9]+'               # v7 - the moving tag a workflow follows

# The N in `NAME="${NAME:-N}"`, which is how the shell scripts here spell a pin.
shell_pin() { sed -n "s/^$1=.*:-\\(v\\{0,1\\}[0-9][0-9.]*\\)}.*/\\1/p" "$2" 2>/dev/null | head -1; }

# name, pinned, latest. A leading v is not a difference: SHELLCHECK_VERSION is
# 0.11.0 and the tag is v0.11.0.
pin_row() {
  local flag=""
  [ -n "$2" ] && [ -n "$3" ] && [ "${2#v}" != "${3#v}" ] && flag="  <-- behind"
  printf '  %-16s pinned %-12s latest %s%s\n' "$1" "${2:-?}" "${3:-(could not check)}" "$flag"
}

# name, pinned, owner/repo
tag_pin() {
  local latest=""
  remote_refs "$3" && latest="$(newest_tag "$RELEASE_TAG" <<<"$REFS")"
  pin_row "$1" "$2" "$latest"
}

# name, PEP 440 specifier as pyproject.toml has it ("==22.1.8", ">=1.6,<2").
# Prints the newest release on PyPI and the newest one the specifier allows,
# because for a range those are different questions: mkdocs 2.x existing is not
# news, a new 1.x is. Only the comparison operators this project uses are
# understood; anything else comes back empty and reads as "could not check".
pypi_row() {
  local name="$1" spec="$2" latest="" allowed="" note=""
  read -r latest allowed < <(curl -sL --connect-timeout 5 --max-time 20 "https://pypi.org/pypi/$name/json" 2>/dev/null |
    python3 -c '
import json, re, sys

d = json.load(sys.stdin)
key = lambda v: tuple(int(x) for x in v.split("."))
ops = {">=": lambda a, b: a >= b, "<=": lambda a, b: a <= b, "==": lambda a, b: a == b,
       ">": lambda a, b: a > b, "<": lambda a, b: a < b, "!=": lambda a, b: a != b}
spec = [re.fullmatch(r"(>=|<=|==|!=|<|>)\s*([0-9.]+)", s.strip()).groups()
        for s in sys.argv[1].split(",")]
# Final releases only, and not ones that were published and then yanked.
ok = [v for v, files in d["releases"].items()
      if re.fullmatch(r"\d+(\.\d+)*", v) and any(not f.get("yanked") for f in files)
      and all(ops[o](key(v), key(b)) for o, b in spec)]
print(d["info"]["version"], max(ok, key=key) if ok else "?")
' "$spec" 2>/dev/null)
  case "$spec" in
    "") printf '  %-16s (no pin found in python/pyproject.toml)\n' "$name" ;;
    ==*) pin_row "$name" "${spec#==}" "$latest" ;;
    *)
      [ -n "$latest" ] && [ "$latest" != "$allowed" ] && note="  (latest is outside the range)"
      printf '  %-16s range  %-12s latest %s, newest in range %s%s\n' \
        "$name" "$spec" "${latest:-(could not check)}" "${allowed:-?}" "$note"
      ;;
  esac
}

# The specifier after a package name in pyproject.toml: "mkdocs>=1.6,<2" gives
# >=1.6,<2. The quote in the pattern keeps "mkdocs" from matching
# "mkdocs-material", and keeps the prose in the comments out of it.
pyproject_pin() { grep -oE "\"$1[<>=!~][^\"]*\"" "$PROJECT/python/pyproject.toml" 2>/dev/null |
  head -1 | tr -d '"' | sed "s/^$1//"; }

# One `uses: owner/repo@ref`. Three separate answers, because for an action they
# really are separate:
#
#   does the ref resolve   what decides whether the workflow starts at all
#   newest release         v9.0.0
#   newest major tag       v7 - the newest ref of the `@v7` kind that EXISTS
#
# astral-sh/setup-uv@v9 is why. v9.0.0 was the latest release, `@v9` looked like
# an ordinary bump, and it did not resolve: that action stopped moving its
# major tags at v7. Only asking the remote for the ref itself catches that.
action_row() {
  local spec="$1" action ref owner repo state release major flag=""
  action="${spec%@*}"
  ref="${spec##*@}"
  IFS=/ read -r owner repo _ <<<"$action" # owner/repo/sub/path is still owner/repo
  if ! remote_refs "$owner/$repo"; then
    printf '  %-42s %-10s (could not check)\n' "$action" "@$ref"
    return
  fi
  release="$(newest_tag "$RELEASE_TAG" <<<"$REFS")"
  major="$(newest_tag "$MAJOR_TAG" <<<"$REFS")"
  # A tag, a branch, or a full commit id that some tag or branch points at.
  if awk -v r="$ref" '$2 == "refs/tags/" r || $2 == "refs/heads/" r || $1 == r { f = 1 } END { exit !f }' <<<"$REFS"; then
    state="resolves"
  elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    # ls-remote lists tips only, so a commit in the middle of history cannot
    # be confirmed this way. That is not the same as it being missing.
    state="commit, unchecked"
  else
    state="DOES NOT RESOLVE"
  fi
  # Compare like with like: a major pin against the major tags, anything else
  # version-shaped against the releases. A branch or a commit id has no
  # "behind" that can be read off a tag list.
  if [[ "$ref" =~ ^${MAJOR_TAG}$ ]]; then
    [ -n "$major" ] && [ "$ref" != "$major" ] && flag="  <-- behind"
  elif [[ "$ref" =~ ^${RELEASE_TAG}$ ]]; then
    [ -n "$release" ] && [ "${ref#v}" != "${release#v}" ] && flag="  <-- behind"
  elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && [ -n "$release" ]; then
    # A commit pin, which is how every workflow here pins. It is current when
    # it is the commit the newest release points at. ls-remote lists an
    # annotated tag and then its peeled "^{}" twin, so the last match is the
    # commit, whichever kind of tag it is. Without this, every pin in the
    # workflows printed "resolves" and none could ever read as behind.
    local release_sha
    release_sha="$(awk -v t="refs/tags/$release" '$2 == t || $2 == t "^{}" { s = $1 } END { print s }' <<<"$REFS")"
    [ -n "$release_sha" ] && [ "$ref" != "$release_sha" ] && flag="  <-- behind ($release is ${release_sha:0:12})"
  fi
  [ "$state" = "DOES NOT RESOLVE" ] && flag="  <-- the workflow will not start"
  printf '  %-42s %-10s %-17s latest %s, major tag %s%s\n' \
    "$action" "@$ref" "$state" "${release:-?}" "${major:-none}" "$flag"
}

pins() {
  local tools="$PROJECT/tools/install-dev-tools.sh" spec p

  echo "=== project pins: dev tools (tools/install-dev-tools.sh) ==="
  tag_pin shellcheck "$(shell_pin SHELLCHECK_VERSION "$tools")" koalaman/shellcheck
  tag_pin shfmt "$(shell_pin SHFMT_VERSION "$tools")" mvdan/sh
  tag_pin bats "$(shell_pin BATS_VERSION "$tools")" bats-core/bats-core
  tag_pin actionlint "$(shell_pin ACTIONLINT_VERSION "$tools")" rhysd/actionlint

  echo "=== project pins: python (python/pyproject.toml) ==="
  for p in clang-format mkdocs mkdocs-material; do
    pypi_row "$p" "$(pyproject_pin "$p")"
  done

  echo "=== project pins: Zephyr (west.yml, provision/user/25-zephyr-sdk.sh) ==="
  # west.yml only. 30-zephyr-workspace.sh repeats the version, and
  # check-zephyr-pin.sh already fails check.sh if the two disagree.
  tag_pin zephyr \
    "$(sed -n 's/^[[:space:]]*revision:[[:space:]]*\(v[0-9][0-9.]*\).*/\1/p' "$PROJECT/west.yml" 2>/dev/null | head -1)" \
    zephyrproject-rtos/zephyr
  tag_pin zephyr-sdk "$(shell_pin SDK_VERSION "$PROJECT/provision/user/25-zephyr-sdk.sh")" \
    zephyrproject-rtos/sdk-ng

  echo "=== project pins: GitHub Actions (.github/workflows) ==="
  # Local (./path) and docker:// actions have no repository to ask.
  while read -r spec; do
    [ -n "$spec" ] && action_row "$spec"
  done < <(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$PROJECT"/.github/workflows/*.yml 2>/dev/null |
    sed -e 's/.*uses:[[:space:]]*//' -e 's/[[:space:]]*#.*//' | tr -d "\"'" |
    grep -E '^[^./][^/]*/[^@]+@' | sort -u)
}
if [ "$ONLY" = pins ]; then
  pins
  exit 0
fi

echo "=== Zephyr ==="
printf '  installed %-12s latest %s\n' \
  "$(git -c safe.directory="$HOME/zephyrproject/zephyr" -C "$HOME/zephyrproject/zephyr" describe --tags 2>/dev/null)" \
  "$(gh_latest zephyrproject-rtos/zephyr)"

echo "=== Zephyr SDK ==="
# Glob into an array rather than parsing ls. An unmatched glob stays literal,
# so check the first element exists before using it.
sdk_dirs=("$HOME"/zephyr-sdk-*)
sdk_installed="?"
[ -d "${sdk_dirs[0]}" ] && sdk_installed=$(basename "${sdk_dirs[0]}" | sed 's/zephyr-sdk-/v/')
printf '  installed %-12s latest %s\n' \
  "$sdk_installed" \
  "$(gh_latest zephyrproject-rtos/sdk-ng)"

echo "=== host tools (uv-managed) ==="
for p in uv cmake ninja west; do
  cur=$(uv tool list 2>/dev/null | awk -v p="$p" '$1==p {print $2}' | tr -d 'v')
  [ "$p" = uv ] && cur=$(uv --version 2>/dev/null | awk '{print $2}')
  new=$(curl -sL "https://pypi.org/pypi/$p/json" 2>/dev/null |
    python3 -c "import json,sys;print(json.load(sys.stdin)['info']['version'])" 2>/dev/null)
  flag=""
  [ -n "$cur" ] && [ -n "$new" ] && [ "$cur" != "$new" ] && flag="  <-- update"
  printf '  %-8s %-14s latest %s%s\n' "$p" "${cur:-?}" "${new:-?}" "$flag"
done

echo "=== MPU python ($PROJECT/.venv) ==="
uv pip list --python "$PROJECT/.venv/bin/python" --outdated 2>/dev/null | tail -n +3 |
  sed 's/^/  /' || true
echo "  (these are held by python/requirements-lock.txt - take them with tools/update-constraints.sh --upgrade)"

echo "=== Zephyr venv conformance to its own pins ==="
(cd "$HOME/zephyrproject" && uv pip install --python .venv/bin/python \
  -r zephyr/scripts/requirements.txt --dry-run 2>&1 | tail -2 | sed 's/^/  /')

echo "=== VS Code extensions vs Marketplace ==="
code_matches=("$HOME"/.vscode-server/cli/servers/Stable-*/server/bin/remote-cli/code)
CODE="${code_matches[0]}"
[ -x "$CODE" ] || CODE=""
# code-server installs extensions without needing a live VS Code session; the
# remote-cli `code` above is only reliable for listing while one is connected.
cs_matches=("$HOME"/.vscode-server/cli/servers/Stable-*/server/bin/code-server)
CS="${cs_matches[0]}"
[ -x "$CS" ] || CS=""
[ -x "$CODE" ] && "$CODE" --list-extensions --show-versions 2>/dev/null >/tmp/exts.txt
[ -s /tmp/exts.txt ] || { [ -x "$CS" ] && "$CS" --list-extensions --show-versions 2>/dev/null >/tmp/exts.txt; }
python3 - <<'PY'
import json, urllib.request

# This board is linux-arm64. The Marketplace returns one entry per target
# platform, newest first, and publishers routinely ship a version for x64 and
# Windows days before the arm64 build - so versions[0] is usually NOT something
# this board can install. Reporting it produced two failure modes: an
# `--install-extension` that says "not found", and (worse) a real arm64 update
# hidden behind that noise. Take the newest build that actually runs here:
# an explicit linux-arm64 target, or a universal package with no target at all.
PLATFORM = "linux-arm64"

try:
    cur = dict(l.rsplit("@",1) for l in open("/tmp/exts.txt").read().split() if "@" in l)
except Exception:
    print("  (could not read extension list)"); raise SystemExit
url="https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
body={"filters":[{"criteria":[{"filterType":7,"value":k} for k in cur]}],"flags":950}
req=urllib.request.Request(url, json.dumps(body).encode(),
    {"Content-Type":"application/json","Accept":"application/json;api-version=7.1-preview.1"})

def installable(ext):
    """Newest version with a build for this platform, and the newest overall."""
    here = next((v["version"] for v in ext["versions"]
                 if v.get("targetPlatform", PLATFORM) in (PLATFORM, "universal")), "?")
    return here, ext["versions"][0]["version"]

try:
    d=json.load(urllib.request.urlopen(req, timeout=60))
    latest={e["publisher"]["publisherName"]+"."+e["extensionName"]: installable(e)
            for e in d["results"][0]["extensions"]}
    for k,v in sorted(cur.items()):
        L,newest = latest.get(k,("?","?"))
        note = "  <-- try update" if L not in (v,"?") else ""
        # Flag the trap explicitly rather than letting it read as "outdated".
        if newest not in (L,"?") and not note:
            note = f"  (current for {PLATFORM}; {newest} is other-platform only)"
        print(f"  {k:42} {v:14} -> {L}{note}")
except Exception as e:
    print("  marketplace query failed:", e)
PY

echo "=== OpenOCD ==="
printf '  installed  %s\n' "$(/opt/openocd/bin/openocd --version 2>&1 | head -1 | cut -d' ' -f1-4)"
printf '  pinned in build-openocd.sh: %s\n' "$(grep -oP 'OPENOCD_COMMIT:-\K[0-9a-f]+' "$PROJECT/tools/build-openocd.sh" 2>/dev/null)"
printf '  upstream master head:       %s\n' \
  "$(curl -sL --max-time 20 "${GH_AUTH[@]}" https://api.github.com/repos/openocd-org/openocd/commits/master 2>/dev/null |
    python3 -c "import json,sys;d=json.load(sys.stdin);print(d['sha'][:12], d['commit']['committer']['date'][:10])" 2>/dev/null)"

pins

echo
echo "Update extensions with:"
echo "  ${CS:-<vscode-server>/bin/code-server} --install-extension <id>@<version> --force"
echo "(plain --force does NOT bump the version; versions above are arm64-installable)"
