-module(rebar3_erli18n_po_meta).

-moduledoc """
Metadata-aware PO/POT serializer for `.pot`/`.po` catalogs.

`erli18n_po` is the parity-verified core: its `entry()` is ONLY
`{singular, Ctx, Msgid, Tr}` or `{plural, Ctx, Msgid, Plural, Forms}`, and
`dump/1` emits ONLY the `msgctxt`/`msgid`/`msgid_plural`/`msgstr` block. By
design it drops `#, fuzzy` (PSD-001) and `#~` obsolete (PSD-007) on parse,
and carries no `#:` references or `#.`/`# ` comments. Those are exactly the
bytes a translator's tooling and a `msgmerge` workflow depend on.

This module is the NEW serializer layer that wraps `erli18n_po` for the
translatable block and emits all the metadata itself:

- `# ` translator comments
- `#.` extracted (programmer) comments
- `#:` source references (`file:line`)
- `#,` flags (`fuzzy`, `c-format`, ...)
- `#|` previous msgid / msgctxt (the `msgmerge` fuzzy hint)
- `#~` obsolete entries (every line of the block is `#~`-prefixed)

It is OUTSIDE the GNU-gettext parity oracle's coverage (that oracle checks
`erli18n_po`'s msgstr block), so it carries its own byte-level golden CT and
— when the `msgmerge` CLI is present — a `msgmerge` parity oracle that skips
cleanly when absent.

## Serialization order

Within one entry the lines are emitted in canonical GNU order: translator
comments, extracted comments, references, flags, previous-msgid, then the
translatable block. Obsolete entries omit references/flags/prev-msgid (GNU
emits only `#~`-prefixed block lines for obsoletes) and prefix every block
line with `#~ `.

## Cost

Serialization is a single O(entries) streaming pass; each entry's metadata
block is emitted independently as the entry is written, so cost grows
linearly with entry-plus-reference count, never with file size or a catalog
cross-product.
""".

-export([dump/1, dump_entry/1, msgid_equal/2]).

-export_type([catalog/0, meta_entry/0, body/0]).

-doc """
A metadata-bearing catalog: a header (raw msgstr text, as `erli18n_po`
keeps it) plus an ordered list of `meta_entry()`.
""".
-type catalog() :: #{
    header := binary(),
    entries := [meta_entry()]
}.

-doc """
The translatable core of an entry, in the SAME shape `erli18n_po:entry()`
uses so it can be handed to `erli18n_po:dump/1` unchanged.
""".
-type body() ::
    {singular, Context :: undefined | binary(), Msgid :: binary(), Translation :: binary()}
    | {plural, Context :: undefined | binary(), Msgid :: binary(),
        MsgidPlural :: undefined | binary(), Forms :: [{non_neg_integer(), binary()}]}.

-doc """
A full PO entry: its translatable `body()` plus the metadata lines that
`erli18n_po` cannot represent.

- `comments` — `# ` translator comment lines (text only, no leading `# `).
- `extracted` — `#.` extracted-comment lines (text only).
- `references` — `#:` references as `{File, Line}`; emitted `file:line`.
- `flags` — `#,` flags as atoms/binaries (e.g. `fuzzy`); `fuzzy` is the one
  `merge` sets.
- `previous` — `#|` previous-msgid hint: `undefined`, or `{Ctx, Msgid}` /
  `{Ctx, Msgid, MsgidPlural}` carried verbatim from the matched old entry.
- `obsolete` — `true` emits the whole entry as a `#~` block (GNU obsolete).
""".
-type meta_entry() :: #{
    body := body(),
    comments => [binary()],
    extracted => [binary()],
    references => [{string() | binary(), pos_integer()}],
    flags => [atom() | binary()],
    previous =>
        undefined
        | {undefined | binary(), binary()}
        | {undefined | binary(), binary(), binary()},
    obsolete => boolean()
}.

-doc """
Serialize a metadata-bearing `catalog()` to PO/POT bytes.

The header is emitted via `erli18n_po:dump/1` (so it inherits the header
fidelity), then each entry via `dump_entry/1`, separated by blank lines.
""".
-spec dump(catalog()) -> binary().
dump(#{header := Header, entries := Entries}) ->
    HeaderBin = erli18n_po:dump(#{header => #{raw => Header}, entries => []}),
    EntriesBin = iolist_to_binary([dump_entry(E) || E <- Entries]),
    <<HeaderBin/binary, EntriesBin/binary>>.

-doc """
Serialize one `meta_entry()` to its PO bytes, metadata first then the body.

A non-obsolete entry emits, in order: `# ` comments, `#.` extracted
comments, `#:` references, `#,` flags, `#|` previous-msgid, then the
translatable block (delegated to `erli18n_po:dump/1`). An obsolete entry
emits its comments then the whole block `#~ `-prefixed, with no
references/flags/prev-msgid (matching GNU `msgmerge` output for obsoletes).
Every entry ends with one trailing blank line.
""".
-spec dump_entry(meta_entry()) -> binary().
dump_entry(Entry) ->
    case maps:get(obsolete, Entry, false) of
        true -> dump_obsolete(Entry);
        false -> dump_live(Entry)
    end.

-spec dump_live(meta_entry()) -> binary().
dump_live(Entry) ->
    Comments = comment_lines(~"# ", maps:get(comments, Entry, [])),
    Extracted = comment_lines(~"#. ", maps:get(extracted, Entry, [])),
    References = reference_lines(maps:get(references, Entry, [])),
    Flags = flag_line(maps:get(flags, Entry, [])),
    Previous = previous_lines(maps:get(previous, Entry, undefined)),
    Block = body_block(maps:get(body, Entry)),
    iolist_to_binary([Comments, Extracted, References, Flags, Previous, Block, ~"\n"]).

-spec dump_obsolete(meta_entry()) -> binary().
dump_obsolete(Entry) ->
    Comments = comment_lines(~"# ", maps:get(comments, Entry, [])),
    Block = body_block(maps:get(body, Entry)),
    ObsoleteBlock = prefix_lines(~"#~ ", Block),
    iolist_to_binary([Comments, ObsoleteBlock, ~"\n"]).

%% =========================
%% Metadata line emitters
%% =========================

-spec comment_lines(binary(), [binary()]) -> iolist().
comment_lines(_Prefix, []) ->
    [];
comment_lines(Prefix, Lines) ->
    [<<Prefix/binary, L/binary, "\n">> || L <- Lines].

-spec reference_lines([{string() | binary(), pos_integer()}]) -> iolist().
reference_lines([]) ->
    [];
reference_lines(Refs) ->
    [
        begin
            FileBin = to_binary(File),
            LineBin = integer_to_binary(Line),
            <<"#: ", FileBin/binary, ":", LineBin/binary, "\n">>
        end
     || {File, Line} <- Refs
    ].

%% Narrow a source path (string or binary) to a binary for embedding in a
%% `#:` line. A source path is always valid char data, so the conversion
%% never fails; an already-binary path passes straight through.
-spec to_binary(string() | binary()) -> binary().
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(Str) when is_list(Str) ->
    case unicode:characters_to_binary(Str) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

-spec flag_line([atom() | binary()]) -> iolist().
flag_line([]) ->
    [];
flag_line(Flags) ->
    Joined = lists:join(~", ", [flag_to_binary(F) || F <- Flags]),
    [~"#, ", Joined, ~"\n"].

-spec flag_to_binary(atom() | binary()) -> binary().
flag_to_binary(F) when is_atom(F) -> atom_to_binary(F, utf8);
flag_to_binary(F) when is_binary(F) -> F.

%% `#|` previous-msgid hint. GNU emits `#| msgctxt "..."` (when present),
%% then `#| msgid "..."`, then `#| msgid_plural "..."` (when present).
-spec previous_lines(
    undefined
    | {undefined | binary(), binary()}
    | {undefined | binary(), binary(), binary()}
) -> iolist().
previous_lines(undefined) ->
    [];
previous_lines({Ctx, Msgid}) ->
    [prev_ctx(Ctx), prev_field(~"msgid", Msgid)];
previous_lines({Ctx, Msgid, MsgidPlural}) ->
    [prev_ctx(Ctx), prev_field(~"msgid", Msgid), prev_field(~"msgid_plural", MsgidPlural)].

-spec prev_ctx(undefined | binary()) -> iodata().
prev_ctx(undefined) -> [];
prev_ctx(Ctx) -> prev_field(~"msgctxt", Ctx).

-spec prev_field(binary(), binary()) -> binary().
prev_field(Key, Value) ->
    %% Reuse the core's canonical escaper so the `#|` previous-msgid literals
    %% escape byte-identically to the msgid/msgstr body `erli18n_po:dump/1`
    %% emits — inheriting the parity-verified fidelity rather than maintaining
    %% a divergent copy.
    Escaped = erli18n_po:escape_string(Value),
    <<"#| ", Key/binary, " \"", Escaped/binary, "\"\n">>.

%% =========================
%% Translatable block (delegated to erli18n_po)
%% =========================

%% Render the msgctxt/msgid/msgid_plural/msgstr block by handing the body to
%% `erli18n_po:dump/1` inside a headerless catalog, then stripping the
%% synthetic empty header `dump/1` always prepends AND the trailing blank
%% line `dump/1` puts after the entry (the entry emitters here add their own
%% separator). This is the ONLY place the body bytes are produced, so they
%% inherit PSD-001..009 for that block. The returned block ends in exactly
%% one `\n` (after the final `msgstr`/`msgstr[N]` line).
-spec body_block(body()) -> binary().
body_block(Body) ->
    Full = erli18n_po:dump(#{header => #{raw => <<>>}, entries => [Body]}),
    strip_header_block(Full).

%% `dump/1` emits `msgid ""\nmsgstr ""\n<header lines>\n\n<entry>\n\n`. The
%% header block is everything up to and including the first blank line; the
%% trailing `\n\n` is the inter-entry separator, which we trim to a single
%% `\n` so the caller controls entry separation.
%%
%% `erli18n_po:dump/1` ALWAYS emits the empty-msgid header followed by a
%% blank line, so the split always yields `[Header, Rest]` — there is no
%% no-separator clause (it would be dead code; a malformed dump that lacked
%% the separator is a contract violation that crashes here explicitly).
-spec strip_header_block(binary()) -> binary().
strip_header_block(Bin) ->
    [_Header, Rest] = binary:split(Bin, ~"\n\n"),
    trim_trailing_blank(Rest).

%% Reduce a trailing `\n\n` (or longer run) to a single `\n`.
-spec trim_trailing_blank(binary()) -> binary().
trim_trailing_blank(Bin) ->
    Trimmed = string:trim(Bin, trailing, "\n"),
    <<Trimmed/binary, "\n">>.

%% =========================
%% Line prefixing (obsolete)
%% =========================

%% Prefix every non-empty line of `Block` with `Prefix`. The block ends in a
%% newline; the trailing empty split element is left unprefixed so we do not
%% emit a dangling `#~ `.
-spec prefix_lines(binary(), binary()) -> binary().
prefix_lines(Prefix, Block) ->
    Lines = binary:split(Block, ~"\n", [global]),
    iolist_to_binary([prefix_one(Prefix, L) || L <- Lines]).

-spec prefix_one(binary(), binary()) -> binary().
prefix_one(_Prefix, <<>>) -> <<>>;
prefix_one(Prefix, Line) -> <<Prefix/binary, Line/binary, "\n">>.

%% =========================
%% msgid equality (wrapping-insensitive)
%% =========================

-doc """
Compare two msgids for LOGICAL equality, ignoring PO line-wrapping.

A `.po` may wrap a long msgid across multiple `"..."` continuation lines
(or emit it `--no-wrap` on one line); both decode to the same logical
string. Since both operands here are already DECODED binaries (the parser
joined continuations), this is plain binary equality — the function exists
to name the contract at merge call sites and to keep the wrapping-equality
guarantee explicit and testable.
""".
-spec msgid_equal(binary(), binary()) -> boolean().
msgid_equal(A, B) when is_binary(A), is_binary(B) ->
    A =:= B.
