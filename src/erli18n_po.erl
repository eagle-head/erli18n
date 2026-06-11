-module(erli18n_po).

-moduledoc """
Parser e serializador do formato GNU gettext PO/POT.

Implementa um descida-recursiva escrito a mao que honra as nove decisoes de
semantica PO (PSD-001..009): detecta e normaliza o charset declarado no
`Content-Type` do header (utf8 | latin1 | us_ascii), descarta entradas fuzzy e
obsoletas por padrao, separa `msgctxt` do `msgid`, preserva `Plural-Forms` cru
e valida o conjunto de indices `msgstr[N]` contra `nplurals`. Erros de parsing
viram `parse_error()` estruturados (charset nao suportado, conversao,
divergencia de plural, `syntax_error` por linha, erro de arquivo) — nunca
crashes silenciosos. O decode de escapes (`\\xHH`/`\\OOO`) e transcodificado
pelo charset declarado antes do gate UTF-8, e `dump/1` faz o caminho inverso
para roundtrip.
""".

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
    msgid_plural/0,
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
%%
%% Finding #14 (dump-drops-msgid-plural-silently): the plural shape retains
%% the `msgid_plural` form text so `dump/1` can re-emit it faithfully. A
%% catalog with no explicit `msgid_plural` (only a singular `msgid` plus
%% `msgstr[N]` lines — unusual but accepted) carries `undefined`, and the
%% dumper falls back to the singular `msgid` for that one slot.
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
Faz o parse de um catalogo PO a partir de um binario, com opcoes padrao
(`include_fuzzy => false`).

Equivale a `parse(Bin, #{})`. Retorna `{ok, parsed_catalog()}` com o header
normalizado e a lista de entradas (na ordem do arquivo), ou
`{error, parse_error()}` se o charset for invalido, a conversao falhar, houver
erro de sintaxe ou os indices de plural divergirem de `nplurals`.
""".
-spec parse(binary()) -> {ok, parsed_catalog()} | {error, parse_error()}.
parse(Bin) ->
    parse(Bin, #{}).

-doc """
Faz o parse de um catalogo PO a partir de um binario, respeitando `Opts`.

`Bin` e o conteudo bruto do `.po`; `Opts` e um `parse_opts()` — hoje so
`include_fuzzy => boolean()` (default `false`: entradas marcadas `#, fuzzy` sao
descartadas, parity com `msgfmt`). O fluxo: (1) strip silencioso do BOM UTF-8
(PSD-005); (2) prepass que extrai o charset do header `Content-Type` via o mesmo
reconciliador de campos do `build_header/1`, garantindo que prepass e builder
nunca divirjam (finding #5 — fecha o `badmatch` em `Content-Type ` com espaco
antes do `:`); (3) normaliza o corpo inteiro para UTF-8 no charset descoberto;
(4) parse linha-a-linha com o charset threaded para que escapes `\\xHH`/`\\OOO`
sejam transcodificados pelo code space correto.

Retorna `{ok, parsed_catalog()}` (`#{header => header_map(), entries =>
[entry()]}`) ou `{error, parse_error()}`. Sem header explicito, sintetiza um
header vazio com charset `utf8`. Aceita finais de linha LF, CRLF e lone-CR
(finding #15).
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
Le e faz o parse de um arquivo `.po` do disco, com opcoes padrao.

Equivale a `parse_file(Path, #{})`. Le `Path` com `file:read_file/1` e delega a
`parse/2`. Erros de leitura viram `{error, {file_error, file_read_error()}}`.
""".
-spec parse_file(file:filename()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path) ->
    parse_file(Path, #{}).

-doc """
Le e faz o parse de um arquivo `.po` do disco, respeitando `Opts`.

Le `Path` com `file:read_file/1`; em caso de sucesso delega o binario a
`parse/2` com `Opts` (ver `parse/2` para a semantica das opcoes e do retorno).
Se a leitura falhar, retorna `{error, {file_error, Posix}}`, onde `Posix`
percorre `file:posix() | badarg | terminated | system_limit`.
""".
-spec parse_file(file:filename(), parse_opts()) ->
    {ok, parsed_catalog()} | {error, parse_error()}.
parse_file(Path, Opts) ->
    case file:read_file(Path) of
        {ok, Bin} -> parse(Bin, Opts);
        {error, Posix} -> {error, {file_error, Posix}}
    end.

-doc """
Serializa um `parsed_catalog()` de volta para o texto PO (binario UTF-8).

Emite primeiro o bloco de header (`msgid ""` / `msgstr ""` mais o `raw` do
header, ou um header minimo `Content-Type: text/plain; charset=UTF-8` quando o
`raw` esta vazio ou ausente) e depois cada entrada. Entradas `singular`
produzem `msgctxt`/`msgid`/`msgstr`; entradas `plural` re-emitem o
`msgid_plural` retido (finding #14 — quando ele e `undefined`, o `msgid`
singular e usado como stand-in) e uma linha `msgstr[N]` por forma. As strings
sao re-escapadas (`\\\\`, `\\"`, `\\n`, `\\t`, `\\r`) para que `parse(dump(C))`
preserve o catalogo. Funcao total: sempre retorna um `binary()`.
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
        proplists:get_value(<<"content-type">>, Fields, <<>>)
    ).

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
    Norm0 = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    Norm = binary:replace(Norm0, <<"\r">>, <<"\n">>, [global]),
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
    %% Header entry: msgid == "". `build_header/1` is total (finding #5):
    %% it reconciles the charset through the same `field_charset/1` the
    %% prepass uses, so an unsupported charset surfaces as a structured
    %% `{error, parse_error()}` rather than a badmatch crash. In the
    %% normal flow the prepass already short-circuited that case, so the
    %% `{ok, _}` arm is taken; the `{error, _}` arm is belt-and-suspenders
    %% that keeps the failure structured if the paths ever diverge.
    HeaderText = best_header_text(Cur),
    case build_header(HeaderText) of
        {ok, Header} ->
            Nplurals = nplurals_from_header(Header),
            {ok, St#pst{header = Header, nplurals = Nplurals}};
        {error, _} = Err ->
            Err
    end;
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
-spec build_header(binary()) -> {ok, header_map()} | {error, parse_error()}.
build_header(<<>>) ->
    {ok, empty_header()};
build_header(HeaderText) when is_binary(HeaderText) ->
    Fields = parse_header_fields(HeaderText),
    PluralForms = proplists:get_value(<<"plural-forms">>, Fields, <<>>),
    ContentType = proplists:get_value(<<"content-type">>, Fields, <<>>),
    case field_charset(Fields) of
        {ok, Charset} ->
            {ok, #{
                plural_forms => PluralForms,
                content_type => ContentType,
                charset => Charset,
                raw => HeaderText
            }};
        {error, _} = Err ->
            Err
    end.

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

-spec classify_charset_from_content_type(binary()) ->
    {ok, utf8 | latin1 | us_ascii} | {error, {unsupported_charset, binary()}}.
classify_charset_from_content_type(<<>>) ->
    {ok, utf8};
classify_charset_from_content_type(ContentType) ->
    %% Narrow `chardata() -> binary()` at the boundary so `binary:match/2`
    %% is type-checked.
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
dump_entry({plural, Ctx, Msgid, MsgidPlural, Plurals}) ->
    CtxBin = dump_msgctxt(Ctx),
    MsgidBin = dump_field(<<"msgid">>, Msgid),
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
    PluralIdBin = dump_field(<<"msgid_plural">>, PluralIdSrc),
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
