# Testing guide

This guide documents how `erli18n` is tested and what a change is expected to
bring with it. It is the companion to [`CONTRIBUTING.md`](../CONTRIBUTING.md)
(setup + the contribution flow) and [`docs/WORKFLOW.md`](WORKFLOW.md) (the
branch/release playbook). The single source of truth for "what must pass" is the
quality gate, [`bin/quality-gate.sh`](../bin/quality-gate.sh) — everything below
is wired into it.

The repository is a rebar3 **umbrella** with two apps: the runtime library
`apps/erli18n/` and the rebar3 plugin `apps/rebar3_erli18n/`. Each has its own
`test/` directory. Run tests from the repo root unless noted.

## The test harness at a glance

`erli18n` is verified by six complementary techniques, not by unit tests alone:

| Technique | What it proves | Where |
|---|---|---|
| Common Test (`*_SUITE`) | Concrete behavior, integration, OTP wiring | `apps/*/test/*_SUITE.erl` |
| Adequacy suites (`*_adequacy_SUITE`) | Equivalence classes, boundaries, hostile/malformed inputs | `apps/*/test/*_adequacy_SUITE.erl` |
| Property-based (`*_props`, PropEr) | Algebraic laws over generated input (roundtrip, totality, idempotence) | `apps/erli18n/test/*_props.erl`, driven by `erli18n_property_SUITE` |
| Fuzzing (`*_fuzz`, PropEr) | The `.po` parser survives adversarial bytes | `apps/erli18n/test/erli18n_po_fuzz.erl`, driven by `erli18n_fuzz_SUITE` |
| Parity oracle | Output is byte-for-byte identical to GNU gettext | `erli18n_parity_SUITE` + `parity_matrix.eterm` |
| Gradual typing (eqWAlizer) | Static type soundness via `elp eqwalize-all` | whole `src/` tree |

Coverage is collected on top of these but is treated as **one signal, not
proof** — see [Coverage policy](#coverage-policy).

## Suite naming conventions

Naming is load-bearing; the gate, `hank` ignores, and the property driver all
key off these suffixes. Follow them for any new test file:

- **`*_SUITE.erl`** — a Common Test suite (the standard unit/integration tests).
  A `*_SUITE_data/` sibling directory holds that suite's fixtures (`.po` files,
  consumer modules, etc.), reachable in a test via `?config(data_dir, Config)`.
- **`*_adequacy_SUITE.erl`** — a behavioral/black-box suite that pins a unit's
  *real* contract across equivalence classes, tier/boundary values, and
  malformed or untrusted inputs (weird UTF-8, truncation, bad query params). New
  public behavior should land an adequacy suite, not just a happy-path case.
- **`*_props.erl`** — a PropEr property module. It is **not** a CT suite: it
  exports `prop_*/0` properties (and any generators) and is executed by the
  central driver `erli18n_property_SUITE`, which calls `proper:quickcheck/2` per
  property at a fixed floor of **200** runs.
- **`*_fuzz.erl`** — PropEr fuzz scenarios (generators + properties), executed by
  `erli18n_fuzz_SUITE` at a floor of **500** runs.
- **`*_red_SUITE.erl`** — a regression ("red") suite that *pins a specific bug*.
  It must **fail on the unfixed code and pass after the fix** (e.g.
  `erli18n_interp_utf8_red_SUITE`, `erli18n_po_escape_total_red_SUITE`). This is
  the executable form of the project's "a regression test that fails on old
  code" acceptance rule.
- **`erli18n_parity_SUITE.erl`** — the GNU gettext parity oracle (see below).
- **`*_coverage_SUITE.erl`** — a suite whose cases exist to exercise a specific
  hard-to-reach-but-real branch (e.g. `erli18n_server_coverage_SUITE`).

## Running tests

```sh
# Everything + coverage (what `--full` and CI run):
rebar3 do ct --cover, cover

# One suite (fast iteration):
rebar3 ct --suite apps/erli18n/test/erli18n_po_SUITE

# One test case:
rebar3 ct --suite apps/erli18n/test/erli18n_po_SUITE --case single_entry_singular

# One group (for suites that define groups/0):
rebar3 ct --suite apps/erli18n/test/<some>_SUITE --group <group_name>
```

CT logs (including any PropEr counterexample) land in `_build/test/logs/` — open
the generated `index.html` to inspect a failure. The PropEr and fuzz deps live
in the `test` profile, so CT compiles them automatically; no extra setup.

## Property-based tests (PropEr)

A property states a law that must hold for *all* generated inputs, e.g.
`parse(dump(X)) == X` (roundtrip), `format(_, _)` always returns a binary
(totality), or `canonicalize(canonicalize(X)) == canonicalize(X)`
(idempotence). The properties live in `*_props.erl` and the driver
`erli18n_property_SUITE` runs each as a CT case at `numtests = 200` (the
release-blocking floor; nightly runs may raise it).

**Authoring a property.** Add a `prop_*/0` function in the relevant `*_props.erl`
(or a new one), then register it as a case in `erli18n_property_SUITE` (add to
`all/0`, export it, and have the case call `run_property(<mod>:<prop>())`). Keep
properties total and deterministic.

**eqWAlizer at generator boundaries.** PropEr's `?FORALL`/`?LET` values are
statically typed as `term()` (their payload is opaque), so a function that binds
a generated value to a concrete shape (a `pos_integer()`, an AST, a `binary()`)
must carry a static annotation:

```erlang
-eqwalizer({nowarn_function, prop_index_in_range/0}).
```

This is the project's zero-runtime-dependency pattern (the same one used in the
runtime modules `erli18n_server` and `erli18n_pt_store`); it replaced an earlier
runtime cast helper. Annotate **only** the true generator boundary — never use
it to paper over a real type error in production code.

**Reproducing a counterexample.** When a property fails, PropEr prints the
minimized counterexample to the CT log (`{to_file, user}`). To replay or dig in,
drive the property directly from a shell:

```sh
rebar3 as test shell
```
```erlang
%% Re-run a single property with more tests to stabilize a flaky failure:
proper:quickcheck(erli18n_po_props:prop_roundtrip_parse_dump(), [{numtests, 5000}]).

%% Replay an exact counterexample copied from the CT log:
proper:check(erli18n_po_props:prop_roundtrip_parse_dump(), CounterExample).
```

> On-disk counterexample persistence (`apps/erli18n/test/proper_counterexamples/`)
> is a reserved, currently-empty corpus directory; PropEr 1.5 leaves that file
> lifecycle to the consumer, so today counterexamples surface in the CT log
> rather than as committed files.

## Fuzzing the `.po` parser

`erli18n_po_fuzz.erl` (driven by `erli18n_fuzz_SUITE`, 500 runs) throws random
bytes, mutated/truncated catalogs, embedded control characters, encoding
mismatches, and extreme inputs at `erli18n_po:parse/1` and end-to-end at
`ensure_loaded`. The invariant: the parser is **total** — it returns a result or
a structured `{error, _}`, and never crashes the catalog server. Add a scenario
here when you touch the parser or its decoder.

## The gettext parity oracle

`erli18n_parity_SUITE` proves erli18n's runtime output is **byte-for-byte
identical** to GNU gettext for every scenario in
`apps/erli18n/test/parity_matrix.eterm` (the committed scenario list). The oracle
— the expected gettext bytes — is pre-computed out of band by
[`bin/extract-gettext-table.sh`](../bin/extract-gettext-table.sh) running the
real `msgfmt`/`gettext`/`ngettext` CLI, and written to an artifact the suite
reads via `$ERLI18N_PARITY_ORACLE`.

**Skip/fail policy** (the one behavioral subtlety):

- `ERLI18N_PARITY_ORACLE` **unset** → the suite **skips cleanly**. A plain
  `rebar3 ct` (and the gate's own `ct --cover` pass) never sets it, so those runs
  stay green without a gettext toolchain.
- `ERLI18N_PARITY_ORACLE` **set** → the **gate context**, no skip: a missing or
  malformed oracle, a missing/empty matrix, or *any* byte divergence is a hard
  FAIL naming the scenario and the expected-vs-got bytes.

Run it locally (needs GNU gettext + UTF-8 locales, or Docker):

```sh
make parity          # extract the oracle with GNU gettext, then run the suite
# or, in two steps:
make extract         # build the oracle into .gate/artifacts (or via docker compose)
ERLI18N_PARITY_ORACLE=.gate/artifacts/parity_oracle.eterm \
    rebar3 ct --suite apps/erli18n/test/erli18n_parity_SUITE
```

## eqWAlizer (gradual typing)

eqWAlizer is **not** a rebar3 plugin; it runs through the `elp` CLI (the Erlang
Language Platform). The gate invokes `elp eqwalize-all` (type check) and
`elp lint` (IDE-equivalent diagnostics).

```sh
elp eqwalize-all     # must print NO ERRORS
elp lint --include-erlc-diagnostics
```

`elp` is a **hard requirement for `--full`**: the gate records a real FAIL — not
a skip — when it is missing, so a type error can never slip through as a green
build. Install it per the
[eqWAlizer getting-started guide](https://whatsapp.github.io/eqwalizer/getting-started/).
The build-time toolchain anchor `eqwalizer_support` is declared as a `test`
profile dep in the root `rebar.config`.

## Coverage policy

The project holds **100% behavioral coverage**, with one firm rule: never add
dead defensive code (an unreachable clause, a can't-happen guard) just to color
a line. Instead, **craft an input that exercises the real branch**; if a branch
is genuinely unreachable, **delete it**. Coverage is a hint that points at
untested behavior — it is not a substitute for the adequacy/property/parity
checks above. `rebar3 do ct --cover, cover` writes the HTML report under
`_build/test/cover/`.

## What a change should bring

Use this as a checklist when deciding which tests your change needs:

- **Bug fix** → a `*_red_SUITE` (or a case) that **fails on the old code** and
  passes after the fix, plus an update to the relevant adequacy/unit suite.
- **New or changed public function** → unit cases in the module's `*_SUITE`,
  adequacy cases (equivalence + boundary + at least one malformed/hostile
  input), a property in `*_props.erl` if it has a law (roundtrip / totality /
  idempotence), and a `parity_matrix.eterm` entry if it mirrors a gettext
  behavior.
- **`.po` parser/serializer change** → a fuzz scenario and a parity check.
- **Type-surface change** → keep `elp eqwalize-all` clean; add an
  `-eqwalizer({nowarn_function, F/A})` annotation **only** at a PropEr generator
  boundary, never over production code.
- **Plugin (`rebar3_erli18n`) change** → the matching suite under
  `apps/rebar3_erli18n/test/` (`extract`, `roundtrip`, `providers`, `keywords`,
  `jaro`, `po_meta`, `common`, or the adequacy suite), plus the demo
  catalog-freshness gate (`rebar3 erli18n check`, run by the gate from
  `examples/erli18n_demo`).

## Running the gate

The gate is the contract CI enforces; run it before opening a PR.

```sh
bin/quality-gate.sh --fast    # ~30s: compile, xref, fmt --check, lint, hank,
                              #       elp lint, actionlint, catalog freshness
bin/quality-gate.sh --full    # ~5min: + require_elp, dialyzer, eqwalize-all,
                              #        ct + cover, gettext parity, strict actionlint
```

`make hooks-install` wires `--fast` as the pre-commit hook and the Dockerized
**OTP 27/28/29** matrix as the pre-push hook. CI (`.github/workflows/ci.yml`)
runs the full gate across **OTP 27, 28, and 29** with ELP on every push to
`main` and on every pull request targeting `main`; fork PRs are gated by the
repository's outside-collaborator-approval setting. `make otp-matrix` reproduces
that matrix locally in Docker.
