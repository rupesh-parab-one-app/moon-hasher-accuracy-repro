#!/usr/bin/env bash
#
# Reproduces: under hasher.optimization=accuracy, moon records a declared semver
# range instead of the lockfile-resolved integrity digest for JavaScript
# dependencies, so a lockfile change within the range does not change the task
# hash and moon serves a stale cached artifact.
#
# Exit 0 means the defect is still present. Exit 1 means it is not reproducing
# here -- which, on a moon that has fixed it, is the outcome you want.

set -uo pipefail

cd "$(dirname "$0")"

MOON_PIN="2.5.0"
LOCAL_MOON="tools/moon-cli/node_modules/.bin/moon"

FP_INTEGRITY_9="sha512-+I2+FnVB+tVaxcYyQkHUq7ZdKScaBlX53A41mxQtpIccsfyv8PzdzP7fzp2AY832T4aoK6UZ5WRX/ebGd8uZuQ=="
FP_INTEGRITY_11="sha512-LaI+KaX2NFkfn1ZGHoKCmcfv7yrZsC3b8NtWsTVQeHkq4F27vI5igUuO53sxqDEa2gNQMHFPmpojDw/1zmUK7w=="

failures=0
note() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }

# The script rewrites two tracked files. Refuse to start from a dirty tree so a
# previous interrupted run cannot be mistaken for the fixture state, and restore
# them on every exit path so "clone once, run repeatedly" stays true.
if [ -n "$(git status --porcelain -- packages/app/package.json pnpm-lock.yaml 2>/dev/null)" ]; then
  echo "refusing to run: packages/app/package.json or pnpm-lock.yaml has uncommitted changes" >&2
  echo "run: git checkout -- packages/app/package.json pnpm-lock.yaml" >&2
  exit 2
fi
restore() { git checkout -- packages/app/package.json pnpm-lock.yaml 2>/dev/null || true; }
trap restore EXIT INT TERM

if [ -z "${MOON_BIN:-}" ]; then
  if [ ! -x "$LOCAL_MOON" ]; then
    note "Installing moon ${MOON_PIN} into tools/moon-cli"
    # Installed here rather than invoked through npx: npm 11 parses moon's own
    # flags (--no-actions) as npm config and the call fails. An isolated prefix
    # also keeps @moonrepo/cli out of the workspace lockfile under measurement.
    npm install --prefix tools/moon-cli --silent --no-audit --no-fund || {
      echo "failed to install moon ${MOON_PIN}" >&2
      exit 2
    }
  fi
  MOON_BIN="$LOCAL_MOON"
fi

note "Versions under test"
echo "  moon:             $($MOON_BIN --version 2>/dev/null)"
echo "  javascript plugin: $(grep -o 'javascript_toolchain-v[0-9.]*' .moon/toolchains.yml | head -1)"

# node and pnpm are pinned so the hashes below are identical on every machine,
# which means moon has to have them installed. Every measured run passes
# --no-actions and therefore skips setup, so it is done once, here. On a machine
# that already has these versions this is a no-op; otherwise it downloads them.
note "Preparing the pinned toolchain (one-time, ~30s on a cold machine)"
if ! $MOON_BIN setup >/dev/null 2>&1; then
  echo "  moon setup failed; cannot run the measurements" >&2
  exit 2
fi
echo "  ready"

# Swap in one (declaration, lockfile) pair and return the task hash plus the
# value moon recorded for fp-ts. The lockfile's importer `specifier` is set to
# match the declaration so the pair is never self-contradictory; moon reads only
# `version`/`hash`/`meta` from a lock entry, so this cannot affect the result.
run_case() {
  local pkg="$1" lock="$2" spec="$3"
  cp "fixtures/$pkg" packages/app/package.json
  cp "fixtures/$lock" pnpm-lock.yaml
  python3 -c "
import re
p='pnpm-lock.yaml'; s=open(p).read()
open(p,'w').write(re.sub(r'specifier: .*', 'specifier: $spec', s, count=1))"
  # Drop only the last-run record, so a moon invocation that fails for an
  # unrelated reason cannot leave a previous case's hash to be read as a fresh
  # result. The output archive under .moon/cache must survive: measurement 1
  # asserts a cache hit, and purging the cache would guarantee a miss on any
  # machine that had not already run this script.
  rm -f .moon/cache/states/app/build/lastRun.json
  CASE_OUT=$($MOON_BIN run app:build --no-actions 2>&1)
  CASE_HASH=$(python3 -c "
import json
print(json.load(open('.moon/cache/states/app/build/lastRun.json'))['hash'])" 2>/dev/null)
  CASE_RECORDED=$($MOON_BIN hash "$CASE_HASH" --json 2>/dev/null | python3 -c "
import json,sys
for e in json.load(sys.stdin):
    if isinstance(e,dict) and e.get('toolchain')=='javascript':
        print(e['dependencies']['production']['fp-ts']); break
else:
    print('NO-JAVASCRIPT-BLOCK')")
}

# A hash comparison is only meaningful if the javascript toolchain contributed a
# dependencies block at all. Without a recordable non-workspace dependency moon
# emits no block, and every later assertion would compare hashes that never
# considered dependencies.
note "Precondition: the javascript dependencies block is emitted"
run_case package.range.json pnpm-lock.2.16.9.yaml "~2.16.9"
if [ "$CASE_RECORDED" = "NO-JAVASCRIPT-BLOCK" ]; then
  fail "no javascript dependencies block; every measurement below would be void"
  exit 1
fi
pass "block present, fp-ts recorded as: $CASE_RECORDED"

note "1. The defect: lockfile moves inside the declared range, hash does not"
echo "  declaration held at ~2.16.9; lockfile resolved 2.16.9 -> 2.16.11"
hash_lo="$CASE_HASH"; rec_lo="$CASE_RECORDED"
run_case package.range.json pnpm-lock.2.16.11.yaml "~2.16.9"
hash_hi="$CASE_HASH"; rec_hi="$CASE_RECORDED"
echo "  lockfile 2.16.9  -> hash ${hash_lo:0:8}  recorded: $rec_lo"
echo "  lockfile 2.16.11 -> hash ${hash_hi:0:8}  recorded: $rec_hi"
echo "  moon reported:"
sed 's/^/    /' <<<"$CASE_OUT" | grep -vE '^\s*$'

[ "$rec_lo" = "~2.16.9" ] \
  && pass "recorded the declared range, not a digest" \
  || fail "expected the literal string ~2.16.9, got: $rec_lo"
[ "$hash_lo" = "$hash_hi" ] \
  && pass "task hash unchanged across the lockfile change" \
  || fail "hash changed ($hash_lo -> $hash_hi); the defect is not reproducing"
grep -q "cached" <<<"$CASE_OUT" \
  && pass "moon served a CACHE HIT against the new lockfile" \
  || fail "expected a cache hit on the second run"

note "2. Lockfile parsing works: same lockfile, exact declaration, digest appears"
run_case package.exact-old.json pnpm-lock.2.16.9.yaml "2.16.9"
echo "  exact 2.16.9 + lockfile 2.16.9 -> recorded: $CASE_RECORDED"
[ "$CASE_RECORDED" = "$FP_INTEGRITY_9" ] \
  && pass "digest recorded, and it equals the lockfile's own integrity" \
  || fail "expected $FP_INTEGRITY_9, got: $CASE_RECORDED"

note "3. The catalog: path, which is the shape real monorepos use"
run_case package.catalog.json pnpm-lock.2.16.9.yaml "~2.16.9"
echo "  \"fp-ts\": \"catalog:\" -> catalog range ~2.16.9 -> recorded: $CASE_RECORDED"
[ "$CASE_RECORDED" = "~2.16.9" ] \
  && pass "catalog indirection reaches the same defect" \
  || fail "expected the literal string ~2.16.9, got: $CASE_RECORDED"

note "4. The intended behaviour exists: each exact pin records its own digest"
run_case package.exact-new.json pnpm-lock.2.16.11.yaml "2.16.11"
echo "  exact 2.16.11 + lockfile 2.16.11 -> recorded: $CASE_RECORDED"
[ "$CASE_RECORDED" = "$FP_INTEGRITY_11" ] \
  && pass "digest tracks the lockfile, so the feature is present but unreachable by ranges" \
  || fail "expected $FP_INTEGRITY_11, got: $CASE_RECORDED"

note "Result"
if [ "$failures" -eq 0 ]; then
  echo "  All assertions held: the defect reproduces on moon $($MOON_BIN --version 2>/dev/null | awk '{print $2}')."
  echo "  A dependency declared as a range is hashed as the range string, so a"
  echo "  lockfile change inside that range cannot invalidate the cache."
  exit 0
fi
echo "  $failures assertion(s) failed. If you are testing a fix, that is the goal;"
echo "  otherwise the environment differs from the one this was measured on."
exit 1
