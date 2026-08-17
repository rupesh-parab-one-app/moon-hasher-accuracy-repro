#!/usr/bin/env bash
#
# Reproduces a second, unrelated regression found while building the hasher
# reproduction: the moon 2.5 line cannot parse the comma-separated
# `versionConstraint` ">=2.4.6, <3" that moon 2.4.6 accepts.
#
# The space-separated form ">=2.4.6 <3" is probed alongside it. Every release
# here rejects that one, so it is a control rather than a second regression:
# it rules out the reading that 2.5 merely wants a different separator.
#
# This matters because a repository pinning ">=2.4.6, <3" is asking for the
# newest 2.x and will be given it, then fails to load its own workspace config
# before any task runs.
#
# Exit 0 means the regression is still present.

set -uo pipefail

cd "$(dirname "$0")"
repo="$PWD"

NEW_PIN="2.5.1"
OLD_PIN="2.4.6"
NEW_MOON="tools/moon-cli/node_modules/.bin/moon"
OLD_MOON="tools/moon-cli-2.4.6/node_modules/.bin/moon"

failures=0
note() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }

for pair in "$NEW_MOON:tools/moon-cli:$NEW_PIN" "$OLD_MOON:tools/moon-cli-2.4.6:$OLD_PIN"; do
  bin="${pair%%:*}"; rest="${pair#*:}"; prefix="${rest%%:*}"; ver="${rest##*:}"
  if [ ! -x "$bin" ]; then
    note "Installing moon ${ver} into ${prefix}"
    npm install --prefix "$prefix" --silent --no-audit --no-fund || {
      echo "failed to install moon ${ver}" >&2
      exit 2
    }
  fi
done

# A scratch workspace outside this repository, so moon cannot walk up and find
# the hasher reproduction's own configuration instead.
scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

mkdir -p "$scratch/.moon"
printf '{"name":"vc","version":"1.0.0","private":true}\n' > "$scratch/package.json"
git -C "$scratch" init -q -b main
git -C "$scratch" -c user.email=repro@local -c user.name=repro commit -q --allow-empty -m init

# Returns PARSES or REJECTED for one constraint under one moon binary. moon must
# run with the scratch workspace as its working directory, otherwise it walks up
# and loads this repository's own config instead of the file under test.
probe() {
  local bin="$1" constraint="$2"
  printf 'versionConstraint: "%s"\nprojects:\n  - "."\n' "$constraint" > "$scratch/.moon/workspace.yml"
  local out rc
  out=$(cd "$scratch" && "$repo/$bin" projects 2>&1); rc=$?
  # Classify on moon's own error taxonomy rather than one release's wording. A
  # parse failure names the offending field; a constraint that parses but
  # excludes the running binary reports invalid_version. Anything else means
  # moon did not run, and must not be reported as acceptance.
  if grep -q "versionConstraint:" <<<"$out"; then echo "REJECTED"
  elif [ "$rc" -eq 0 ] || grep -q "invalid_version" <<<"$out"; then echo "PARSES"
  else echo "ERROR(rc=$rc)"; fi
}

note "Versions under test"
echo "  old: $($NEW_MOON --version >/dev/null 2>&1; $OLD_MOON --version 2>/dev/null)"
echo "  new: $($NEW_MOON --version 2>/dev/null)"

note "Parsing the same versionConstraint under both releases"
printf '  %-18s %-10s %-10s\n' "constraint" "moon $OLD_PIN" "moon $NEW_PIN"
declare -A old_res new_res
for c in '>=2.4.6, <3' '>=2.4.6 <3' '^2.4.6' '=2.5.0'; do
  o=$(probe "$OLD_MOON" "$c")
  n=$(probe "$NEW_MOON" "$c")
  old_res["$c"]="$o"; new_res["$c"]="$n"
  printf '  %-18s %-10s %-10s\n' "$c" "$o" "$n"
done

note "Assertions"
[ "${old_res['>=2.4.6, <3']}" = "PARSES" ] \
  && pass "moon $OLD_PIN accepts the comma form" \
  || fail "expected moon $OLD_PIN to accept '>=2.4.6, <3'"
[ "${new_res['>=2.4.6, <3']}" = "REJECTED" ] \
  && pass "moon $NEW_PIN rejects the same string it is eligible to satisfy" \
  || fail "moon $NEW_PIN accepted '>=2.4.6, <3'; the regression is fixed"
[ "${new_res['>=2.4.6 <3']}" = "REJECTED" ] \
  && pass "the space-separated form is rejected too, so this is not a separator issue" \
  || fail "expected moon $NEW_PIN to reject '>=2.4.6 <3'"
[ "${new_res['^2.4.6']}" = "PARSES" ] && [ "${new_res['=2.5.0']}" = "PARSES" ] \
  && pass "single-comparator forms still parse, so only multi-comparator ranges broke" \
  || fail "expected single-comparator forms to parse on moon $NEW_PIN"

note "Result"
if [ "$failures" -eq 0 ]; then
  echo "  A workspace pinning \">=2.4.6, <3\" resolves to moon $NEW_PIN and is then"
  echo "  unable to load its own config. The constraint is valid semver and the"
  echo "  previous release accepted it."
  exit 0
fi
echo "  $failures assertion(s) failed."
exit 1
