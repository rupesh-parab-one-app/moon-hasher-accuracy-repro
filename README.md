# Two moon reproductions

This repository reproduces two independent defects, each with its own script.
Both exit 0 while the defect is present.

| Script | Defect |
|---|---|
| `./repro.sh` | `hasher.optimization: accuracy` records declared ranges instead of lockfile-resolved digests, so a lockfile change inside the range yields a cache hit |
| `./repro-version-constraint.sh` | moon 2.5.0 and 2.5.1 cannot parse the comma-separated `versionConstraint` `>=2.4.6, <3` that moon 2.4.6 accepts |

---

# 1. `hasher.optimization: accuracy` records ranges, not resolved versions

The documentation for [`hasher.optimization`](https://moonrepo.dev/docs/config/workspace#optimization) states:

> `accuracy` (default) — When hashing dependency versions, utilize the resolved
> value in the lockfile. This requires parsing the lockfile, which may reduce
> performance.

moon does this only for a dependency declared as an **exact version**. For a
dependency declared as a **range**, moon records the range string itself. A
lockfile change that stays inside the declared range therefore does not change
the task hash, and moon serves a cached artifact that was built against
different resolved dependencies.

## Run it

```bash
./repro.sh
```

On first run the script installs moon 2.5.1 into `tools/moon-cli/` and runs
`moon setup` to fetch the pinned node and pnpm toolchains, which takes about
half a minute. Later runs reuse both. **Exit 0 means the defect is still
present.** If you are testing a fix, you want this script to fail.

## Expected output

```
Versions under test
  moon:             moon 2.5.1
  javascript plugin: javascript_toolchain-v1.2.2

Precondition: the javascript dependencies block is emitted
  PASS block present, fp-ts recorded as: ~2.16.9

1. The defect: lockfile moves inside the declared range, hash does not
  declaration held at ~2.16.9; lockfile resolved 2.16.9 -> 2.16.11
  lockfile 2.16.9  -> hash ff35dcba  recorded: ~2.16.9
  lockfile 2.16.11 -> hash ff35dcba  recorded: ~2.16.9
  PASS recorded the declared range, not a digest
  PASS task hash unchanged across the lockfile change
  PASS moon served a CACHE HIT against the new lockfile

2. Lockfile parsing works: same lockfile, exact declaration, digest appears
  exact 2.16.9 + lockfile 2.16.9 -> recorded: sha512-+I2+FnVB...
  PASS digest recorded, and it equals the lockfile's own integrity

3. The catalog: path, which is the shape real monorepos use
  "fp-ts": "catalog:" -> catalog range ~2.16.9 -> recorded: ~2.16.9
  PASS catalog indirection reaches the same defect

4. The intended behaviour exists: each exact pin records its own digest
  exact 2.16.11 + lockfile 2.16.11 -> recorded: sha512-LaI+KaX2...
  PASS digest tracks the lockfile, so the feature is present but unreachable by ranges
```

The hashes are reproducible. `node` and `pnpm` are pinned in
`.moon/toolchains.yml` and each contributes a `version` entry to the hash, so
the result is deterministic rather than environment-dependent. It was confirmed
identical against a clean `MOON_HOME` that had to download every toolchain
plugin from scratch.

**The claim to check is that the two lines above print the same hash as each
other, not that either equals `ff35dcba`.** That equality across a lockfile
change is the defect itself. The absolute value depends on the task's declared
inputs, which the hash manifest lists as `.moon/toolchains.yml`,
`.moon/workspace.yml` and `packages/app/src/index.js`. Editing any of them —
including widening the `versionConstraint`, since the workspace config is
itself an input — moves the printed value. So `ff35dcba` is what this revision
produces, not a constant to hold future revisions to.

## What each measurement rules out

Case 1 alone invites three rebuttals. The other three close them:

- *"Your lockfile did not really change."* Case 4 shows the two lockfiles
  produce different digests when the declaration is exact, so they genuinely
  differ. The script also prints the resolved version from each.
- *"`accuracy` silently fell back to `performance`, so no lockfile was read."*
  Case 2 uses the **same lockfile** as case 1 and changes only the declaration
  shape. The digest appears. The lockfile is being parsed.
- *"Nobody declares dependencies that way."* Case 3 routes the same range
  through pnpm's `catalog:` protocol, which is how a large monorepo centralises
  versions. It reaches the identical defect, and in fact yields the identical
  hash, because both paths record the same string.

Case 2 and case 4 deliberately do **not** assert that the hash changed. Their
`package.json` differs between runs, so the hash would move for that reason
alone; asserting it would prove nothing. They assert the recorded *value*
instead, and check it against the integrity field in the lockfile.

## Suspected cause

In `crates/task-hasher/src/task_hashing.rs` at tag `v2.5.0`,
`apply_toolchain_dependencies_by_scope` (lines 392–457) matches a manifest
dependency against lockfile entries at line 421:

```rust
.find(|ld| ld.version.as_ref().is_some_and(|v| req == v))
```

`req` is an `UnresolvedVersionSpec` and `v` is a resolved `VersionSpec`. That
resolves to `impl PartialEq<VersionSpec> for UnresolvedVersionSpec` in
`version_spec`, which returns `true` only for the `Version`/`Version`,
`Alias`/`Alias` and `Canary` arms, and `false` for a requirement against a
version. A range can therefore never match, and execution falls through to
line 447, which records `req.to_string()` — the declared range.

The second matcher at line 426 cannot compensate, because it tests
`ld.req`, and none of the JavaScript lockfile parsers in `moonrepo/plugins`
(`npm.rs`, `pnpm.rs`, `yarn.rs`, `bun.rs`, `deno.rs`) populate that field.

A semver *satisfies* check is needed where the equality currently sits.

## Layout

```
.moon/workspace.yml           versionConstraint pinned to ^2.5.0
.moon/toolchains.yml          javascript plugin pinned by release URL
pnpm-workspace.yaml           workspace globs + the catalog: entry for case 3
packages/app/                 one project, one no-op task with cacheable output
fixtures/package.*.json       the four declaration variants
fixtures/pnpm-lock.*.yaml     the two lockfiles, by resolved version
repro.sh                      swaps fixtures in, runs moon, asserts
```

No project dependency is ever installed and no npm registry request is made for
`fp-ts`. moon's hasher reads `package.json` and `pnpm-lock.yaml` as text, so the
committed lockfiles are enough, and the reproduction cannot drift when a new
`fp-ts` patch is published. The only downloads are moon itself, its JavaScript
toolchain plugin, and the pinned node and pnpm that `moon setup` installs.

### Two details worth knowing before you call the fixtures invalid

**The lockfiles were generated from exact pins.** `~2.16.9` resolves to the
newest match, so `pnpm install --lockfile-only` against the tilde declaration
only ever produces 2.16.11. The 2.16.9 lockfile had to come from an exact
`2.16.9` pin.

**`repro.sh` rewrites the importer `specifier` field** to match whichever
declaration it is testing, so a fixture pair is never self-contradictory. Only
`version:` and the integrity differ between the two lockfiles. moon reads only
`version`, `hash` and `meta` from a lock entry, so this cannot affect the
measurement — it only removes a misleading artifact of how the files were made.

## Testing a fix

`.moon/workspace.yml` pins `versionConstraint: "^2.5.0"` so a reader cannot
accidentally attribute a result to a moon outside the line this was measured
against. To run against a patched moon, widen or delete that field and set
`MOON_BIN` to your build:

```bash
MOON_BIN=/path/to/your/moon ./repro.sh
```

Editing that field moves the printed task hash, because `.moon/workspace.yml`
is one of the task's three declared inputs. The two hashes in measurement 1
must still equal each other; only their absolute value shifts.

Note that the 2.5 line rejects every multi-comparator constraint, including
`">=2.5.0, <2.6"` and `">=2.5.0 <2.6"`. moon 2.4.6 accepted the comma form but
rejected the space form. Use a single comparator.

`repro.sh` refuses to start if `packages/app/package.json` or `pnpm-lock.yaml`
has uncommitted changes, and restores both on exit, so repeated runs are
idempotent.

---

# 2. The 2.5 line rejects the comma form `>=2.4.6, <3` that 2.4.6 accepts

```bash
./repro-version-constraint.sh
```

This one was found while building the reproduction above, and is unrelated to
hashing. moon 2.5.0 and 2.5.1 fail to parse a comma-separated multi-comparator
`versionConstraint` that 2.4.6 reads without complaint:

```
constraint         moon 2.4.6 moon 2.5.1
>=2.4.6, <3        PARSES     REJECTED
>=2.4.6 <3         REJECTED   REJECTED
^2.4.6             PARSES     PARSES
=2.5.0             PARSES     PARSES
```

**The two multi-comparator rows are different strings and they behave
differently.** `>=2.4.6, <3` is the comma form and it is the regression: 2.4.6
accepts it, 2.5.0 and 2.5.1 reject it. `>=2.4.6 <3` is the space form and every
release listed rejects it, so it is not a regression. It is probed to show that
the 2.5 failure is not a mere separator preference that switching to spaces
would work around.

The three outcomes mean distinct things:

- `PARSES` — moon read the field. It does not mean the running binary satisfies
  the constraint. `=2.5.0` parses under both binaries above even though neither
  is 2.5.0; moon then reports `app::invalid_version`, a constraint mismatch
  rather than a parse failure.
- `REJECTED` — moon named `versionConstraint:` as the offending field and
  refused to load the config before running any task.
- `ERROR(rc=N)` — moon did not run. The cell is evidence of nothing, and the
  script fails rather than counting it as acceptance.

The wording differs by release, which is why the probe classifies on the field
moon blames rather than on one release's phrasing. moon 2.4.6 rejects the space
form with `versionConstraint: expected comma after patch version number, found
'<'`. The 2.5 line rejects both multi-comparator forms with
`versionConstraint: Failed to parse a version requirement`.

The combination that bites is specific: a repository pinning `">=2.4.6, <3"` is
declaring that 2.5.1 is acceptable, so an upgrade selects it, and moon 2.5.1
then cannot read the very constraint that admitted it. The string is valid
semver and the previous release parsed it.

The script installs both 2.4.6 and 2.5.1 into `tools/`, builds a throwaway
workspace in a temp directory, and probes each constraint under both binaries,
so the contrast is measured rather than asserted. It leaves nothing behind.
moon 2.5.0 was probed the same way and matches the 2.5.1 column in every row.

Workaround: use a single comparator, for example `^2.4.6`.
