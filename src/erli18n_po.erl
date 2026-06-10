-module(erli18n_po).

%% Public API.
-export([
    parse/1,
    parse/2,
    parse_file/1,
    parse_file/2,
    dump/1
]).

-export_type([
    parse_opts/0,
    parsed_catalog/0,
    header_map/0,
    entry/0,
    context/0,
    msgid/0,
    translation/0,
    plural_index/0,
    parse_error/0
]).

%% =========================
%% Types
%% =========================

-type parse_opts() :: #{include_fuzzy => boolean()}.

-type parsed_catalog() :: #{
    header := header_map(),
    entries := [entry()]
}.

%% Per PSD-002: charset normalized to one of utf8 | latin1 | us_ascii.
%% Per PSD-004: plural_forms preserved raw for downstream evaluator.
-type header_map() :: #{
    plural_forms => binary(),
    content_type => binary(),
    charset => utf8 | latin1 | us_ascii,
    raw => binary()
}.

%% Per PSD-006: context is a separate field, never byte-glued with msgid.
-type entry() ::
    {singular, context(), msgid(), translation()}
    | {plural, context(), msgid(), [{plural_index(), translation()}]}.
-type context() :: undefined | binary().
-type msgid() :: binary().
-type translation() :: binary().
-type plural_index() :: non_neg_integer().

%% `file:read_file/1` returns `{error, Reason}` where Reason ranges over
%% `file:posix() | badarg | terminated | system_limit` (see file.erl
%% spec). We surface all of them under `file_error`.
-type file_read_error() ::
    file:posix() | badarg | terminated | system_limit.

-type parse_error() ::
    {unsupported_charset, binary()}
    | {charset_conversion, binary(), term()}
    | {plural_count_mismatch, msgid(), Expected :: non_neg_integer(), Got :: [non_neg_integer()]}
    | {syntax_error, Line :: pos_integer(), Reason :: term()}
    | {file_error, file_read_error()}.

%% =========================
%% Internal parser state
%% =========================

%% Accumulator for a single entry being built line-by-line.
-record(po_st, {
    context :: context(),
    msgid :: undefined | binary(),
    msgid_plural :: undefined | binary(),
    msgstr :: undefined | binary(),
    msgstr_plurals = [] :: [{plural_index(), binary()}],
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
    nplurals :: undefined | non_neg_integer()
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

-spec parse(binary()) -> {ok, parsed_catalog()} | {error, parse_error()}.
parse(Bin) ->
    parse(Bin, #{}).

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
                    do_parse(Utf8Bin, Opts);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec parse_file(file:filename()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path) ->
    parse_file(Path, #{}).

-spec parse_file(file:filename(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path, Opts) ->
    case file:read_file(Path) of
        {ok, Bin} -> parse(Bin, Opts);
        {error, Posix} -> {error, {file_error, Posix}}
    end.

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
is_empty_string_line(<<"\"\"">>, Rest) ->
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
%% `append_to_last/2` deliberately keeps the accumulator on the LEFT and
%% is already O(total); do not "unify" the two.
-spec bins_to_binary([binary()]) -> binary().
bins_to_binary(Bins) when is_list(Bins) ->
    iolist_to_binary(lists:reverse(Bins)).

%% Per PSD-002: accept utf8 (and aliases), latin1 / iso-8859-1, us-ascii.
%% Case-insensitive match per RFC 2978 (charset names are
%% case-insensitive). Anything else: hard fail.
charset_from_header(HeaderText) ->
    case find_charset(HeaderText) of
        undefined -> {ok, utf8};
        Bin -> classify_charset(Bin)
    end.

find_charset(HeaderText) ->
    Lines = binary:split(HeaderText, <<"\n">>, [global]),
    find_charset_line(Lines).

find_charset_line([]) ->
    undefined;
find_charset_line([Line | Rest]) ->
    %% `string:lowercase/1` returns `unicode:chardata()` (which can be a
    %% deep iolist). `binary:match/2` requires a binary. Materialize
    %% once at the boundary; the input came from `binary:split/3` so
    %% it's always a valid binary.
    Lower = to_binary(string:lowercase(Line)),
    case binary:match(Lower, <<"content-type:">>) of
        nomatch ->
            find_charset_line(Rest);
        _ ->
            case binary:match(Lower, <<"charset=">>) of
                nomatch ->
                    %% Content-Type without charset — default utf8 per
                    %% GNU spec.
                    undefined;
                {Start, _Len} ->
                    Rest0 = binary:part(
                        Line,
                        Start + 8,
                        byte_size(Line) - (Start + 8)
                    ),
                    extract_charset_token(Rest0)
            end
    end.

%% Narrow `unicode:chardata()` (potentially a deep iolist) into a flat
%% binary. The header is ASCII-only by GNU gettext spec, so this
%% conversion never errors on the prepass path. We assert
%% post-condition with `is_binary/1` and crash with a descriptive
%% payload if `unicode:characters_to_binary/1` returns the error tuple
%% — that would mean the input was malformed Unicode, which the
%% charset prepass should have caught.
-spec to_binary(unicode:chardata()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(CD) ->
    case unicode:characters_to_binary(CD) of
        B when is_binary(B) -> B;
        Other -> error({chardata_to_binary_failed, Other})
    end.

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
        <<"utf-8">> -> {ok, utf8};
        <<"utf8">> -> {ok, utf8};
        <<"iso-8859-1">> -> {ok, latin1};
        <<"iso8859-1">> -> {ok, latin1};
        <<"latin-1">> -> {ok, latin1};
        <<"latin1">> -> {ok, latin1};
        <<"us-ascii">> -> {ok, us_ascii};
        <<"ascii">> -> {ok, us_ascii};
        _ -> {error, {unsupported_charset, Bin}}
    end.

normalize_input(Bin, utf8) ->
    %% Already UTF-8; validate via unicode:characters_to_binary/1 to fail
    %% loud on malformed bytes.
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin2 when is_binary(Bin2) -> {ok, Bin2};
        {error, _, _} = E -> {error, {charset_conversion, <<"UTF-8">>, E}};
        {incomplete, _, _} = E -> {error, {charset_conversion, <<"UTF-8">>, E}}
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
    {error, {charset_conversion, <<"US-ASCII">>, non_ascii_byte}};
validate_ascii(<<_, Rest/binary>>) ->
    validate_ascii(Rest).

%% =========================
%% Main parser (PO grammar, hand-rolled recursive descent)
%% =========================

do_parse(Utf8Bin, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    Lines = split_lines(Utf8Bin),
    St0 = #pst{include_fuzzy = IncludeFuzzy},
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

%% Line splitting that handles both \n and \r\n line endings without
%% relying on binary:split (which would allocate sublists for the wrong
%% delimiter family on some inputs). We normalize \r\n -> \n first.
split_lines(Bin) ->
    Norm = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    binary:split(Norm, <<"\n">>, [global]).

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
            case decode_quoted_string(Content) of
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
    case decode_quoted_string(Content) of
        {ok, Bin} ->
            Cur2 = set_field(Field, Bin, Cur),
            parse_lines(Rest, Ln + 1, Cur2, St);
        {error, Reason} ->
            {error, {syntax_error, Ln, Reason}}
    end.

set_field(msgctxt, Bin, Cur) ->
    Cur#po_st{
        context = Bin,
        last_field = msgctxt
    };
set_field(msgid, Bin, Cur) ->
    Cur#po_st{
        msgid = Bin,
        last_field = msgid
    };
set_field(msgid_plural, Bin, Cur) ->
    Cur#po_st{
        msgid_plural = Bin,
        last_field = msgid_plural
    };
set_field(msgstr, Bin, Cur) ->
    Cur#po_st{
        msgstr = Bin,
        last_field = msgstr
    };
set_field({msgstr, Idx}, Bin, Cur) ->
    Existing = Cur#po_st.msgstr_plurals,
    Cur#po_st{
        msgstr_plurals = [{Idx, Bin} | Existing],
        last_field = {msgstr, Idx}
    }.

append_to_last(Cur, Bin) ->
    %% classify_line only emits {continuation, _} when last_field =/= undefined
    %% (orphan continuations are intercepted as {syntax_error,
    %% unexpected_continuation}). Therefore the undefined case is
    %% unreachable: hitting it would mean a contract violation and we
    %% want it to crash visibly with case_clause.
    %%
    %% The intermediate `is_binary(Prev)` guards turn the record fields
    %% (typed `undefined | binary()`) into `binary()` at this point, so
    %% the binary append below is type-checked. A non-binary would mean
    %% `set_field/3` was bypassed — contract violation, badmatch.
    case Cur#po_st.last_field of
        msgctxt ->
            Prev = Cur#po_st.context,
            true = is_binary(Prev),
            Cur#po_st{context = <<Prev/binary, Bin/binary>>};
        msgid ->
            Prev = Cur#po_st.msgid,
            true = is_binary(Prev),
            Cur#po_st{msgid = <<Prev/binary, Bin/binary>>};
        msgid_plural ->
            Prev = Cur#po_st.msgid_plural,
            true = is_binary(Prev),
            Cur#po_st{msgid_plural = <<Prev/binary, Bin/binary>>};
        msgstr ->
            Prev = Cur#po_st.msgstr,
            true = is_binary(Prev),
            Cur#po_st{msgstr = <<Prev/binary, Bin/binary>>};
        {msgstr, Idx} ->
            [{Idx, Prev} | T] = Cur#po_st.msgstr_plurals,
            Cur#po_st{msgstr_plurals = [{Idx, <<Prev/binary, Bin/binary>>} | T]}
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

finalize_entry(#po_st{obsolete = true}, St) ->
    %% Per PSD-007: drop obsolete entries silently.
    {ok, St};
finalize_entry(#po_st{msgid = undefined}, St) ->
    %% No msgid in this block — nothing to emit (trailing blank lines,
    %% comment-only blocks, etc.).
    {ok, St};
finalize_entry(#po_st{msgid = <<>>} = Cur, #pst{header = undefined} = St) ->
    %% Header entry: msgid == "". build_header/1 always succeeds because
    %% charset validation already happened in the prepass.
    HeaderText = best_header_text(Cur),
    Header = build_header(HeaderText),
    Nplurals = nplurals_from_header(Header),
    {ok, St#pst{header = Header, nplurals = Nplurals}};
finalize_entry(#po_st{msgid = <<>>}, St) ->
    %% Duplicate header entry — preserve the first one (parity with
    %% msgfmt which uses the first one). Drop silently.
    {ok, St};
finalize_entry(Cur, St) ->
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
        msgid_plural = _Plural,
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
            Entry = {plural, Ctx, Msgid, SortedPlurals},
            {ok, St#pst{entries = [Entry | St#pst.entries]}};
        {error, _} = Err ->
            Err
    end.

%% Per PSD-009: index set must be exactly [0, 1, ..., Nplurals-1].
validate_plural_indices(_Msgid, undefined, _Indices) ->
    ok;
validate_plural_indices(Msgid, Nplurals, Indices) ->
    Expected = lists:seq(0, Nplurals - 1),
    case Indices =:= Expected of
        true -> ok;
        false -> {error, {plural_count_mismatch, Msgid, Nplurals, Indices}}
    end.

%% =========================
%% Header parsing
%% =========================

build_header(<<>>) ->
    empty_header();
build_header(HeaderText) when is_binary(HeaderText) ->
    Fields = parse_header_fields(HeaderText),
    PluralForms = proplists:get_value(<<"plural-forms">>, Fields, <<>>),
    ContentType = proplists:get_value(<<"content-type">>, Fields, <<>>),
    %% The prepass (charset_from_header -> classify_charset) already
    %% rejected unsupported charsets and short-circuited the parse, so
    %% by the time build_header runs the same ContentType must classify
    %% successfully. The {ok, _} match is therefore exhaustive; an
    %% unsupported_charset here would be a contract violation and crash
    %% visibly with case_clause.
    {ok, Charset} = classify_charset_from_content_type(ContentType),
    #{
        plural_forms => PluralForms,
        content_type => ContentType,
        charset => Charset,
        raw => HeaderText
    }.

%% Header lines have the shape "Key: Value\n". Keys are stored lowercased
%% for case-insensitive lookup.
parse_header_fields(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:flatmap(fun parse_header_line/1, Lines).

parse_header_line(<<>>) ->
    [];
parse_header_line(Line) ->
    case binary:split(Line, <<":">>) of
        [Key, Value] ->
            K = string:lowercase(string:trim(Key)),
            V = string:trim(Value),
            [{K, V}];
        _ ->
            []
    end.

classify_charset_from_content_type(<<>>) ->
    {ok, utf8};
classify_charset_from_content_type(ContentType) ->
    %% Same `chardata() -> binary()` narrow as `find_charset_line/1`.
    Lower = to_binary(string:lowercase(ContentType)),
    case binary:match(Lower, <<"charset=">>) of
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
    case binary:match(PF, <<"nplurals">>) of
        nomatch ->
            undefined;
        {Start, _} ->
            Rest = binary:part(PF, Start, byte_size(PF) - Start),
            extract_nplurals_value(Rest)
    end.

extract_nplurals_value(Bin) ->
    case binary:match(Bin, <<"=">>) of
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
    case binary:match(Lower, <<"fuzzy">>) of
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
-spec decode_quoted_string(binary()) ->
    {ok, binary()} | {error, term()}.
decode_quoted_string(<<$", Rest/binary>>) ->
    decode_chars(Rest, []).

-spec decode_chars(binary(), [binary()]) ->
    {ok, binary()} | {error, term()}.
decode_chars(<<$">>, Acc) ->
    {ok, bins_to_binary(Acc)};
decode_chars(<<$", Rest/binary>>, Acc) ->
    case is_only_trailing_ws(Rest) of
        true -> {ok, bins_to_binary(Acc)};
        false -> {error, content_after_close_quote}
    end;
decode_chars(<<$\\, Rest/binary>>, Acc) ->
    case decode_escape(Rest) of
        {ok, Bytes, Rest2} -> decode_chars(Rest2, [Bytes | Acc]);
        {error, _} = E -> E
    end;
decode_chars(<<C/utf8, Rest/binary>>, Acc) ->
    decode_chars(Rest, [<<C/utf8>> | Acc]);
decode_chars(<<>>, _Acc) ->
    {error, unterminated_string};
decode_chars(<<_Byte, _/binary>>, _Acc) ->
    {error, invalid_utf8}.

decode_escape(<<$n, R/binary>>) ->
    {ok, <<$\n>>, R};
decode_escape(<<$t, R/binary>>) ->
    {ok, <<$\t>>, R};
decode_escape(<<$r, R/binary>>) ->
    {ok, <<$\r>>, R};
decode_escape(<<$", R/binary>>) ->
    {ok, <<$">>, R};
decode_escape(<<$\\, R/binary>>) ->
    {ok, <<$\\>>, R};
decode_escape(<<$b, R/binary>>) ->
    {ok, <<$\b>>, R};
decode_escape(<<$f, R/binary>>) ->
    {ok, <<$\f>>, R};
decode_escape(<<$v, R/binary>>) ->
    {ok, <<$\v>>, R};
decode_escape(<<$a, R/binary>>) ->
    {ok, <<7>>, R};
decode_escape(<<$/, R/binary>>) ->
    {ok, <<$/>>, R};
decode_escape(<<$?, R/binary>>) ->
    {ok, <<$?>>, R};
decode_escape(<<$', R/binary>>) ->
    {ok, <<$'>>, R};
decode_escape(<<$x, R/binary>>) ->
    decode_hex_escape(R, <<>>, 0);
decode_escape(<<C, R/binary>>) when C >= $0, C =< $7 ->
    decode_octal_escape(R, <<C>>, 1);
decode_escape(<<C, _/binary>>) ->
    {error, {unknown_escape, C}};
decode_escape(<<>>) ->
    {error, dangling_backslash}.

decode_hex_escape(<<C, R/binary>>, Acc, N) when
    N < 2,
    ((C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F))
->
    decode_hex_escape(R, <<Acc/binary, C>>, N + 1);
decode_hex_escape(R, Acc, _N) when byte_size(Acc) > 0 ->
    Byte = binary_to_integer(Acc, 16),
    {ok, <<Byte>>, R};
decode_hex_escape(_, _, _) ->
    {error, invalid_hex_escape}.

decode_octal_escape(<<C, R/binary>>, Acc, N) when
    N < 3, C >= $0, C =< $7
->
    decode_octal_escape(R, <<Acc/binary, C>>, N + 1);
decode_octal_escape(R, Acc, _N) ->
    Byte = binary_to_integer(Acc, 8),
    {ok, <<Byte>>, R}.

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
    Body = <<"Content-Type: text/plain; charset=UTF-8\n">>,
    dump_header_text(Body);
dump_header(#{raw := RawHeader}) ->
    dump_header_text(RawHeader);
dump_header(_) ->
    %% Tolerate missing keys by emitting a minimal header.
    dump_header_text(<<"Content-Type: text/plain; charset=UTF-8\n">>).

dump_header_text(Body) ->
    Lines = binary:split(Body, <<"\n">>, [global]),
    BodyOut = iolist_to_binary([encode_header_line(L) || L <- Lines]),
    <<"msgid \"\"\nmsgstr \"\"\n", BodyOut/binary, "\n">>.

encode_header_line(<<>>) ->
    <<>>;
encode_header_line(Line) ->
    Escaped = escape_string(Line),
    <<$", Escaped/binary, "\\n", $", $\n>>.

dump_entry({singular, Ctx, Msgid, Translation}) ->
    CtxBin = dump_msgctxt(Ctx),
    MsgidBin = dump_field(<<"msgid">>, Msgid),
    MsgstrBin = dump_field(<<"msgstr">>, Translation),
    <<CtxBin/binary, MsgidBin/binary, MsgstrBin/binary, "\n">>;
dump_entry({plural, Ctx, Msgid, Plurals}) ->
    CtxBin = dump_msgctxt(Ctx),
    MsgidBin = dump_field(<<"msgid">>, Msgid),
    %% msgid_plural is not preserved on parse — synthesize from the last
    %% plural index. The data model carries the singular text only; for
    %% roundtrip the consumer is expected to also store msgid_plural if
    %% required. For our purposes (P1: parse∘dump fixpoint), the
    %% catalog representation already drops msgid_plural — so we emit
    %% msgid as msgid_plural placeholder.
    PluralIdBin = dump_field(<<"msgid_plural">>, Msgid),
    PluralsBin = iolist_to_binary([
        dump_plural_form(I, T)
     || {I, T} <- Plurals
    ]),
    <<CtxBin/binary, MsgidBin/binary, PluralIdBin/binary, PluralsBin/binary, "\n">>.

dump_msgctxt(undefined) ->
    <<>>;
dump_msgctxt(Ctx) when is_binary(Ctx) ->
    dump_field(<<"msgctxt">>, Ctx).

dump_field(Key, Value) ->
    Escaped = escape_string(Value),
    <<Key/binary, " \"", Escaped/binary, "\"\n">>.

dump_plural_form(Idx, T) ->
    IdxBin = integer_to_binary(Idx),
    Escaped = escape_string(T),
    <<"msgstr[", IdxBin/binary, "] \"", Escaped/binary, "\"\n">>.

-spec escape_string(binary()) -> binary().
escape_string(Bin) ->
    escape_string(Bin, []).

-spec escape_string(binary(), [binary()]) -> binary().
escape_string(<<>>, Acc) ->
    bins_to_binary(Acc);
escape_string(<<$\\, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<"\\\\">> | Acc]);
escape_string(<<$", Rest/binary>>, Acc) ->
    escape_string(Rest, [<<"\\\"">> | Acc]);
escape_string(<<$\n, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<"\\n">> | Acc]);
escape_string(<<$\t, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<"\\t">> | Acc]);
escape_string(<<$\r, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<"\\r">> | Acc]);
escape_string(<<C/utf8, Rest/binary>>, Acc) ->
    escape_string(Rest, [<<C/utf8>> | Acc]).
