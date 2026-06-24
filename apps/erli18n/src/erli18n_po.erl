-module(erli18n_po).

-moduledoc """
Parser and serializer for the GNU gettext PO/POT format.

Reads a `.po`/`.pot` catalog (text) and returns a structured `parsed_catalog()`;
`dump/1` is the inverse path. All the logic is hand-rolled recursive descent,
dependency-free, honoring the nine PO-semantics decisions (PSD-001..009).

## What it does and what problem it solves

Turns the raw bytes of a `.po` into data the rest of the library consumes
(`erli18n_server` calls this module at the start of the load pipeline). The nine
decisions in one sentence each:

- PSD-001: `#, fuzzy` entries are dropped by default (parity with `msgfmt`).
- PSD-002: the `Content-Type` charset is normalized to `utf8 | latin1 | us_ascii`.
- PSD-003: an empty translation (`<<>>`) is preserved; the fallback is the
  responsibility of whoever does the lookup, not the parser.
- PSD-004: `Plural-Forms` is preserved raw; only `nplurals` is extracted here.
- PSD-005: a UTF-8 BOM is stripped silently before any processing.
- PSD-006: `msgctxt` is a separate field, never byte-glued to the `msgid`.
- PSD-007: obsolete entries (`#~`) are dropped.
- PSD-008: a degenerate plural (`nplurals=1`) is accepted; `validate_plural_indices/3`
  treats `nplurals=1` as a valid index set (`[0]`), parity with the
  Asian rules (ja/zh/ko/vi/th).
- PSD-009: the `msgstr[N]` index set is validated against `nplurals`.

## Mental model

This module is PURE and STATELESS: no ETS, no process dictionary,
no `application:env`. Each `parse/2` call carries only the binary you
passed; `parse_file/2` just prepends a `file:read_file/1`. Errors
become data (`{error, parse_error()}`), not dead processes.

The input is UNTRUSTED (the multi-tenant threat model in `SECURITY.md`): a
tenant may upload an adversarial `.po`. Hence the contract is "parsing
errors become structured errors, never silent crashes nor unbounded
memory growth". Two concrete defenses live here:

- A cap by digit COUNT before any `binary_to_integer` over attacker input
  (`?MAX_INT_DIGITS`), at the two sites that read integers from the `.po`:
  the `nplurals=` of the header (`collect_digits/2`) and the `msgstr[N]` index
  (`parse_msgstr_index/2`). Without it, a run of thousands of digits would
  build an O(d^2) bignum or hit `system_limit`.
- `bins_to_binary/1` materializes large strings in LINEAR time (left-side
  accumulator + `iolist_to_binary/1`); the naive form with the right-side
  accumulator was Θ(n²) and stalled the loader for seconds on a single large `msgid`.

The `parse/2` pipeline is TWO-PASS, because the body charset is only
known after reading the header:

1. A prepass (`extract_header_charset/1`) reads the raw bytes (the header is
   always ASCII-safe per the GNU spec) and discovers the charset.
2. `normalize_input/2` transcodes the entire body to UTF-8 in that charset.
3. The line-by-line parse runs over UTF-8, with the charset still threaded so
   `\\xHH`/`\\OOO` escapes are interpreted in the declared code space BEFORE the
   UTF-8 gate (two-phase decode, `decode_quoted_string/2` +
   `reassemble_field/2`). Prepass and builder use the SAME field reconciler
   (`field_charset/1`), so they never diverge (that divergence was a badmatch
   that took down the gen_server on a `Content-Type ` with a space before the `:`).

LF, CRLF and lone-CR (classic Mac) line endings are all accepted.

## When you touch this module

- Loading a catalog: `erli18n_server` reads the file on its own
  (`file:read_file/1`) and calls `parse/2` underneath — `parse_file/1,2` is a
  convenience/test helper, NOT the production path. You rarely call it directly.
- Validating/inspecting a `.po` in a tool or test: `parse/1` or `parse/2`.
- Roundtrip / programmatic rewrite: `parse/1` -> edit -> `dump/1`.

## Quickstart

```erlang
1> Po = <<"msgid \"\"\n"
..          "msgstr \"Content-Type: text/plain; charset=UTF-8\\n\"\n"
..          "\n"
..          "msgid \"Hello\"\n"
..          "msgstr \"Ola\"\n">>.
2> {ok, Catalog} = erli18n_po:parse(Po).
3> maps:get(entries, Catalog).
[{singular,undefined,<<"Hello">>,<<"Ola">>}]
4> maps:get(charset, maps:get(header, Catalog)).
utf8
5> erli18n_po:parse(erli18n_po:dump(Catalog)) =:= {ok, Catalog}.
true
```

## Key functions

Input: `parse/1`, `parse/2`, `parse_file/1`, `parse_file/2`. Output: `dump/1`,
and `escape_string/1` (the PO-value escaper `dump/1` uses, exported so the
`rebar3_erli18n` plugin can serialize the metadata it owns byte-identically).
Result type: `parsed_catalog/0`; an entry is an `entry/0`; errors are a
`parse_error/0`.
""".

%% Public API.
-export([
    parse/1,
    parse/2,
    parse_file/1,
    parse_file/2,
    dump/1,
    escape_string/1
]).

-export_type([
    parse_opts/0,
    parsed_catalog/0,
    header_map/0,
    entry/0,
    context/0,
    msgid/0,
    msgid_plural/0,
    translation/0,
    plural_index/0,
    parse_error/0
]).

%% =========================
%% Types
%% =========================

-doc """
Parse options. Today there is only one key: `include_fuzzy`.

With `include_fuzzy => false` (default), entries marked `#, fuzzy` are
dropped on flush (parity with `msgfmt`). With `true`, they are kept. An
empty map `#{}` inherits all the defaults.
""".
-type parse_opts() :: #{include_fuzzy => boolean()}.

-doc """
Result of a successful parse.

`header` is the `header_map()` (always present: synthesized empty if the `.po`
had no header of its own). `entries` is in FILE ORDER. It is exactly the
shape that `dump/1` consumes.

The roundtrip law `parse(dump(C)) =:= {ok, C}` holds for catalogs whose header
was parsed from a `.po` WITH a header of its own (`raw =/= <<>>`). When the
catalog came from an input WITHOUT a header (a synthetic header with
`raw => <<>>` and `content_type => <<>>`), `dump/1` materializes a minimal
`Content-Type`; on re-parse, that field becomes populated and the catalog
differs from the original at that point. See `dump/1` for the detail.
""".
-type parsed_catalog() :: #{
    header := header_map(),
    entries := [entry()]
}.

%% Per PSD-002: charset normalized to one of utf8 | latin1 | us_ascii.
%% Per PSD-004: plural_forms preserved raw for downstream evaluator.
-doc """
Catalog header, already reconciled.

`charset` is the normalized atom (PSD-002). `plural_forms` is the RAW string of
the `Plural-Forms` field (PSD-004): this module does NOT evaluate it — only
`erli18n_plural` does; here it is preserved for downstream. `content_type` is
the raw value of the field of the same name. `raw` is the entire `msgstr` text
of the header, used by `dump/1` to re-emit the header faithfully. A catalog
without a header of its own gets a synthetic header with `charset => utf8` and
the other fields empty.
""".
-type header_map() :: #{
    plural_forms => binary(),
    content_type => binary(),
    charset => utf8 | latin1 | us_ascii,
    raw => binary()
}.

%% Per PSD-006: context is a separate field, never byte-glued with msgid.
%%
%% Finding #14 (dump-drops-msgid-plural-silently): the plural shape retains
%% the `msgid_plural` form text so `dump/1` can re-emit it faithfully. A
%% catalog with no explicit `msgid_plural` (only a singular `msgid` plus
%% `msgstr[N]` lines — unusual but accepted) carries `undefined`, and the
%% dumper falls back to the singular `msgid` for that one slot.
-doc """
A catalog entry, in one of two shapes.

`{singular, Context, Msgid, Translation}` — a 1:1 translation. `Context` is
`undefined` (no `msgctxt`) or a binary. `Translation` may be `<<>>` (PSD-003:
the empty value is preserved, it does not become a fallback here).

`{plural, Context, Msgid, MsgidPlural, Forms}` — a translation with plurals.
`MsgidPlural` is the plural form from the source or `undefined` (degenerate
case: only `msgstr[N]` without an explicit `msgid_plural`). `Forms` is a list
`[{plural_index(), translation()}]` ORDERED by index, validated against
`nplurals` (PSD-009).
""".
-type entry() ::
    {singular, context(), msgid(), translation()}
    | {plural, context(), msgid(), msgid_plural(), [{plural_index(), translation()}]}.
-type context() :: undefined | binary().
-type msgid() :: binary().
-type msgid_plural() :: undefined | binary().
-type translation() :: binary().
-type plural_index() :: non_neg_integer().

%% `file:read_file/1` returns `{error, Reason}` where Reason ranges over
%% `file:posix() | badarg | terminated | system_limit` (see file.erl
%% spec). We surface all of them under `file_error`.
-type file_read_error() ::
    file:posix() | badarg | terminated | system_limit.

-doc """
Structured parse error — the only "normal" failure mode of the public API.

- `{unsupported_charset, Declared}` — the `Content-Type` declared a charset that
  does not map to `utf8 | latin1 | us_ascii`.
- `{charset_conversion, Label, Detail}` — the bytes do not match the declared
  charset (e.g. invalid UTF-8, a byte outside US-ASCII).
- `{plural_count_mismatch, Msgid, Expected, Got}` — the `msgstr[N]` indices do
  not form exactly `[0..Expected-1]` (PSD-009).
- `{syntax_error, Line, Reason}` — malformed line; `Reason` is `term()` and
  also carries the escape-decode errors (e.g. `escape_invalid_utf8`,
  `octal_escape_out_of_range`) without widening the exported tuple.
- `{file_error, Posix}` — only `parse_file/1,2`: the disk read failed.
""".
-type parse_error() ::
    {unsupported_charset, binary()}
    | {charset_conversion, binary(), term()}
    | {plural_count_mismatch, msgid(), Expected :: non_neg_integer(), Got :: [non_neg_integer()]}
    %% The `Reason` of a `{syntax_error, Line, Reason}` is `term()`, so the
    %% escape-decode failures introduced for finding #11
    %% (po-hex-octal-escape-emits-invalid-utf8) — `escape_error()` below —
    %% travel inside this envelope without widening the exported tuple
    %% shape.
    | {syntax_error, Line :: pos_integer(), Reason :: term()}
    | {file_error, file_read_error()}.

%% Normalized charset (PSD-002), reused as the code space in which `\xHH`
%% / `\OOO` escape bytes are interpreted before being transcoded to UTF-8
%% (finding #11). Mirrors the `charset` key of `header_map/0`.
-type charset() :: utf8 | latin1 | us_ascii.

%% A chunk produced while decoding one quoted string, BEFORE the
%% charset->UTF-8 transcode. `{utf8, Bin}` is already valid UTF-8 (literal
%% text that survived the phase-1 gate of `normalize_input/2`, plus the
%% always-ASCII C escapes like `\n`/`\t`). `{raw, B}` is ONE byte in the
%% declared charset's code space, produced by a `\xHH` / `\OOO` escape —
%% exactly how the GNU gettext lexer stacks raw escape bytes before the
%% whole-string charset conversion.
-type chunk() :: {utf8, binary()} | {raw, byte()}.

%% Structured escape-decode errors (finding #11). Emitted as the `Reason`
%% of a `{syntax_error, Line, Reason}`; restores the UTF-8 gate as a true
%% guarantee (no `{ok, _}` carrying invalid UTF-8) and gives parity with
%% msgfmt's "invalid multibyte sequence" rejection.
%% `Rest` is whatever `unicode:characters_to_binary/3` hands back as the
%% undecodable tail — documented as `unicode:chardata()` (it may be a deep
%% iolist, not just a flat binary), so we carry that type verbatim rather
%% than narrowing to `binary()`.
-type escape_error() ::
    {invalid_escape_charset, charset(), Byte :: byte()}
    | {escape_invalid_utf8, Rest :: unicode:chardata()}
    | {escape_incomplete_utf8, Rest :: unicode:chardata()}
    | {octal_escape_out_of_range, pos_integer()}.

%% =========================
%% Internal parser state
%% =========================

%% Accumulator for a single entry being built line-by-line.
%%
%% Finding #17 (po-append-to-last-superlinear): each string field is built
%% as a REVERSED list of segments (`[binary()]`, newest first) while the
%% entry's lines stream in, never as a growing binary. A continuation line
%% prepends ONE segment in O(1) (`append_to_last/2`); the whole field is
%% joined into a binary exactly once, at finalization (`finalize_buffers/1`
%% -> `iolist_to_binary/1`), so building an n-byte field is genuinely
%% O(n) total. The old shape did `<<Prev/binary, Bin/binary>>` per
%% continuation: because `Prev` lived inside the record (more than one
%% reference), the runtime's in-place binary-append optimization did not
%% apply and each append re-copied the accumulator -> Θ(n²) on a single
%% many-continuation msgid. `undefined` still means "field never seen", so
%% the downstream pattern matches (`msgid = undefined`, `msgid = <<>>`) are
%% unchanged — they run AFTER `finalize_buffers/1` has flattened the
%% buffers back to binaries.
-record(po_st, {
    context :: undefined | [binary()] | binary(),
    msgid :: undefined | [binary()] | binary(),
    msgid_plural :: undefined | [binary()] | binary(),
    msgstr :: undefined | [binary()] | binary(),
    msgstr_plurals = [] :: [{plural_index(), [binary()] | binary()}],
    last_field ::
        undefined
        | msgctxt
        | msgid
        | msgid_plural
        | msgstr
        | {msgstr, plural_index()},
    fuzzy = false :: boolean(),
    obsolete = false :: boolean(),
    start_line = 1 :: pos_integer()
}).

%% Global parser context. Carries already-finalized state.
-record(pst, {
    include_fuzzy = false :: boolean(),
    %% reversed during accumulation
    entries = [] :: [entry()],
    header :: undefined | header_map(),
    nplurals :: undefined | non_neg_integer(),
    %% Declared catalog charset (finding #11). Defaults to utf8 so any
    %% legacy internal call building a `#pst{}` without it keeps the prior
    %% already-UTF-8 behaviour. Threaded into every `decode_quoted_string`
    %% call site so `\xHH`/`\OOO` escape bytes are transcoded through the
    %% right code space.
    charset = utf8 :: charset()
}).

%% Maximum number of decimal digits accepted for an attacker-controlled
%% integer run before `binary_to_integer` is called (finding #8,
%% po-plural-unbounded-binary-to-integer-bignum). Two sites read such
%% runs out of untrusted `.po` input: the `nplurals=<digits>` header
%% cross-check (`collect_digits/2`) and the `msgstr[<digits>]` index
%% (`parse_msgstr_index/2`). Both cap the run by DIGIT COUNT first, so a
%% thousands-digit adversarial run is rejected in O(1) without ever
%% building an O(d^2) bignum or reaching the >=~1.3M-digit
%% `error:system_limit` path. 7 digits (max 9_999_999) is far above any
%% legitimate plural-form count (real locales top out at 6) or msgstr
%% index.
-define(MAX_INT_DIGITS, 7).

%% =========================
%% Public API
%% =========================

-doc """
Parses a PO catalog from a binary, with default options
(`include_fuzzy => false`).

Equivalent to `parse(Bin, #{})`. Returns `{ok, parsed_catalog()}` with the
normalized header and the list of entries (in file order), or
`{error, parse_error()}` if the charset is invalid, the conversion fails, there
is a syntax error, or the plural indices diverge from `nplurals`.

```erlang
1> erli18n_po:parse(<<"msgid \"Hello\"\nmsgstr \"Ola\"\n">>).
{ok,#{header => #{charset => utf8,content_type => <<>>,
                  plural_forms => <<>>,raw => <<>>},
      entries => [{singular,undefined,<<"Hello">>,<<"Ola">>}]}}
```

See `parse/2` for the full semantics of options and the pipeline, and `dump/1`
for the inverse path.
""".
-spec parse(binary()) -> {ok, parsed_catalog()} | {error, parse_error()}.
parse(Bin) ->
    parse(Bin, #{}).

-doc """
Parses a PO catalog from a binary, honoring `Opts`.

`Bin` is the raw content of the `.po`; `Opts` is a `parse_opts()` — today only
`include_fuzzy => boolean()` (default `false`: entries marked `#, fuzzy` are
dropped, parity with `msgfmt`). The flow: (1) silent strip of the UTF-8 BOM
(PSD-005); (2) a prepass that extracts the charset from the `Content-Type`
header via the same field reconciler as `build_header/1`, ensuring that prepass
and builder never diverge (finding #5 — closes the `badmatch` on a
`Content-Type ` with a space before the `:`); (3) normalizes the entire body to
UTF-8 in the discovered charset; (4) line-by-line parse with the charset
threaded so `\\xHH`/`\\OOO` escapes are transcoded through the right code space.

Returns `{ok, parsed_catalog()}` (`#{header => header_map(), entries =>
[entry()]}`) or `{error, parse_error()}`. Without an explicit header, it
synthesizes an empty header with charset `utf8`. Accepts LF, CRLF and lone-CR
line endings (finding #15).

Parameters:
- `Bin` — raw content of the `.po`/`.pot`. Treated as UNTRUSTED: an
  `nplurals=` or `msgstr[N]` with an absurd run of digits is rejected in O(1)
  (cap by `?MAX_INT_DIGITS`), never builds a bignum.
- `Opts` — see `parse_opts/0`. `include_fuzzy` controls whether `#, fuzzy`
  entries enter the result.

Failure modes (all `{error, parse_error()}`, never a crash): an unsupported
declared charset, bytes that do not match the charset, plural indices that
diverge from `nplurals`, and malformed lines (with line number).

```erlang
1> Fuzzy = <<"#, fuzzy\nmsgid \"a\"\nmsgstr \"b\"\n">>.
2> {ok, C0} = erli18n_po:parse(Fuzzy, #{}).
3> maps:get(entries, C0).
[]
4> {ok, C1} = erli18n_po:parse(Fuzzy, #{include_fuzzy => true}).
5> maps:get(entries, C1).
[{singular,undefined,<<"a">>,<<"b">>}]
6> erli18n_po:parse(<<"msgid \"a\"\nmsgstr \"b\"\n???\n">>).
{error,{syntax_error,3,{unrecognized_line,<<"???">>}}}
```

See `parse/1` (defaults), `parse_file/2` (from disk) and `dump/1`.
""".
-spec parse(binary(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse(Bin, Opts) when is_binary(Bin), is_map(Opts) ->
    %% Per PSD-005: strip UTF-8 BOM silently before any other processing.
    Stripped = strip_bom(Bin),
    %% Per PSD-002: header determines charset, so first pass extracts header
    %% bytes (raw, treating as latin1-compatible 7-bit ASCII — header is
    %% always ASCII-safe per GNU spec). The second pass uses the discovered
    %% charset to convert the entire body.
    case extract_header_charset(Stripped) of
        {ok, Charset} ->
            case normalize_input(Stripped, Charset) of
                {ok, Utf8Bin} ->
                    %% Finding #11: thread the discovered charset into the
                    %% body parse so escape bytes can be transcoded through
                    %% it instead of being spliced raw.
                    do_parse(Utf8Bin, Charset, Opts);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

-doc """
Reads and parses a `.po` file from disk, with default options.

Equivalent to `parse_file(Path, #{})`. Reads `Path` with `file:read_file/1` and
delegates to `parse/2`. Read errors become `{error, {file_error, file_read_error()}}`.

```erlang
1> erli18n_po:parse_file(<<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).
{ok,#{header => #{charset => utf8, ...}, entries => [...]}}
2> erli18n_po:parse_file(<<"/does/not/exist.po">>).
{error,{file_error,enoent}}
```

See `parse_file/2` (with options) and `parse/2` (the parse semantics themselves).
""".
-spec parse_file(file:filename()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path) ->
    parse_file(Path, #{}).

-doc """
Reads and parses a `.po` file from disk, honoring `Opts`.

Reads `Path` with `file:read_file/1`; on success it delegates the binary to
`parse/2` with `Opts` (see `parse/2` for the semantics of the options and the
return). If the read fails, it returns `{error, {file_error, Posix}}`, where
`Posix` ranges over `file:posix() | badarg | terminated | system_limit`.

Parameters:
- `Path` — file path, any `file:filename()`.
- `Opts` — passed untouched to `parse/2`; see `parse_opts/0`.

The only difference from `parse/2` is the read phase: I/O errors become
`{error, {file_error, Posix}}`; everything already read follows exactly the
rules of `parse/2`.

```erlang
1> erli18n_po:parse_file(<<"catalog.po">>, #{include_fuzzy => true}).
{ok,#{header => #{...}, entries => [...]}}
```

See `parse_file/1` (defaults) and `parse/2`.
""".
-spec parse_file(file:filename(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path, Opts) ->
    case file:read_file(Path) of
        {ok, Bin} -> parse(Bin, Opts);
        {error, Posix} -> {error, {file_error, Posix}}
    end.

-doc """
Serializes a `parsed_catalog()` back to PO text (a UTF-8 binary).

Emits the header block first (`msgid ""` / `msgstr ""` plus the header `raw`,
or a minimal header `Content-Type: text/plain; charset=UTF-8` when the `raw` is
empty or absent) and then each entry. `singular` entries produce
`msgctxt`/`msgid`/`msgstr`; `plural` entries re-emit the retained
`msgid_plural` (finding #14 — when it is `undefined`, the singular `msgid`
is used as a stand-in) and one `msgstr[N]` line per form. The strings are
re-escaped (`\\\\`, `\\"`, `\\n`, `\\t`, `\\r`) so that `parse(dump(C))`
preserves the catalog. A total function: it always returns a `binary()`.

Parameter: `Catalog` must be a valid `parsed_catalog()` (`#{header := _,
entries := _}`) — typically the `{ok, Catalog}` from `parse/2`. A map without
the `header`/`entries` keys triggers `function_clause` (contract: it only
consumes what `parse/2` produces). Each `entry()` must have the `singular`/`plural`
shape; a tuple of any other shape falls through `dump_entry/1` and crashes.

The minimal synthetic header is NOT emitted with the `Content-Type` glued onto
the `msgstr` line: `dump_header_text/1` always emits `msgstr ""` and dumps the
header body as quoted CONTINUATION LINES (`encode_header_line/1`). So the actual
output for a catalog WITHOUT a header of its own is:

```erlang
1> {ok, C} = erli18n_po:parse(<<"msgid \"Hi\"\nmsgstr \"Oi\"\n">>).
2> erli18n_po:dump(C).
<<"msgid \"\"\nmsgstr \"\"\n"
  "\"Content-Type: text/plain; charset=UTF-8\\n\"\n\n"
  "msgid \"Hi\"\nmsgstr \"Oi\"\n\n">>
```

WATCH OUT for the roundtrip: the `.po` above has no header, so `C` carries a
synthetic header (`raw => <<>>`, `content_type => <<>>`). `dump/1` injects a
minimal `Content-Type`; on re-parse, that field is no longer empty, so the
catalog differs from the original and equality is FALSE:

```erlang
3> erli18n_po:parse(erli18n_po:dump(C)) =:= {ok, C}.
false
```

The law `parse(dump(C)) =:= {ok, C}` only holds for catalogs that ALREADY had a
header of their own (`raw =/= <<>>`) — exactly the case of the quickstart in the
moduledoc, which does return `true`.

Inverse path of `parse/1` / `parse/2`. See `parsed_catalog/0` and `entry/0`.
""".
-spec dump(parsed_catalog()) -> binary().
dump(#{header := Header, entries := Entries}) ->
    HeaderBin = dump_header(Header),
    EntriesBin = iolist_to_binary([dump_entry(E) || E <- Entries]),
    <<HeaderBin/binary, EntriesBin/binary>>.

%% =========================
%% Charset detection and conversion (PSD-002)
%% =========================

%% Per PSD-005: BOM strip is the first thing the parser does. Already
%% silent — no logging, no flag.
strip_bom(<<16#EF, 16#BB, 16#BF, Rest/binary>>) -> Rest;
strip_bom(Bin) when is_binary(Bin) -> Bin.

%% Walks the raw input looking for the header entry (first non-comment
%% block starting with msgid ""). Extracts and validates the charset from
%% Content-Type. Returns the normalized charset atom or an error.
%%
%% This pass runs over raw bytes. The header (per GNU spec) is always
%% ASCII-safe, so reading it byte-by-byte is correct regardless of the
%% declared charset.
%%
%% Finding #16 (INFO): the header's `msgstr` lines are decoded here AND
%% again in the main pass. This second decode is INHERENT, not a
%% workaround: the body charset is only knowable after the header has been
%% read, and the line-by-line parse must run over the already-transcoded
%% body — so the header round-trips through the decoder twice by
%% construction. The cost is bounded: it is the HEADER only (one block,
%% ASCII-safe, a handful of short lines per the GNU spec), not the catalog
%% body, so there is no structural single-decode win to be had without
%% regressing charset detection. Left as-is deliberately.
extract_header_charset(Bin) ->
    case extract_header_msgstr(Bin) of
        {ok, HeaderText} -> charset_from_header(HeaderText);
        no_header -> {ok, utf8};
        {error, _} = Err -> Err
    end.

%% Extract the msgstr text of the first entry whose msgid is empty.
%% Returns the concatenated header msgstr (with newlines preserved as in
%% the source) as a binary, or no_header if no header found.
extract_header_msgstr(Bin) ->
    Lines = split_lines(Bin),
    find_header(Lines, 1, []).

find_header([], _Ln, []) ->
    no_header;
find_header([], _Ln, _Acc) ->
    no_header;
find_header([Line | Rest], Ln, Acc) ->
    Trimmed = trim_leading_ws(Line),
    case classify_raw_line(Trimmed) of
        blank when Acc =:= [] ->
            find_header(Rest, Ln + 1, []);
        comment ->
            find_header(Rest, Ln + 1, Acc);
        {msgid, Content} ->
            %% Header has msgid "". If the first msgid in the file is
            %% non-empty, there is no proper header — fallback to default.
            case is_empty_string_line(Content, Rest) of
                {true, RestAfterMsgid} ->
                    collect_header_msgstr(RestAfterMsgid, Ln + 1);
                {false, _} ->
                    no_header
            end;
        _ ->
            find_header(Rest, Ln + 1, [Line | Acc])
    end.

%% Returns {true, RestLines} when the current msgid is the empty string
%% (after consuming any continuation lines). Otherwise {false, _}.
is_empty_string_line(~"\"\"", Rest) ->
    %% No continuation expected; but if the next non-blank line starts
    %% with ", it's part of this string. For the header, the empty string
    %% has no continuation.
    {true, Rest};
is_empty_string_line(_, Rest) ->
    {false, Rest}.

%% After seeing msgid "", look for the corresponding msgstr and gather it
%% (with continuation lines). The header msgstr's content is what we need.
collect_header_msgstr([], _Ln) ->
    no_header;
collect_header_msgstr([Line | Rest], Ln) ->
    Trimmed = trim_leading_ws(Line),
    case classify_raw_line(Trimmed) of
        blank ->
            collect_header_msgstr(Rest, Ln + 1);
        comment ->
            collect_header_msgstr(Rest, Ln + 1);
        {msgstr, Content} ->
            case decode_quoted_string(Content) of
                {ok, First} ->
                    {More, _Remaining} = consume_continuations(Rest),
                    {ok, <<First/binary, More/binary>>};
                {error, Reason} ->
                    {error, {syntax_error, Ln, Reason}}
            end;
        _ ->
            no_header
    end.

-spec consume_continuations([binary()]) -> {binary(), [binary()]}.
consume_continuations(Lines) ->
    consume_continuations(Lines, []).

-spec consume_continuations([binary()], [binary()]) ->
    {binary(), [binary()]}.
consume_continuations([], Acc) ->
    {bins_to_binary(Acc), []};
consume_continuations([Line | Rest] = All, Acc) ->
    Trimmed = trim_leading_ws(Line),
    case Trimmed of
        <<$", _/binary>> ->
            case decode_quoted_string(Trimmed) of
                {ok, Bin} -> consume_continuations(Rest, [Bin | Acc]);
                {error, _} -> {bins_to_binary(Acc), All}
            end;
        _ ->
            {bins_to_binary(Acc), All}
    end.

%% Reverse-and-concatenate a list of binaries into one binary. The list
%% comes pre-reversed from accumulator-style callers (latest element
%% first), so we reverse once and let `iolist_to_binary/1` materialize
%% the result in a single linear pass.
%%
%% This MUST stay linear in the total byte count. The previous shape —
%% a fold building `<<B/binary, Acc/binary>>` — placed the growing
%% accumulator on the RIGHT, which defeats the runtime's in-place binary
%% growth optimization (that only applies to append, `<<Acc/binary,
%% B/binary>>`, with a single reference). With the accumulator on the
%% right the whole `Acc` is re-copied on every element -> Θ(n²) to build
%% one n-byte string, so a single large msgid/msgstr stalled the loader
%% gen_server for seconds (Finding #3,
%% `po-decode-bins-to-binary-quadratic`). `iolist_to_binary/1` does the
%% same job in two linear passes (reverse + BIF) with one allocation —
%% strictly better above a few dozen bytes. `[binary()]` is a subtype of
%% `iolist()`, so the `-spec` is preserved and eqwalizer-friendly.
%%
%% Finding #17: `append_to_last/2` now ALSO accumulates continuation
%% segments as a reversed `[binary()]` list and routes them through THIS
%% same join (via `finalize_buffers/1`), so the per-field build is
%% genuinely O(total). The previous comment claimed `append_to_last/2`'s
%% left-accumulator binary append was "already O(total)" — it was not: the
%% growing accumulator lived inside the `#po_st{}` record (more than one
%% reference), defeating the runtime's in-place append optimization and
%% making a many-continuation field super-linear. Both paths now share
%% this single linear join.
-spec bins_to_binary([binary()]) -> binary().
bins_to_binary(Bins) when is_list(Bins) ->
    iolist_to_binary(lists:reverse(Bins)).

%% Per PSD-002: accept utf8 (and aliases), latin1 / iso-8859-1, us-ascii.
%% Case-insensitive match per RFC 2978 (charset names are
%% case-insensitive). Anything else: hard fail.
%%
%% Finding #5 (po-header-malformed-content-type-badmatch-crash): this
%% prepass MUST agree with `build_header/1` on every input, or an
%% adversarial header (e.g. `Content-Type : ...; charset=Shift_JIS` with
%% a space before the colon) makes the two paths disagree — the prepass
%% defaulting to utf8 while `build_header` classifies and crashes on a
%% non-exhaustive match. We guarantee agreement by deriving the charset
%% from the SAME normalized field list (`parse_header_fields/1`, which
%% splits each header line on the first colon and trims/lowercases the
%% key per RFC 822 LWSP) and the SAME classifier (`field_charset/1`) that
%% `build_header/1` uses. One reconciler, one whitespace policy, no
%% divergence.
-spec charset_from_header(binary()) ->
    {ok, utf8 | latin1 | us_ascii} | {error, parse_error()}.
charset_from_header(HeaderText) ->
    field_charset(parse_header_fields(HeaderText)).

%% Single charset reconciler shared by the prepass (`charset_from_header/1`)
%% and the header builder (`build_header/1`). Both pass the normalized
%% field list from `parse_header_fields/1`, so they can never disagree.
-spec field_charset([{binary(), binary()}]) ->
    {ok, utf8 | latin1 | us_ascii} | {error, parse_error()}.
field_charset(Fields) ->
    classify_charset_from_content_type(
        proplists:get_value(~"content-type", Fields, <<>>)
    ).

%% Narrow `unicode:chardata()` (potentially a deep iolist) into a flat
%% binary. The header is ASCII-only by GNU gettext spec, so this
%% conversion never errors on the prepass path. We assert
%% post-condition with `is_binary/1` and crash with a descriptive
%% payload if `unicode:characters_to_binary/1` returns the error tuple
%% — that would mean the input was malformed Unicode, which the
%% charset prepass should have caught.
%% Both callers pass `string:lowercase/1` of a binary, which always returns a
%% binary, so there is no chardata clause (a non-binary would be a contract
%% violation and crashes explicitly via `function_clause`).
-spec to_binary(binary()) -> binary().
to_binary(B) when is_binary(B) -> B.

extract_charset_token(Bin) ->
    extract_charset_token(Bin, <<>>).

extract_charset_token(<<>>, Acc) ->
    finalize_token(Acc);
extract_charset_token(<<C, _/binary>>, Acc) when
    C =:= $;; C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n
->
    finalize_token(Acc);
extract_charset_token(<<C, Rest/binary>>, Acc) ->
    extract_charset_token(Rest, <<Acc/binary, C>>).

finalize_token(<<>>) -> undefined;
finalize_token(Bin) -> Bin.

classify_charset(Bin) ->
    case string:lowercase(Bin) of
        ~"utf-8" -> {ok, utf8};
        ~"utf8" -> {ok, utf8};
        ~"iso-8859-1" -> {ok, latin1};
        ~"iso8859-1" -> {ok, latin1};
        ~"latin-1" -> {ok, latin1};
        ~"latin1" -> {ok, latin1};
        ~"us-ascii" -> {ok, us_ascii};
        ~"ascii" -> {ok, us_ascii};
        _ -> {error, {unsupported_charset, Bin}}
    end.

normalize_input(Bin, utf8) ->
    %% Already UTF-8; validate via unicode:characters_to_binary/1 to fail
    %% loud on malformed bytes.
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin2 when is_binary(Bin2) -> {ok, Bin2};
        {error, _, _} = E -> {error, {charset_conversion, ~"UTF-8", E}};
        {incomplete, _, _} = E -> {error, {charset_conversion, ~"UTF-8", E}}
    end;
normalize_input(Bin, us_ascii) ->
    %% US-ASCII is a strict subset of UTF-8 — passthrough is correct, but
    %% we validate that bytes are within 0-127.
    case validate_ascii(Bin) of
        ok -> {ok, Bin};
        {error, _} = E -> E
    end;
normalize_input(Bin, latin1) ->
    %% Every byte 0..255 is a valid Latin-1 codepoint, so
    %% unicode:characters_to_binary/3 with latin1 -> utf8 cannot return
    %% error/incomplete. A binary result is the only possible outcome;
    %% any other shape is a contract violation that will surface as a
    %% badmatch crash on the pattern below.
    Bin2 = unicode:characters_to_binary(Bin, latin1, utf8),
    true = is_binary(Bin2),
    {ok, Bin2}.

validate_ascii(<<>>) ->
    ok;
validate_ascii(<<C, _/binary>>) when C > 127 ->
    {error, {charset_conversion, ~"US-ASCII", non_ascii_byte}};
validate_ascii(<<_, Rest/binary>>) ->
    validate_ascii(Rest).

%% =========================
%% Main parser (PO grammar, hand-rolled recursive descent)
%% =========================

-doc """
(Internal, maintainer.) The parse engine: it already receives the body in UTF-8
(`Utf8Bin`) and the discovered `Charset`, threaded for the escape decode.

Runs `parse_lines/4` accumulating entries in REVERSE order in the `#pst{}` (hence
`lists:reverse/1` at the end — the accumulator invariant of this module). If no
header entry (`msgid ""`) appeared, it synthesizes an empty header with
`charset => utf8` via `empty_header/0`. Only reached after `parse/2` has already
discovered the charset and normalized the body; never called directly.
""".
-spec do_parse(binary(), charset(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
do_parse(Utf8Bin, Charset, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    Lines = split_lines(Utf8Bin),
    St0 = #pst{include_fuzzy = IncludeFuzzy, charset = Charset},
    case parse_lines(Lines, 1, fresh_entry(1), St0) of
        {ok, #pst{header = undefined, entries = Entries}} ->
            %% No header entry — synthesize an empty header with utf8.
            Header = empty_header(),
            {ok, #{
                header => Header,
                entries => lists:reverse(Entries)
            }};
        {ok, #pst{header = Header, entries = Entries}} ->
            {ok, #{
                header => Header,
                entries => lists:reverse(Entries)
            }};
        {error, _} = Err ->
            Err
    end.

empty_header() ->
    #{
        plural_forms => <<>>,
        content_type => <<>>,
        charset => utf8,
        raw => <<>>
    }.

fresh_entry(Ln) ->
    #po_st{start_line = Ln}.

%% Line splitting that handles LF, CRLF and lone-CR line endings. We fold
%% CRLF -> LF first, then any remaining lone CR (0x0D, classic-Mac style)
%% -> LF, before splitting on LF. This matches `msgfmt -c`, which accepts
%% all three newline conventions (Finding #15). Folding CRLF first ensures
%% a CRLF is never turned into two separate line breaks.
split_lines(Bin) ->
    Norm0 = binary:replace(Bin, ~"\r\n", ~"\n", [global]),
    Norm = binary:replace(Norm0, ~"\r", ~"\n", [global]),
    binary:split(Norm, ~"\n", [global]).

parse_lines([], _Ln, Cur, St) ->
    %% EOF — flush any pending entry.
    finalize_entry(Cur, St);
parse_lines([Line | Rest], Ln, Cur, St) ->
    Trimmed = trim_leading_ws(Line),
    case classify_line(Trimmed, Cur) of
        blank ->
            case is_empty_entry(Cur) of
                true ->
                    parse_lines(Rest, Ln + 1, fresh_entry(Ln + 1), St);
                false ->
                    case finalize_entry(Cur, St) of
                        {ok, St1} ->
                            parse_lines(
                                Rest,
                                Ln + 1,
                                fresh_entry(Ln + 1),
                                St1
                            );
                        {error, _} = Err ->
                            Err
                    end
            end;
        skip ->
            parse_lines(Rest, Ln + 1, Cur, St);
        fuzzy_flag ->
            parse_lines(Rest, Ln + 1, Cur#po_st{fuzzy = true}, St);
        obsolete ->
            %% Per PSD-007: obsolete lines are skipped entirely, but they
            %% can span multiple lines forming a fake entry. Mark the
            %% current entry as obsolete so it is discarded on flush.
            parse_lines(Rest, Ln + 1, Cur#po_st{obsolete = true}, St);
        {msgctxt, Content} ->
            handle_string_field(msgctxt, Content, Rest, Ln, Cur, St);
        {msgid, Content} ->
            handle_string_field(msgid, Content, Rest, Ln, Cur, St);
        {msgid_plural, Content} ->
            handle_string_field(msgid_plural, Content, Rest, Ln, Cur, St);
        {msgstr, Content} ->
            handle_string_field(msgstr, Content, Rest, Ln, Cur, St);
        {msgstr_n, Idx, Content} ->
            handle_string_field({msgstr, Idx}, Content, Rest, Ln, Cur, St);
        {continuation, Content} ->
            case decode_quoted_string(Content, St#pst.charset) of
                {ok, Bin} ->
                    Cur2 = append_to_last(Cur, Bin),
                    parse_lines(Rest, Ln + 1, Cur2, St);
                {error, Reason} ->
                    {error, {syntax_error, Ln, Reason}}
            end;
        {syntax_error, Reason} ->
            {error, {syntax_error, Ln, Reason}}
    end.

handle_string_field(Field, Content, Rest, Ln, Cur, St) ->
    case decode_quoted_string(Content, St#pst.charset) of
        {ok, Bin} ->
            Cur2 = set_field(Field, Bin, Cur),
            parse_lines(Rest, Ln + 1, Cur2, St);
        {error, Reason} ->
            {error, {syntax_error, Ln, Reason}}
    end.

%% Finding #17: each string field starts life as a one-element REVERSED
%% segment list (`[Bin]`), so a later continuation just prepends (O(1)) and
%% the whole field joins once at finalization. The `last_field` tag drives
%% which buffer `append_to_last/2` extends.
set_field(msgctxt, Bin, Cur) ->
    Cur#po_st{
        context = [Bin],
        last_field = msgctxt
    };
set_field(msgid, Bin, Cur) ->
    Cur#po_st{
        msgid = [Bin],
        last_field = msgid
    };
set_field(msgid_plural, Bin, Cur) ->
    Cur#po_st{
        msgid_plural = [Bin],
        last_field = msgid_plural
    };
set_field(msgstr, Bin, Cur) ->
    Cur#po_st{
        msgstr = [Bin],
        last_field = msgstr
    };
set_field({msgstr, Idx}, Bin, Cur) ->
    Existing = Cur#po_st.msgstr_plurals,
    Cur#po_st{
        msgstr_plurals = [{Idx, [Bin]} | Existing],
        last_field = {msgstr, Idx}
    }.

%% Finding #17 (po-append-to-last-superlinear): append ONE continuation
%% segment by PREPENDING it to the field's reversed segment list (O(1)),
%% never by re-copying a growing binary. The field is joined into a binary
%% exactly once, later, in `finalize_buffers/1`, so building an n-byte
%% field over many continuation lines is genuinely O(n) total instead of
%% the old Θ(n²).
append_to_last(Cur, Bin) ->
    %% classify_line only emits {continuation, _} when last_field =/= undefined
    %% (orphan continuations are intercepted as {syntax_error,
    %% unexpected_continuation}). Therefore the undefined case is
    %% unreachable: hitting it would mean a contract violation and we
    %% want it to crash visibly with case_clause.
    %%
    %% The matched `[_ | _] = Segs` pattern proves the field is a NON-EMPTY
    %% reversed segment list at this point — `set_field/3` always seeds it
    %% with `[Bin]` before any continuation can extend it, so a non-list /
    %% empty-list field would mean `set_field/3` was bypassed (contract
    %% violation, badmatch).
    case Cur#po_st.last_field of
        msgctxt ->
            [_ | _] = Segs = Cur#po_st.context,
            Cur#po_st{context = [Bin | Segs]};
        msgid ->
            [_ | _] = Segs = Cur#po_st.msgid,
            Cur#po_st{msgid = [Bin | Segs]};
        msgid_plural ->
            [_ | _] = Segs = Cur#po_st.msgid_plural,
            Cur#po_st{msgid_plural = [Bin | Segs]};
        msgstr ->
            [_ | _] = Segs = Cur#po_st.msgstr,
            Cur#po_st{msgstr = [Bin | Segs]};
        {msgstr, Idx} ->
            [{Idx, [_ | _] = Segs} | T] = Cur#po_st.msgstr_plurals,
            Cur#po_st{msgstr_plurals = [{Idx, [Bin | Segs]} | T]}
    end.

is_empty_entry(#po_st{
    context = undefined,
    msgid = undefined,
    msgid_plural = undefined,
    msgstr = undefined,
    msgstr_plurals = [],
    fuzzy = false,
    obsolete = false
}) ->
    true;
is_empty_entry(_) ->
    false.

%% =========================
%% Entry finalization
%% =========================

%% Finding #17: flatten the per-field reversed segment buffers
%% (`[binary()]`, built O(1)-per-continuation) back into single binaries
%% EXACTLY ONCE, here at the finalization boundary, before any of the
%% `finalize_entry_flat/2` clauses pattern-match on `msgid = undefined` /
%% `msgid = <<>>` or `emit_entry/2` reads the fields. After this call every
%% string field is `undefined | binary()` again, so all downstream matches
%% are unchanged.
finalize_entry(Cur, St) ->
    finalize_entry_flat(finalize_buffers(Cur), St).

%% Join each field's reversed segment list into one binary with a single
%% linear `iolist_to_binary/1` pass (`bins_to_binary/1`), leaving
%% `undefined` (field never seen) untouched. No `-spec`: like the other
%% `#po_st{}`-consuming internals (`set_field/3`, `append_to_last/2`,
%% `emit_entry/2`) it takes the record directly, and elvis'
%% `no_spec_with_records` rule forbids naming the record in a spec.
finalize_buffers(#po_st{} = Cur) ->
    Cur#po_st{
        context = flatten_field(Cur#po_st.context),
        msgid = flatten_field(Cur#po_st.msgid),
        msgid_plural = flatten_field(Cur#po_st.msgid_plural),
        msgstr = flatten_field(Cur#po_st.msgstr),
        %% Plural buffers are always a reversed `[binary()]` segment list at
        %% finalization (never `undefined`, never a bare binary), so join them
        %% with `bins_to_binary/1` directly. The `is_list/1` guard narrows the
        %% record field's `[binary()] | binary()` union to the list arm; it is
        %% always true here (the buffer is built only by prepending segments),
        %% so it drops nothing and the join stays a single linear pass.
        msgstr_plurals = [
            {Idx, bins_to_binary(Segs)}
         || {Idx, Segs} <- Cur#po_st.msgstr_plurals, is_list(Segs)
        ]
    }.

%% `undefined` -> `undefined` (field never seen); a reversed segment list
%% -> one binary in a single linear pass.
-spec flatten_field(undefined | [binary()] | binary()) -> undefined | binary().
flatten_field(undefined) -> undefined;
flatten_field(Segs) when is_list(Segs) -> bins_to_binary(Segs).

finalize_entry_flat(#po_st{obsolete = true}, St) ->
    %% Per PSD-007: drop obsolete entries silently.
    {ok, St};
finalize_entry_flat(#po_st{msgid = undefined}, St) ->
    %% No msgid in this block — nothing to emit (trailing blank lines,
    %% comment-only blocks, etc.).
    {ok, St};
finalize_entry_flat(#po_st{msgid = <<>>} = Cur, #pst{header = undefined} = St) ->
    %% Header entry: msgid == "". `build_header/1` is total — the prepass
    %% (parse/2) already reconciled the charset and short-circuited an
    %% unsupported one before do_parse, so it returns `{ok, _}` here.
    HeaderText = best_header_text(Cur),
    {ok, Header} = build_header(HeaderText),
    Nplurals = nplurals_from_header(Header),
    {ok, St#pst{header = Header, nplurals = Nplurals}};
finalize_entry_flat(#po_st{msgid = <<>>}, St) ->
    %% Duplicate header entry — preserve the first one (parity with
    %% msgfmt which uses the first one). Drop silently.
    {ok, St};
finalize_entry_flat(Cur, St) ->
    case Cur#po_st.fuzzy andalso not St#pst.include_fuzzy of
        true ->
            %% Per PSD-001: fuzzy entries dropped by default.
            {ok, St};
        false ->
            emit_entry(Cur, St)
    end.

best_header_text(#po_st{msgstr = Bin}) when is_binary(Bin) -> Bin;
best_header_text(_) -> <<>>.

emit_entry(
    #po_st{
        msgid_plural = undefined,
        msgid = Msgid,
        context = Ctx,
        msgstr = Msgstr
    },
    St
) ->
    Translation =
        case Msgstr of
            undefined -> <<>>;
            _ -> Msgstr
        end,
    %% Per PSD-003: parser preserves <<>> as translation; fallback is
    %% lookup's responsibility.
    Entry = {singular, Ctx, Msgid, Translation},
    {ok, St#pst{entries = [Entry | St#pst.entries]}};
emit_entry(
    #po_st{
        msgid_plural = MsgidPlural,
        msgid = Msgid,
        context = Ctx,
        msgstr_plurals = Plurals
    },
    St
) ->
    %% Per PSD-009: validate index set against nplurals from the header
    %% (when known). If the header is absent or has no nplurals, accept
    %% any index set.
    SortedPlurals = lists:keysort(1, Plurals),
    Indices = [I || {I, _} <- SortedPlurals],
    case validate_plural_indices(Msgid, St#pst.nplurals, Indices) of
        ok ->
            %% Finding #14: retain `msgid_plural` so `dump/1` re-emits the
            %% real plural-form source text instead of substituting `Msgid`.
            Entry = {plural, Ctx, Msgid, MsgidPlural, SortedPlurals},
            {ok, St#pst{entries = [Entry | St#pst.entries]}};
        {error, _} = Err ->
            Err
    end.

-doc """
(Internal, maintainer — PSD-009.) Validates the `msgstr[N]` index set of a
plural entry against the header's `Nplurals`.

If `Nplurals` is `undefined` (no header, or a header without a usable `nplurals`),
it ACCEPTS any set — a deliberate fail-open, matched with the fail-open of
`collect_digits/2`. Otherwise the set must be EXACTLY
`[0, 1, ..., Nplurals-1]` (already sorted by the caller); a divergence becomes
`{error, {plural_count_mismatch, Msgid, Nplurals, Indices}}`, which bubbles up as
a `parse_error()`.

Anti-DoS (finding #1, po-plural-nplurals-seq-allocation-dos): `Nplurals` is
attacker-controlled — `collect_digits/2` only caps the DIGIT COUNT, so the
header may legitimately declare `nplurals=9999999`. The validation MUST NOT
size any list by that value (the old `lists:seq(0, Nplurals - 1)` allocated a
~10M-element list, ~80MB, for a 158-byte `.po`). Instead it checks the two
conditions that `Indices =:= lists:seq(0, Nplurals - 1)` decomposes into,
without ever materializing the expected sequence: (1) the present set is a
dense `[0, 1, ..., length(Indices) - 1]` prefix — sized by the bytes actually
present in the file, not the header; and (2) that length equals `Nplurals`. A
genuine count mismatch still yields the EXACT same
`{plural_count_mismatch, Msgid, Nplurals, Indices}` payload, in O(length(Indices)).
""".
%% Per PSD-009: index set must be exactly [0, 1, ..., Nplurals-1].
validate_plural_indices(_Msgid, undefined, _Indices) ->
    ok;
validate_plural_indices(Msgid, Nplurals, Indices) ->
    %% Size the comparison list by the indices PRESENT in the file
    %% (`length(Indices)`), never by the untrusted header `Nplurals`. The
    %% set is exactly `[0..Nplurals-1]` iff it is a dense 0-based prefix of
    %% its own length AND that length equals `Nplurals`; checking both
    %% avoids `lists:seq(0, Nplurals - 1)`, which an adversarial
    %% `nplurals=9999999` would blow up into a multi-MB allocation.
    DensePrefix = lists:seq(0, length(Indices) - 1),
    case Indices =:= DensePrefix andalso length(Indices) =:= Nplurals of
        true -> ok;
        false -> {error, {plural_count_mismatch, Msgid, Nplurals, Indices}}
    end.

%% =========================
%% Header parsing
%% =========================

%% Finding #5 (po-header-malformed-content-type-badmatch-crash):
%% `build_header/1` is now TOTAL — it returns `{error, parse_error()}`
%% instead of crashing on an unsupported charset. The charset is
%% reconciled through `field_charset/1`, the SAME path the prepass uses,
%% so in practice the prepass has already short-circuited an unsupported
%% charset before we get here. Returning the structured error (rather
%% than the old non-exhaustive `{ok,Charset} =` match) closes the
%% badmatch class for good: any future divergence degrades to a clean
%% `{error, _}` propagated by `finalize_entry/2`, never an uncaught
%% exception that terminates the loader gen_server.
-spec build_header(binary()) -> {ok, header_map()}.
build_header(<<>>) ->
    {ok, empty_header()};
build_header(HeaderText) when is_binary(HeaderText) ->
    Fields = parse_header_fields(HeaderText),
    PluralForms = proplists:get_value(~"plural-forms", Fields, <<>>),
    ContentType = proplists:get_value(~"content-type", Fields, <<>>),
    %% The prepass (parse/2) already reconciled the charset via the identical
    %% `field_charset/1` and short-circuited an unsupported charset BEFORE
    %% do_parse ran, so it is `{ok, _}` here. Asserting the match (rather than
    %% re-handling `{error, _}` on an unreachable path) keeps the single charset
    %% gate in the prepass; a future divergence crashes explicitly (badmatch).
    {ok, Charset} = field_charset(Fields),
    {ok, #{
        plural_forms => PluralForms,
        content_type => ContentType,
        charset => Charset,
        raw => HeaderText
    }}.

%% Header lines have the shape "Key: Value\n". Keys are stored lowercased
%% for case-insensitive lookup.
parse_header_fields(Bin) ->
    Lines = binary:split(Bin, ~"\n", [global]),
    lists:flatmap(fun parse_header_line/1, Lines).

parse_header_line(<<>>) ->
    [];
parse_header_line(Line) ->
    case binary:split(Line, ~":") of
        [Key, Value] ->
            K = string:lowercase(string:trim(Key)),
            V = string:trim(Value),
            [{K, V}];
        _ ->
            []
    end.

-spec classify_charset_from_content_type(binary()) ->
    {ok, utf8 | latin1 | us_ascii} | {error, {unsupported_charset, binary()}}.
classify_charset_from_content_type(<<>>) ->
    {ok, utf8};
classify_charset_from_content_type(ContentType) ->
    %% Narrow `chardata() -> binary()` at the boundary so `binary:match/2`
    %% is type-checked.
    Lower = to_binary(string:lowercase(ContentType)),
    case binary:match(Lower, ~"charset=") of
        nomatch ->
            {ok, utf8};
        {Start, _Len} ->
            Rest = binary:part(
                ContentType,
                Start + 8,
                byte_size(ContentType) - (Start + 8)
            ),
            Token = extract_charset_token(Rest),
            case Token of
                undefined -> {ok, utf8};
                _ -> classify_charset(Token)
            end
    end.

%% Per PSD-004: nplurals parsed eagerly for cross-check with msgstr[N]
%% indices. The full Plural-Forms expression is preserved raw for
%% downstream evaluation.
nplurals_from_header(#{plural_forms := <<>>}) ->
    undefined;
nplurals_from_header(#{plural_forms := PF}) ->
    case binary:match(PF, ~"nplurals") of
        nomatch ->
            undefined;
        {Start, _} ->
            Rest = binary:part(PF, Start, byte_size(PF) - Start),
            extract_nplurals_value(Rest)
    end.

extract_nplurals_value(Bin) ->
    case binary:match(Bin, ~"=") of
        nomatch ->
            undefined;
        {EqStart, _} ->
            After = binary:part(
                Bin,
                EqStart + 1,
                byte_size(Bin) - (EqStart + 1)
            ),
            collect_digits(After, <<>>)
    end.

%% Finding #8 (po-plural-unbounded-binary-to-integer-bignum): cap the
%% digit run by COUNT before `binary_to_integer`. This is a tolerant
%% cross-check of the header's `nplurals=` value (used only to validate
%% plural-form counts downstream), so an over-long run is treated as "no
%% usable nplurals declared" — `undefined`, the same fail-open outcome as
%% a missing field — rather than crashing the parse. The bignum is never
%% materialised, so the O(d^2) cost and the >=~1.3M-digit `system_limit`
%% exception are both avoided.
-doc """
(Internal, maintainer — anti-DoS defense.) Reads the digit run of `nplurals=`
in the header, capping by COUNT (`?MAX_INT_DIGITS`) BEFORE `binary_to_integer`.

A TOLERANT fail-open: an empty or over-long run becomes `undefined` — the same
result as "no `nplurals` declared". This is safe because the value only serves
as a downstream cross-check (`validate_plural_indices/3`); an adversarial header
with thousands of digits is ignored in O(1), never builds the bignum. Contrast
with `parse_msgstr_index/2`, which FAILS CLOSED (the index is load-bearing).
""".
-spec collect_digits(binary(), binary()) -> undefined | non_neg_integer().
collect_digits(_, Acc) when byte_size(Acc) > ?MAX_INT_DIGITS ->
    undefined;
collect_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    collect_digits(Rest, <<Acc/binary, C>>);
collect_digits(_, <<>>) ->
    undefined;
collect_digits(_, Acc) ->
    binary_to_integer(Acc).

%% =========================
%% Line classification
%% =========================

%% For the prepass extracting the header charset, we treat all comments
%% uniformly and only flag msgid/msgstr.
classify_raw_line(<<>>) ->
    blank;
classify_raw_line(<<"#", _/binary>>) ->
    comment;
classify_raw_line(<<"msgctxt", Rest/binary>>) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgctxt, Content};
        error -> other
    end;
classify_raw_line(<<"msgid_plural", Rest/binary>>) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgid_plural, Content};
        error -> other
    end;
classify_raw_line(<<"msgid", Rest/binary>>) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgid, Content};
        error -> other
    end;
classify_raw_line(<<"msgstr", Rest/binary>>) ->
    case classify_msgstr(Rest) of
        {ok, Content} -> {msgstr, Content};
        {ok, Idx, Content} -> {msgstr_n, Idx, Content};
        %% Prepass only extracts the header charset; a malformed or
        %% over-long msgstr index (finding #8) is irrelevant here and is
        %% treated like any other unclassified line.
        {error, _} -> other;
        error -> other
    end;
classify_raw_line(<<$", _/binary>>) ->
    continuation;
classify_raw_line(_) ->
    other.

%% Full classifier for the main parser (carries context-sensitive info).
classify_line(<<>>, _Cur) ->
    blank;
classify_line(<<"#~", _Rest/binary>>, _Cur) ->
    %% Per PSD-007: any line starting with #~ is part of an obsolete
    %% entry. We mark the entry as obsolete; downstream skips it.
    %% Body content is irrelevant — the entire entry is dropped on flush.
    obsolete;
classify_line(<<"#,", Rest/binary>>, _Cur) ->
    %% Flag line. Look for the literal token "fuzzy". Other flags
    %% (c-format, no-c-format, etc.) are ignored — they have no effect
    %% on the catalog content.
    %% Narrow chardata() -> binary() so binary:match/2 is type-checked.
    Lower = to_binary(string:lowercase(Rest)),
    case binary:match(Lower, ~"fuzzy") of
        nomatch -> skip;
        _ -> fuzzy_flag
    end;
classify_line(<<"#|", _Rest/binary>>, _Cur) ->
    %% Previous-msgid (informational, GNU manual "Marking Translations
    %% as Fuzzy"). Skip.
    skip;
classify_line(<<"#.", _Rest/binary>>, _Cur) ->
    skip;
classify_line(<<"#:", _Rest/binary>>, _Cur) ->
    skip;
classify_line(<<"#", _Rest/binary>>, _Cur) ->
    %% Translator comment.
    skip;
classify_line(<<"msgctxt", Rest/binary>>, _Cur) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgctxt, Content};
        error -> {syntax_error, expected_msgctxt_string}
    end;
classify_line(<<"msgid_plural", Rest/binary>>, _Cur) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgid_plural, Content};
        error -> {syntax_error, expected_msgid_plural_string}
    end;
classify_line(<<"msgid", Rest/binary>>, _Cur) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {msgid, Content};
        error -> {syntax_error, expected_msgid_string}
    end;
classify_line(<<"msgstr", Rest/binary>>, _Cur) ->
    case classify_msgstr(Rest) of
        {ok, Content} -> {msgstr, Content};
        {ok, Idx, Content} -> {msgstr_n, Idx, Content};
        %% Finding #8: an over-long `msgstr[<digits>]` index surfaces a
        %% structured reason so the parse fails closed with a precise
        %% diagnostic instead of crashing on a giant `binary_to_integer`.
        {error, Reason} -> {syntax_error, Reason};
        error -> {syntax_error, expected_msgstr_string}
    end;
classify_line(<<$", _/binary>> = Line, #po_st{last_field = LF}) when LF =/= undefined ->
    {continuation, Line};
classify_line(<<$", _/binary>>, _Cur) ->
    {syntax_error, unexpected_continuation};
classify_line(Other, _Cur) ->
    {syntax_error, {unrecognized_line, Other}}.

strip_keyword_space(<<>>) -> error;
strip_keyword_space(<<$\s, Rest/binary>>) -> strip_keyword_space(Rest);
strip_keyword_space(<<$\t, Rest/binary>>) -> strip_keyword_space(Rest);
strip_keyword_space(<<$", _/binary>> = Bin) -> {ok, Bin};
strip_keyword_space(_) -> error.

classify_msgstr(<<$[, Rest/binary>>) ->
    case parse_msgstr_index(Rest, <<>>) of
        {ok, Idx, After} ->
            case strip_keyword_space(After) of
                {ok, Content} -> {ok, Idx, Content};
                error -> error
            end;
        {error, _} = Err ->
            Err;
        error ->
            error
    end;
classify_msgstr(Rest) ->
    case strip_keyword_space(Rest) of
        {ok, Content} -> {ok, Content};
        error -> error
    end.

%% Finding #8 (po-plural-unbounded-binary-to-integer-bignum): cap the
%% `msgstr[<digits>]` index run by DIGIT COUNT before `binary_to_integer`
%% builds the bignum. An over-long run is surfaced as a structured
%% `{error, {index_too_long, Max}}` (the rejected run is kept OUT of the
%% payload), which the caller turns into a `{syntax_error, _, _}` parse
%% error — never an O(d^2) bignum and never an uncaught `system_limit`.
-doc """
(Internal, maintainer — anti-DoS defense.) Reads the index of `msgstr[<digits>]`,
capping by COUNT (`?MAX_INT_DIGITS`) before `binary_to_integer`.

FAILS CLOSED (unlike `collect_digits/2`): an over-long run becomes
`{error, {index_too_long, Max}}` — with the rejected run DELIBERATELY kept out
of the payload — which the caller converts into `{syntax_error, Line, _}`. The
index is load-bearing (it selects the plural form), so silently ignoring it
would be wrong; better to reject the `.po`. Returns `error` (no `{}`) for a `[`
that does not close with `]` over valid digits.
""".
-spec parse_msgstr_index(binary(), binary()) ->
    {ok, non_neg_integer(), binary()}
    | {error, {index_too_long, pos_integer()}}
    | error.
parse_msgstr_index(_, Acc) when byte_size(Acc) > ?MAX_INT_DIGITS ->
    {error, {index_too_long, ?MAX_INT_DIGITS}};
parse_msgstr_index(<<$], Rest/binary>>, Acc) when byte_size(Acc) > 0 ->
    {ok, binary_to_integer(Acc), Rest};
parse_msgstr_index(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    parse_msgstr_index(Rest, <<Acc/binary, C>>);
parse_msgstr_index(_, _) ->
    error.

trim_leading_ws(<<$\s, Rest/binary>>) -> trim_leading_ws(Rest);
trim_leading_ws(<<$\t, Rest/binary>>) -> trim_leading_ws(Rest);
trim_leading_ws(Bin) -> Bin.

%% =========================
%% Quoted string decoder
%% =========================

%% Decodes a PO-style quoted string. Input must start with " and end
%% with " (trailing whitespace allowed). Escape sequences per the GNU
%% gettext PO format spec (https://www.gnu.org/software/gettext/manual/
%% gettext.html#PO-Files): \n \t \r \" \\ \xHH \OOO \b \f \v \a.
%%
%% All four call sites (collect_header_msgstr, consume_continuations,
%% handle_string_field, parse_lines continuation branch) gate input on
%% <<$", _/binary>> via strip_keyword_space or a guard pattern, so the
%% leading quote is an enforced precondition. Passing anything else is
%% a contract violation and will crash with function_clause.
%% Arity-1 shim for the header prepass call sites
%% (`collect_header_msgstr/2`, `consume_continuations/2`). The header is
%% ASCII-safe per the GNU spec and is decoded BEFORE the body charset is
%% applied, so utf8 (the already-UTF-8 identity, matching the legacy
%% behaviour for ASCII) is the correct code space there.
-spec decode_quoted_string(binary()) ->
    {ok, binary()} | {error, term()}.
decode_quoted_string(Bin) ->
    decode_quoted_string(Bin, utf8).

%% Finding #11 — two-phase decode (mirrors the GNU gettext lexer):
%% phase 1 walks the quoted string emitting tagged `chunk()`s (literal
%% UTF-8 text vs. raw escape bytes); phase 2 (`reassemble_field/2`)
%% transcodes contiguous raw runs through the declared charset, so
%% `\xHH`/`\OOO` escape bytes end up as valid UTF-8 (or a structured
%% error) instead of being spliced raw past the UTF-8 gate.
-doc """
(Internal, maintainer.) Decodes ONE quoted PO string, in two phases.

Input invariant: `Bin` MUST start with `"` — all 4 call sites
guarantee this via `strip_keyword_space/1` or a guard. Passing anything else is
a contract violation and crashes with `function_clause`.

Phase 1 (`decode_chars/2`) walks the string emitting tagged `chunk()`s: literal
already-UTF-8 text becomes `{utf8, _}`; a `\\xHH`/`\\OOO` escape becomes `{raw, Byte}`
in the code space of the declared charset. Phase 2 (`reassemble_field/2`)
transcodes the runs of contiguous raw bytes through the charset and interleaves
them with the UTF-8 chunks. Grouping is essential: in UTF-8 a multibyte
codepoint is written as CONSECUTIVE escapes (`\\xC3\\xBF` = U+00FF) and must be
validated as one unit — a lone `\\xFF` becomes `{error, {escape_invalid_utf8, _}}`,
never a leaked invalid byte.
""".
-spec decode_quoted_string(binary(), charset()) ->
    {ok, binary()} | {error, term()}.
decode_quoted_string(<<$", Rest/binary>>, Charset) ->
    case decode_chars(Rest, []) of
        {ok, ChunksRev} -> reassemble_field(ChunksRev, Charset);
        {error, _} = E -> E
    end.

%% Accumulates `[chunk()]` in REVERSE order (newest first), like the rest
%% of the module's accumulators.
-spec decode_chars(binary(), [chunk()]) ->
    {ok, [chunk()]} | {error, term()}.
decode_chars(<<$">>, Acc) ->
    {ok, Acc};
decode_chars(<<$", Rest/binary>>, Acc) ->
    case is_only_trailing_ws(Rest) of
        true -> {ok, Acc};
        false -> {error, content_after_close_quote}
    end;
decode_chars(<<$\\, Rest/binary>>, Acc) ->
    case decode_escape(Rest) of
        {ok, Chunk, Rest2} -> decode_chars(Rest2, [Chunk | Acc]);
        {error, _} = E -> E
    end;
decode_chars(<<C/utf8, Rest/binary>>, Acc) ->
    %% Literal text already survived the phase-1 UTF-8 gate, so keep the
    %% codepoint as a ready-made UTF-8 chunk.
    decode_chars(Rest, [{utf8, <<C/utf8>>} | Acc]);
decode_chars(<<>>, _Acc) ->
    {error, unterminated_string};
decode_chars(<<_Byte, _/binary>>, _Acc) ->
    {error, invalid_utf8}.

%% "Literal" C escapes (\n \t \" ...) are ASCII, so they are trivially
%% valid UTF-8 and become `{utf8, _}` chunks. Only `\xHH`/`\OOO` produce a
%% `{raw, Byte}` chunk interpreted later in the declared charset.
-spec decode_escape(binary()) ->
    {ok, chunk(), binary()} | {error, term()}.
decode_escape(<<$n, R/binary>>) ->
    {ok, {utf8, <<$\n>>}, R};
decode_escape(<<$t, R/binary>>) ->
    {ok, {utf8, <<$\t>>}, R};
decode_escape(<<$r, R/binary>>) ->
    {ok, {utf8, <<$\r>>}, R};
decode_escape(<<$", R/binary>>) ->
    {ok, {utf8, <<$">>}, R};
decode_escape(<<$\\, R/binary>>) ->
    {ok, {utf8, <<$\\>>}, R};
decode_escape(<<$b, R/binary>>) ->
    {ok, {utf8, <<$\b>>}, R};
decode_escape(<<$f, R/binary>>) ->
    {ok, {utf8, <<$\f>>}, R};
decode_escape(<<$v, R/binary>>) ->
    {ok, {utf8, <<$\v>>}, R};
decode_escape(<<$a, R/binary>>) ->
    {ok, {utf8, <<7>>}, R};
decode_escape(<<$/, R/binary>>) ->
    {ok, {utf8, <<$/>>}, R};
decode_escape(<<$?, R/binary>>) ->
    {ok, {utf8, <<$?>>}, R};
decode_escape(<<$', R/binary>>) ->
    {ok, {utf8, <<$'>>}, R};
decode_escape(<<$x, R/binary>>) ->
    decode_hex_escape(R, <<>>, 0);
decode_escape(<<C, R/binary>>) when C >= $0, C =< $7 ->
    decode_octal_escape(R, <<C>>, 1);
decode_escape(<<C, _/binary>>) ->
    {error, {unknown_escape, C}};
decode_escape(<<>>) ->
    {error, dangling_backslash}.

%% `\xHH` -> {raw, Byte}: the byte is interpreted later in the declared
%% charset (`reassemble_field/2`), not spliced raw.
-spec decode_hex_escape(binary(), binary(), 0..2) ->
    {ok, {raw, byte()}, binary()} | {error, term()}.
decode_hex_escape(<<C, R/binary>>, Acc, N) when
    N < 2,
    ((C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F))
->
    decode_hex_escape(R, <<Acc/binary, C>>, N + 1);
decode_hex_escape(R, Acc, _N) when byte_size(Acc) > 0 ->
    Byte = binary_to_integer(Acc, 16),
    {ok, {raw, Byte}, R};
decode_hex_escape(_, _, _) ->
    {error, invalid_hex_escape}.

%% `\OOO` -> {raw, Byte}. In PO a `\OOO` escape is BY DEFINITION a single
%% byte; three octal digits reach 0777 (511), so values > 0xFF are a
%% malformed-escape error rather than a wrap.
-spec decode_octal_escape(binary(), binary(), 1..3) ->
    {ok, {raw, byte()}, binary()} | {error, term()}.
decode_octal_escape(<<C, R/binary>>, Acc, N) when
    N < 3, C >= $0, C =< $7
->
    decode_octal_escape(R, <<Acc/binary, C>>, N + 1);
decode_octal_escape(R, Acc, _N) ->
    Int = binary_to_integer(Acc, 8),
    case Int =< 16#FF of
        true -> {ok, {raw, Int}, R};
        false -> {error, {octal_escape_out_of_range, Int}}
    end.

%% =========================
%% Phase 2: charset->UTF-8 transcode of escape bytes (finding #11)
%% =========================

%% Takes the reversed chunk list from `decode_chars/2`, groups contiguous
%% raw bytes into runs, transcodes each run through the declared charset,
%% and interleaves with the ready UTF-8 chunks. Grouping is essential: in
%% a UTF-8 catalog a multibyte codepoint is written as CONSECUTIVE escapes
%% (`\xC3\xBF` = U+00FF) and must be validated as one unit.
-spec reassemble_field([chunk()], charset()) ->
    {ok, binary()} | {error, escape_error()}.
reassemble_field(ChunksRev, Charset) ->
    reassemble(lists:reverse(ChunksRev), Charset, [], []).

%% `RawAcc` collects contiguous raw bytes (reverse order); `Out` collects
%% finished UTF-8 segments (reverse order).
-spec reassemble([chunk()], charset(), [byte()], [binary()]) ->
    {ok, binary()} | {error, escape_error()}.
reassemble([{raw, B} | Rest], Charset, RawAcc, Out) ->
    reassemble(Rest, Charset, [B | RawAcc], Out);
reassemble([{utf8, Bin} | Rest], Charset, RawAcc, Out) ->
    case flush_raw(RawAcc, Charset) of
        {ok, Flushed} ->
            reassemble(Rest, Charset, [], [Bin, Flushed | Out]);
        {error, _} = E ->
            E
    end;
reassemble([], Charset, RawAcc, Out) ->
    case flush_raw(RawAcc, Charset) of
        {ok, Flushed} ->
            {ok, iolist_to_binary(lists:reverse([Flushed | Out]))};
        {error, _} = E ->
            E
    end.

%% Transcode one run of charset-native raw bytes into UTF-8.
-spec flush_raw([byte()], charset()) ->
    {ok, binary()} | {error, escape_error()}.
flush_raw([], _Charset) ->
    {ok, <<>>};
flush_raw(RawAccRev, Charset) ->
    Bytes = list_to_binary(lists:reverse(RawAccRev)),
    transcode_escape_bytes(Bytes, Charset).

-spec transcode_escape_bytes(binary(), charset()) ->
    {ok, binary()} | {error, escape_error()}.
transcode_escape_bytes(Bytes, latin1) ->
    %% Every byte 0..255 is a valid Latin-1 codepoint; latin1 -> utf8
    %% never fails (same contract as `normalize_input/2`).
    Out = unicode:characters_to_binary(Bytes, latin1, utf8),
    true = is_binary(Out),
    {ok, Out};
transcode_escape_bytes(Bytes, us_ascii) ->
    %% US-ASCII: a byte >= 0x80 is outside the charset. gettext rejects;
    %% we surface a structured error instead of emitting a non-ASCII byte.
    case first_non_ascii(Bytes) of
        none -> {ok, Bytes};
        Bad -> {error, {invalid_escape_charset, us_ascii, Bad}}
    end;
transcode_escape_bytes(Bytes, utf8) ->
    %% UTF-8 catalog: the raw run MUST itself be valid UTF-8 (e.g.
    %% `\xC3\xBF` = U+00FF). A lone `\xFF` -> structured error, parity
    %% with msgfmt's "invalid multibyte sequence".
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Out when is_binary(Out) ->
            {ok, Out};
        {error, _Converted, Rest} ->
            {error, {escape_invalid_utf8, Rest}};
        {incomplete, _Converted, Rest} ->
            {error, {escape_incomplete_utf8, Rest}}
    end.

-spec first_non_ascii(binary()) -> none | byte().
first_non_ascii(<<>>) -> none;
first_non_ascii(<<B, _/binary>>) when B > 127 -> B;
first_non_ascii(<<_, R/binary>>) -> first_non_ascii(R).

is_only_trailing_ws(<<>>) ->
    true;
is_only_trailing_ws(<<C, R/binary>>) when
    C =:= $\s;
    C =:= $\t;
    C =:= $\r;
    C =:= $\n
->
    is_only_trailing_ws(R);
is_only_trailing_ws(_) ->
    false.

%% =========================
%% Dumper (for P1/P2 roundtrip properties)
%% =========================

dump_header(#{raw := <<>>} = _Header) ->
    %% No raw header text known — emit a minimal one.
    Body = ~"Content-Type: text/plain; charset=UTF-8\n",
    dump_header_text(Body);
dump_header(#{raw := RawHeader}) ->
    dump_header_text(RawHeader);
dump_header(_) ->
    %% Tolerate missing keys by emitting a minimal header.
    dump_header_text(~"Content-Type: text/plain; charset=UTF-8\n").

dump_header_text(Body) ->
    Lines = binary:split(Body, ~"\n", [global]),
    BodyOut = iolist_to_binary([encode_header_line(L) || L <- Lines]),
    <<"msgid \"\"\nmsgstr \"\"\n", BodyOut/binary, "\n">>.

encode_header_line(<<>>) ->
    <<>>;
encode_header_line(Line) ->
    Escaped = escape_string(Line),
    <<$", Escaped/binary, "\\n", $", $\n>>.

dump_entry({singular, Ctx, Msgid, Translation}) ->
    CtxBin = dump_msgctxt(Ctx),
    MsgidBin = dump_field(~"msgid", Msgid),
    MsgstrBin = dump_field(~"msgstr", Translation),
    <<CtxBin/binary, MsgidBin/binary, MsgstrBin/binary, "\n">>;
dump_entry({plural, Ctx, Msgid, MsgidPlural, Plurals}) ->
    CtxBin = dump_msgctxt(Ctx),
    MsgidBin = dump_field(~"msgid", Msgid),
    %% Finding #14 (dump-drops-msgid-plural-silently): emit the RETAINED
    %% `msgid_plural` form text. The parsed `entry/0` now carries it
    %% verbatim, so `parse∘dump` preserves the plural source. When the
    %% source had no explicit `msgid_plural` (carried as `undefined`), we
    %% fall back to the singular `Msgid` — the only sensible stand-in, and
    %% the historical behaviour for that degenerate case.
    PluralIdSrc =
        case MsgidPlural of
            undefined -> Msgid;
            _ -> MsgidPlural
        end,
    PluralIdBin = dump_field(~"msgid_plural", PluralIdSrc),
    PluralsBin = iolist_to_binary([
        dump_plural_form(I, T)
     || {I, T} <- Plurals
    ]),
    <<CtxBin/binary, MsgidBin/binary, PluralIdBin/binary, PluralsBin/binary, "\n">>.

dump_msgctxt(undefined) ->
    <<>>;
dump_msgctxt(Ctx) when is_binary(Ctx) ->
    dump_field(~"msgctxt", Ctx).

dump_field(Key, Value) ->
    Escaped = escape_string(Value),
    <<Key/binary, " \"", Escaped/binary, "\"\n">>.

dump_plural_form(Idx, T) ->
    IdxBin = integer_to_binary(Idx),
    Escaped = escape_string(T),
    <<"msgstr[", IdxBin/binary, "] \"", Escaped/binary, "\"\n">>.

-doc """
Escape a raw string for the body of a PO `"..."` value.

Applies the five GNU gettext PO escapes — backslash, double-quote, newline,
tab, carriage return — so the result can be wrapped in `"..."` and parsed back
byte-identically by `parse/1`. This is the exact escaping `dump/1` uses for
every emitted field, exposed as public API so the separate `rebar3_erli18n`
plugin package can serialize PO metadata it owns (notably the `#|`
previous-msgid lines written by `rebar3_erli18n_po_meta`) byte-identically to
`dump/1`, across the published `{deps, [erli18n]}` boundary, instead of
vendoring a duplicate escaper that would have to stay in lock-step forever.

The five escapes applied, every other byte passed through unchanged:

```erlang
1> erli18n_po:escape_string(<<"a\"b\nc\td\\e">>).
<<"a\\\"b\\nc\\td\\\\e">>
```
""".
-spec escape_string(binary()) -> binary().
escape_string(Bin) ->
    escape_string(Bin, []).

-spec escape_string(binary(), [binary()]) -> binary().
escape_string(<<>>, Acc) ->
    bins_to_binary(Acc);
%% Each escaped form is emitted as an explicit two-byte character segment
%% (`<<$\\, $X>>` = a literal backslash followed by `X`) rather than a `"..."`
%% string or a `~"..."` sigil. This is unambiguous for an escape sequence and
%% sidesteps a tooling wart: the equivalent escape-heavy sigils (`~"\\\\"`,
%% `~"\\\""`) are valid Erlang but desync ELP's parser.
escape_string(<<$\\, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<$\\, $\\>> | Acc]);
escape_string(<<$", Rest/binary>>, Acc) ->
    escape_string(Rest, [<<$\\, $">> | Acc]);
escape_string(<<$\n, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<$\\, $n>> | Acc]);
escape_string(<<$\t, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<$\\, $t>> | Acc]);
escape_string(<<$\r, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<$\\, $r>> | Acc]);
escape_string(<<C/utf8, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<C/utf8>> | Acc]).
