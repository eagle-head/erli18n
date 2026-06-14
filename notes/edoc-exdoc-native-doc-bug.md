# `rebar3 ex_doc` crashes on a backtick in an ordinary comment (modules using native `-doc`)

> **Status of this document.** Standalone bug report + reproduction guide. It is _not_ part of the
> `erli18n` library (it lives under `notes/`, which is excluded from the Hex package whitelist).
> Written in English so it can be pasted, mostly as-is, into an upstream issue/PR on
> `jelly-beam/rebar3_ex_doc` and/or `erlang/otp`.

## TL;DR

A project documented entirely with **native OTP 27+ documentation attributes** (`-moduledoc` / `-doc`,
EEP-59) cannot build HTML docs with `rebar3 ex_doc`. The command aborts with:

```
===> Running edoc for erli18n
edoc: error in doclet 'edoc_doclet_chunks': {'EXIT',error}.
===> An unknown error occurred generating doc chunks with edoc. Run with DIAGNOSTICS=1 for more details.
```

The real, swallowed error is:

```
throw:{error, 176, {"`-quote ended unexpectedly at line ~w", "´"}}
  edoc_wiki:throw_error/2  (edoc_wiki.erl:482)
  edoc_wiki:expand_text/2  (edoc_wiki.erl:116)
  edoc_wiki:parse_xml/2    (edoc_wiki.erl:96)
```

**Root cause:** `rebar3 ex_doc` unconditionally runs **EDoc** to generate doc chunks. EDoc parses _every_
`%%` comment through its legacy "wiki" markup, in which a backtick opens inline code that must be closed
with an apostrophe (`` `code' ``). A perfectly normal comment that uses Markdown-style backticks
(`` `code` ``) — the convention everywhere in a modern, `-doc`-documented codebase — makes the EDoc wiki
parser scan for a closing `'` that never comes and throw. The throw aborts the whole `rebar3 ex_doc`
run.

**Why this is surprising / why it matters:** the EDoc step is _vestigial_. `ex_doc` reads the
documentation directly from the compiled BEAM files (the EEP-48 `Docs` chunk produced by the compiler
from the native `-doc` attributes), **not** from EDoc's chunks. EDoc here only contributes a way to
crash. See "How `rebar3 ex_doc` actually works" below.

## Environment

| Component                                   | Version                                                        |
| ------------------------------------------- | -------------------------------------------------------------- |
| Erlang/OTP                                  | 28.4.3 (ERTS 16.3.1)                                           |
| rebar3                                      | 3.24.0                                                         |
| rebar3_ex_doc                               | 0.2.31 (**also 0.3.0** — see note)                             |
| ex_doc (escript, bundled in plugin `priv/`) | `ex_doc_otp_27`                                                |
| Source documentation style                  | 100% native `-moduledoc`/`-doc`; **zero** `@doc` EDoc comments |

> **The latest `rebar3_ex_doc` (0.3.0, 2026-05-27) does not fix this.** Its `gen_chunks/2` still calls
> EDoc unconditionally (`{doclet, edoc_doclet_chunks}`), with no branch that reads the native BEAM chunk
> and no OTP-version-dependent path. "Retire support for < OTP 27" did not change the doc-generation
> mechanism.

## Background: two parallel, non-interoperating documentation systems

Erlang has two independent documentation systems that do not read each other's markup:

|             | Modern (EEP-59)                                       | Legacy (EDoc)            |
| ----------- | ----------------------------------------------------- | ------------------------ |
| You write   | `-doc "..."` / `-moduledoc "..."` attributes          | `%% @doc ...` comments   |
| Consumed by | the **compiler** → EEP-48 `Docs` chunk in the `.beam` | the **edoc** application |
| Surfaces in | `h/1` in the shell, `ex_doc` (reads the BEAM chunk)   | edoc HTML / edoc chunks  |

EDoc was extended in OTP 27 to _emit_ EEP-48 chunks and to _convert_ EDoc markup to EEP-59 Markdown
(see `erlang/otp` PR #8308, "edoc: Add doclet to convert to EEP-59 Markdown"). It was **not** taught to
_read_ native `-doc`/`-moduledoc` attributes as input. Empirically (this OTP 28.4.3): running EDoc over
a module whose only documentation is native `-doc` produces a `docs_v1` chunk with **empty doc bodies**
(`#{}`), i.e. EDoc silently drops the native documentation (`#{}` means "hidden"; cf. OTP PR #8421
"edoc: For edoc #{} means hidden").

## How `rebar3 ex_doc` actually works (and why the edoc step is vestigial)

From `rebar3_ex_doc.erl` (0.2.31 and 0.3.0). The provider does two things in sequence:

1. `gen_chunks/2` — runs EDoc to produce `doc/chunks/*.chunk`:

   ```erlang
   EdocOptsDefault = [{preprocess, true},
                      {doclet, edoc_doclet_chunks},
                      {layout, edoc_layout_chunks},
                      {dir, OutDir},
                      {includes, ["src", "include"] ++ ...}],
   ...
   case providers:do(Prv, State2) of
       {ok, State3} -> {State3, App1, OutDir};
       {error, Err} -> ?RAISE({gen_chunks, Err})   %% <-- aborts here on the EDoc crash
   end.
   ```

2. `make_command_string/4` — invokes the `ex_doc` escript:

   ```erlang
   BaseArgs = [ ex_doc_escript(Opts),
                AppName,
                Vsn,
                Ebin,                       %% <-- the compiled BEAM dir
                "--source-ref", SourceRefVer,
                "--config", ex_doc_config_file(App, EdocOutDir),
                "--quiet" ] ++ ...
   ```

`ex_doc` is given **`Ebin`** (the `_build/.../<app>/ebin` directory). The `ex_doc` escript reads the
EEP-48 `Docs` chunk straight from each `.beam`. It does **not** consume `doc/chunks/*.chunk`. Therefore:

- For native-`-doc` projects, step 1 (EDoc) contributes nothing that `ex_doc` reads.
- When step 1 happens not to crash, everything works — `ex_doc` renders the native BEAM docs and nobody
  notices EDoc produced empty chunks.
- When step 1 crashes (this bug), `?RAISE({gen_chunks, Err})` aborts the command **before** `ex_doc`
  ever runs.

## Root cause

`edoc:get_doc/2` runs `edoc_wiki:expand_text/2` over comment text. In EDoc wiki markup, `` ` `` opens an
inline-code span terminated by an apostrophe `'` (i.e. `` `code' ``). A comment that uses Markdown
backticks (`` `code` ``) opens a span that is never closed with `'`; the parser runs to the end of the
text and throws `{error, Line, {"`-quote ended unexpectedly at line ~w", ...}}`.

`edoc_doclet_chunks` then swallows the reason (`catch _:_R:_St -> ... {OkSet, true}` →
surfaces only `{'EXIT', error}`); cf. `erlang/otp` #5778 "EDoc swallows errors when running with
-chunks", open since 2022.

## Minimal reproduction (isolates the bug to EDoc itself — no plugin, no ex_doc)

`d.erl`:

```erlang
-module(d).
-export_type([t/0]).
-type s() :: atom().
%% O campo `msgid_plural` e irrelevante e dropado na materializacao.
-type t() :: {s(), s()}.
```

```console
$ erl -noshell -eval '
    try edoc:get_doc("d.erl", [{preprocess,true}]) of
       {_,_} -> io:format("returned (no throw)~n")
    catch throw:{error,L,{Fmt,Arg}}:_ -> io:format("THROW line ~p: " ++ Fmt ++ "~n",[L,Arg])
    end, halt().'
THROW line 3: `-quote ended unexpectedly at line [3]
```

Notes on the trigger condition (observed on OTP 28.4.3):

- The backtick must be in a comment that EDoc attaches to a declaration (here, the comment is attached
  to the following `-type t/0`). A comment attached to a plain function did **not** throw in our tests;
  a comment between two type declarations (second one exported) does.
- Replacing the Markdown `` `msgid_plural` `` with EDoc-style `` `msgid_plural' `` (apostrophe close)
  makes it pass — confirming the parser is treating `` ` `` as an EDoc inline-code opener.
- The plugin issue jelly-beam/rebar3_ex_doc #123 has a similar but _non-deterministic_ repro (the
  maintainer could not reproduce it). The `d.erl` form above is deterministic.

## End-to-end reproduction (`rebar3 ex_doc`)

```console
$ rebar3 new lib exdoc_native && cd exdoc_native
# put d.erl (above) in src/, give it -moduledoc, and add to rebar.config:
#   {project_plugins, [{rebar3_ex_doc, "~> 0.2"}]}.
#   {hex, [{doc, #{provider => ex_doc}}]}.
$ rebar3 ex_doc
===> Running edoc for exdoc_native
edoc: error in doclet 'edoc_doclet_chunks': {'EXIT',error}.
===> An unknown error occurred generating doc chunks with edoc. ...
```

## Evidence that the native docs themselves are fine (it is purely the EDoc bridge)

- The compiler-produced BEAM `Docs` chunk is correct and complete:

  ```console
  $ erl -noshell -eval '{ok,{_,[{"Docs",B}]}} = beam_lib:chunks("_build/default/lib/erli18n/ebin/erli18n.beam",["Docs"]),
      io:format("~p / ~p bytes~n",[element(1,binary_to_term(B)), byte_size(B)]), halt().'
  docs_v1 / 9924 bytes
  ```

- `h/1` renders them at runtime (module doc, function docs, examples, cross-refs).

- Pointing the bundled `ex_doc` escript directly at the BEAM dir produces the full HTML site, offline,
  with **no EDoc step**:

  ```console
  $ _build/default/plugins/rebar3_ex_doc/priv/ex_doc_otp_27 \
        erli18n 0.1.0 _build/default/lib/erli18n/ebin --output doc --main readme ...
  # -> doc/erli18n.html, doc/erli18n_server.html, ... (rich content, only cosmetic
  #    "references gen_server:init/1 but it is undefined or private" warnings)
  ```

- By contrast, the chunk EDoc writes for a native-`-doc` module has empty doc bodies:

  ```erlang
  {docs_v1, [...], erlang, <<"application/erlang+html">>, #{}, #{},
   [{{function,bar,0}, [...], [<<"bar()">>], #{}, #{signature => [...]}}, ...]}
   %%                                          ^^  module doc and every function doc are #{}
  ```

## Related issues

- jelly-beam/rebar3_ex_doc **#123** (open) — "Crashes if type comment has backticks". Same bug; the
  maintainer notes it is "related to EDoc's wiki syntax" and that EDoc wants `` `x' ``. Non-deterministic
  repro; unassigned; no fix.
- erlang/otp **#5778** (open, 2022) — "EDoc swallows errors when running with -chunks". Explains the
  useless `{'EXIT', error}`. Includes a suggested patch to report the real error.
- erlang/otp PR **#8308** (merged) — "edoc: Add doclet to convert _to_ EEP-59 Markdown". Confirms EDoc
  reads `@doc` and only _emits_ EEP-59; it does not read native `-doc`.
- erlang/otp **#9404** (open) — "Add option to force compiler to always generate doc chunks" (relevant
  to a BEAM-chunks-first flow).

## Proposed fixes (for the upstream contribution)

Ranked by where the fix belongs and how structural it is:

1. **`rebar3_ex_doc`: skip EDoc when the BEAM already carries native docs.** `ex_doc` already reads the
   `Docs` chunk from `Ebin`. For an app whose modules carry compiler-produced `docs_v1` chunks
   (detectable via `beam_lib:chunks(Beam, ["Docs"])`), `gen_chunks/2` should be skipped entirely. This
   removes the legacy dependency for modern projects and fixes the crash at its source. (Could be gated
   by a config flag, e.g. `{ex_doc, [{from, beam}]}`, or made automatic.)

2. **`erlang/otp` `edoc_wiki`: do not throw on an unterminated `` ` ``-quote in comment text.** Degrade
   to literal text (and/or a warning) instead of aborting. A backtick in a comment should never be able
   to crash documentation generation, especially for code that does not use EDoc at all.

3. **`erlang/otp` `edoc_doclet_chunks`: surface the real error** (this is `erlang/otp` #5778). At minimum,
   the user should see `` `-quote ended unexpectedly at line N `` with the file and line, not
   `{'EXIT', error}`.

(1) is the smallest change that gives modern projects a correct, EDoc-free path. (2)+(3) harden EDoc for
everyone and are independently worthwhile.

## Appendix — local workaround used in `erli18n` (no upstream dependency)

Generate the site from the BEAM, bypassing the EDoc step the plugin can't skip:

```sh
rebar3 compile
ESCRIPT=$(ls _build/default/plugins/rebar3_ex_doc/priv/ex_doc_otp_* | sort -V | tail -1)
"$ESCRIPT" <app> <vsn> _build/default/lib/<app>/ebin --output doc --main readme --config <docs.config>
```

This is exactly what `rebar3 ex_doc` does _after_ `gen_chunks`, minus the crashing EDoc precondition.

```

```
