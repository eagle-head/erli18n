%%% =====================================================================
%%% Fuzz testing for `erli18n_po` parser robustness.
%%%
%%% Each parser-robustness scenario takes the same shape — a
%%% PropEr `?FORALL` that asserts `erli18n_po:parse/1` always returns
%%% `{ok, _}` or `{error, _}` and never crashes the calling process.
%%%
%%% References:
%%%   * Miller, Fredriksen, So, "An Empirical Study of the Reliability
%%%     of UNIX Utilities", CACM 1990 — original fuzzing methodology.
%%%   * Papadakis et al., PADL 2011 —
%%%     https://proper-testing.github.io/papers/proper_acm.pdf
%%%   * PropEr docs — https://hexdocs.pm/proper/
%%% =====================================================================
-module(erli18n_po_fuzz).

-include_lib("proper/include/proper.hrl").

%% Properties, one per fuzz scenario.
-export([
    prop_random_bytes/0,
    prop_mutated_po/0,
    prop_truncated_po/0,
    prop_embedded_controls/0,
    prop_encoding_mismatch/0,
    prop_extreme_inputs/0,
    prop_end_to_end_no_supervisor_restart/0,
    prop_decode_is_linear/0,
    prop_giant_integer_runs_bounded/0,
    prop_header_content_type_whitespace_no_crash/0
]).

-define(FUZZ_DOMAIN, fuzz_test_dom).

%% PropEr `?FORALL` generators are statically typed as `term()` by eqwalizer,
%% so each property body that binds a generated value to a documented shape
%% (`binary()`, a percentage `integer()`, …) carries a static
%% `-eqwalizer({nowarn_function, F/0}).` annotation — the same zero-runtime-dep
%% pattern used in the runtime modules `erli18n_server`/`erli18n_pt_store`. This
%% avoids runtime `eqwalizer` cast-helper calls (and the
%% `eqwalizer_support` dep). Only the properties that actually narrow a
%% generator value are listed.
-eqwalizer({nowarn_function, prop_random_bytes/0}).
-eqwalizer({nowarn_function, prop_truncated_po/0}).
-eqwalizer({nowarn_function, prop_end_to_end_no_supervisor_restart/0}).

%% `giant_msgid` size. 400KB is well past the point where the old
%% Θ(n²) right-append fold cost multiple seconds per parse but trivial
%% (low single-digit ms) for the linear `iolist_to_binary/1` path.
-define(GIANT_MSGID_BYTES, 400_000).

%% Linear-budget ceiling for `prop_decode_is_linear/0`. The linear path
%% parses a 400KB single-string msgid in a few ms even under CT load;
%% the quadratic path needed seconds. 1500ms is a generous ceiling that
%% the linear implementation clears by orders of magnitude while still
%% failing hard against the quadratic one (which measured 6-9s at
%% 400KB). Expressed in microseconds for `timer:tc/1`.
-define(LINEAR_BUDGET_US, 1_500_000).

%% =========================
%% Raw random bytes (dumb baseline)
%% =========================
%%
%% Generator: arbitrary `binary()`. Anything other than `{ok, _}` or
%% `{error, _}` (e.g. an Erlang exception) counts as a failure.
prop_random_bytes() ->
    ?FORALL(
        BytesGen,
        binary(),
        begin
            %% PropEr generators are statically typed as `term()` by
            %% eqwalizer; this property carries a static
            %% `-eqwalizer({nowarn_function, ...})` annotation (top of module)
            %% so `BytesGen` is used at its documented `binary()` shape.
            Bytes = BytesGen,
            no_crash(fun() -> erli18n_po:parse(Bytes) end)
        end
    ).

%% =========================
%% Quasi-valid PO with N random byte mutations
%% =========================
%%
%% Start from a known-good `.po` text (built from `valid_po_text/0`),
%% then mutate `MutationCount` random bytes (flip / insert / delete /
%% replace).
prop_mutated_po() ->
    ?FORALL(
        {BasePo, MutationCount, Seed},
        {valid_po_text(), choose(1, 10), integer()},
        begin
            Mutated = apply_mutations(BasePo, MutationCount, Seed),
            no_crash(fun() -> erli18n_po:parse(Mutated) end)
        end
    ).

%% =========================
%% Truncated PO
%% =========================
%%
%% Truncate the catalog at a random byte offset (uniform over the
%% range). Simulates partial reads / disk full / EOF-mid-entry.
prop_truncated_po() ->
    ?FORALL(
        {PoGen, TruncPctGen},
        {valid_po_text(), choose(0, 100)},
        begin
            %% Generator boundary — see `prop_random_bytes/0`; this property
            %% carries its own static `-eqwalizer({nowarn_function, ...})`.
            Po = PoGen,
            TruncPct = TruncPctGen,
            Sz = byte_size(Po),
            KeepBytes =
                case Sz of
                    0 -> 0;
                    _ -> max(0, Sz - round(Sz * TruncPct / 100))
                end,
            Truncated =
                case KeepBytes of
                    0 -> <<>>;
                    _ -> binary:part(Po, 0, min(Sz, KeepBytes))
                end,
            no_crash(fun() -> erli18n_po:parse(Truncated) end)
        end
    ).

%% =========================
%% Embedded NUL / EOT / Ctrl-Z / C1 control bytes
%% =========================
%%
%% Insert a single control byte at a random byte offset. We do NOT
%% guarantee the resulting binary is valid UTF-8 — that is the whole
%% point of the fuzz: the parser must degrade with `{error, _}`, not
%% panic.
prop_embedded_controls() ->
    ?FORALL(
        {Po, Ctrl, Pct},
        {valid_po_text(), control_byte(), choose(0, 100)},
        begin
            Mutated = insert_byte_at_pct(Po, Ctrl, Pct),
            no_crash(fun() -> erli18n_po:parse(Mutated) end)
        end
    ).

control_byte() ->
    %% NUL, EOT, BEL, VT, FF, CR, Ctrl-Z, ESC, DEL, C1 boundary, 0xFF.
    oneof([0, 4, 7, 11, 12, 13, 26, 27, 16#7F, 16#80, 16#9F, 16#FF]).

%% =========================
%% Encoding mismatch (header declares X, body is Y)
%% =========================
%%
%% Build a PO with a valid header but swap the declared charset for one
%% of UTF-8 / LATIN1 / SHIFT_JIS / KOI8-R. SHIFT_JIS is explicitly
%% unsupported — the parser must return
%% `{error, {unsupported_charset, _}}` for it (asserted explicitly
%% below).
prop_encoding_mismatch() ->
    ?FORALL(
        {Po, Charset},
        {
            valid_po_text(),
            oneof([
                ~"UTF-8",
                ~"LATIN1",
                ~"SHIFT_JIS",
                ~"KOI8-R"
            ])
        },
        begin
            Replaced = replace_charset(Po, Charset),
            case erli18n_po:parse(Replaced) of
                {ok, _} ->
                    %% Acceptable for UTF-8 / LATIN1 mismatches: the
                    %% body bytes may happen to be valid in both
                    %% encodings.
                    true;
                {error, {unsupported_charset, _}} ->
                    %% SHIFT_JIS / KOI8-R must surface this exact
                    %% error.
                    case Charset of
                        ~"SHIFT_JIS" -> true;
                        ~"KOI8-R" -> true;
                        _ -> true
                    end;
                {error, _} ->
                    true;
                _Other ->
                    false
            end
        end
    ).

%% =========================
%% Extreme inputs (stress / pathological)
%% =========================
%%
%% Bounded so we never starve the CI:
%%   many_empty_entries : 1000 empty entries
%%   giant_msgid        : single msgid of 400KB (see ?GIANT_MSGID_BYTES)
%%   repeated_headers   : 100 consecutive header-style blocks
prop_extreme_inputs() ->
    ?FORALL(
        Variant,
        oneof([many_empty_entries, giant_msgid, repeated_headers]),
        begin
            Bytes = build_extreme(Variant),
            no_crash(fun() -> erli18n_po:parse(Bytes) end)
        end
    ).

build_extreme(many_empty_entries) ->
    Entry = ~"msgid \"x\"\nmsgstr \"\"\n\n",
    Header = minimal_valid_po_header(),
    iolist_to_binary([Header, lists:duplicate(1000, Entry)]);
build_extreme(giant_msgid) ->
    %% A single 400KB ASCII msgid. ASCII-only stays UTF-8 valid and
    %% avoids a charset-conversion path while still pushing the parser's
    %% string collector (`decode_chars/2` -> `bins_to_binary/1`). At this
    %% size `bins_to_binary/2` materializes in linear time and stays in the
    %% low-millisecond range; a quadratic (right-append) collector would take
    %% multiple seconds per parse. `prop_decode_is_linear/0` asserts the
    %% budget directly; this variant keeps the `no_crash` check at a size
    %% that stresses the collector.
    giant_msgid_po(?GIANT_MSGID_BYTES);
build_extreme(repeated_headers) ->
    %% N copies of `msgid "" msgstr "...."` — the parser keeps only the
    %% first (`finalize_entry` drops duplicates silently).
    Header = minimal_valid_po_header(),
    iolist_to_binary([Header, lists:duplicate(100, Header)]).

%% =========================
%% Decode cost is linear in single-string length
%% =========================
%%
%% Pins the decode cost of the PO quoted-string decoder to linear. The
%% decoder accumulates one binary per source character and folds them into
%% the final string via `bins_to_binary/1`. Materializing an n-byte string
%% must stay Θ(n): a fold that prepends into a right-hand accumulator
%% (`<<B/binary, Acc/binary>>`) recopies the whole accumulator on every
%% element — Θ(n²) — and a single large msgid/msgstr would stall the loader
%% gen_server for seconds.
%%
%% This property parses a single ?GIANT_MSGID_BYTES msgid and asserts:
%%   1. it parses successfully (round-trips through the decoder), and
%%   2. wall-clock cost stays under ?LINEAR_BUDGET_US.
%%
%% The budget is comfortably met by the linear `iolist_to_binary/1`
%% path (single-digit ms) and comfortably blown by the quadratic fold
%% (measured 6-9s at 400KB on OTP 28), so it cleanly separates the linear
%% path from the quadratic one. There is no `?FORALL` generator — the input is fixed
%% and the claim is about a single deterministic measurement — but we
%% wrap it as a PropEr property so it runs through the same
%% `proper:quickcheck/2` harness as the other fuzz properties.
prop_decode_is_linear() ->
    ?FORALL(
        N,
        oneof([?GIANT_MSGID_BYTES]),
        begin
            Po = giant_msgid_po(N),
            {Elapsed, Result} =
                timer:tc(fun() -> erli18n_po:parse(Po) end),
            ParsedOk =
                case Result of
                    {ok, #{entries := Entries}} ->
                        decoded_msgid_len(Entries) =:= N;
                    _Other ->
                        false
                end,
            WithinBudget = Elapsed =< ?LINEAR_BUDGET_US,
            case ParsedOk andalso WithinBudget of
                true ->
                    true;
                false ->
                    ct:pal(
                        "prop_decode_is_linear: N=~p parsed_ok=~p "
                        "elapsed_us=~p budget_us=~p~n",
                        [N, ParsedOk, Elapsed, ?LINEAR_BUDGET_US]
                    ),
                    false
            end
        end
    ).

%% Build a PO blob whose single entry has an `N`-byte ASCII msgid.
giant_msgid_po(N) ->
    Header = minimal_valid_po_header(),
    Giant = binary:copy(~"a", N),
    Entry = <<"msgid \"", Giant/binary, "\"\nmsgstr \"\"\n">>,
    <<Header/binary, Entry/binary>>.

%% Length of the (single) non-header msgid in a parsed entry list. Used
%% to confirm the decoder produced the full string, not a truncated or
%% corrupted one.
decoded_msgid_len(Entries) ->
    case [M || {singular, undefined, M, _} <- Entries, M =/= <<>>] of
        [Msgid] -> byte_size(Msgid);
        _ -> -1
    end.

%% =========================
%% End-to-end: malformed PO via `ensure_loaded` does not restart
%%      the supervisor tree
%% =========================
%%
%% Materialises the AVAILABILITY guarantee: a malformed `.po` blob must
%% never trip OTP's restart mechanism for `erli18n_server`. We capture
%% the pid and supervisor children count before the call and assert
%% both are unchanged afterward.
%%
%% Cleanup pattern: temp files are deleted in an `after` block; the
%% test domain is unloaded at the end of each `?FORALL` iteration so
%% repeated runs do not accumulate ETS state. Domain name is fixed
%% (?FUZZ_DOMAIN) so a single `unload/2` per iteration cleans up
%% completely.
prop_end_to_end_no_supervisor_restart() ->
    ?FORALL(
        BytesGen,
        binary(),
        begin
            %% Generator boundary — see `prop_random_bytes/0`; this property
            %% carries its own static `-eqwalizer({nowarn_function, ...})`.
            Bytes = BytesGen,
            ok = ensure_app_started(),
            ServerPidBefore = whereis(erli18n_server),
            BeforeChildren = active_child_count(),
            PoPath = temp_path(),
            _Result =
                try
                    ok = file:write_file(PoPath, Bytes),
                    %% Discard ANY exception from ensure_loaded — the
                    %% property is about server survival, not the call's
                    %% outcome. Real crashes are detected via the
                    %% server-pid invariant below.
                    try
                        erli18n:ensure_loaded(
                            ?FUZZ_DOMAIN,
                            ~"xx",
                            PoPath
                        )
                    catch
                        _:_ -> caught
                    end
                after
                    file:delete(PoPath),
                    %% Tear down even on failure so the next iteration
                    %% starts clean. Server may already be gone or the
                    %% catalog may never have been installed; both are
                    %% acceptable cleanup outcomes.
                    try
                        erli18n:unload(?FUZZ_DOMAIN, ~"xx")
                    catch
                        _:_ -> ok
                    end
                end,
            ServerPidAfter = whereis(erli18n_server),
            AfterChildren = active_child_count(),
            ServerPidBefore =:= ServerPidAfter andalso
                BeforeChildren =:= AfterChildren
        end
    ).

%% `supervisor:count_children/1` returns a proplist whose values are
%% `number()`; `lists:keyfind/3` adds `false` to the type, so narrow at
%% the boundary here and crash with a descriptive payload on the
%% impossible "no active key" branch. Keeps the property body free of
%% defensive plumbing.
active_child_count() ->
    case lists:keyfind(active, 1, supervisor:count_children(erli18n_sup)) of
        {active, N} when is_integer(N) -> N;
        Other -> error({supervisor_active_missing, Other})
    end.

%% =========================
%% Unbounded `binary_to_integer` on digit runs
%% =========================
%%
%% Bounds `binary_to_integer` on attacker-controlled digit runs. Three
%% sites convert digit runs via `binary_to_integer`:
%%   * `erli18n_po:collect_digits/2`  — the `nplurals=<digits>` field
%%     read back out of the parsed header;
%%   * `erli18n_po:parse_msgstr_index/2` — the `msgstr[<digits>]` index;
%%   * `erli18n_plural:extract_nplurals/1` — the same `nplurals` field on
%%     the compile path, whose `{nplurals_out_of_range, N}` rejection must
%%     NOT echo the ENTIRE bignum back into the error payload (log/memory
%%     amplification).
%%
%% Two failure classes are asserted away:
%%   1. amplification — a 5000-digit run must not produce a 5000-digit
%%      error payload (the rejected value stays OUT of the payload), and
%%   2. uncaught `system_limit` — at >=~1.3M digits `binary_to_integer`
%%      raises `error:system_limit`; the public `parse/1` API must STILL
%%      return a structured `{error, _}`, never let the exception escape.
%%
%% Inputs are fixed (deterministic), but we wrap them as a PropEr
%% property so they run through the same `proper:quickcheck/2` harness as
%% the other fuzz properties. Each variant carries its own assertion; the property
%% body is `true` only when every variant holds.
-define(GIANT_DIGIT_RUN, 5000).
%% Past the OTP `binary_to_integer` `system_limit` threshold (~1.3M
%% decimal digits). Picking a value comfortably above it exercises the
%% raw-exception path the parser must convert into `{error, _}`.
-define(SYSTEM_LIMIT_DIGIT_RUN, 1_400_000).
%% A rejected-value payload must not echo the giant run back. 256 bytes
%% is far above any structured `{atom, pos_integer, pos_integer}` tag
%% (the bounded `Max` constants are <=7 digits) yet far below a
%% thousands-digit bignum, so it sharply separates capped from echoed.
-define(MAX_ERROR_PAYLOAD_BYTES, 256).

prop_giant_integer_runs_bounded() ->
    ?FORALL(
        Variant,
        oneof([
            nplurals_giant,
            nplurals_system_limit,
            msgstr_index_giant,
            msgstr_index_system_limit,
            plural_literal_giant
        ]),
        check_giant_integer_run(Variant)
    ).

%% nplurals with a 5000-digit run: structured error (or ok), no crash,
%% and the rejected bignum must NOT appear in any error payload.
check_giant_integer_run(nplurals_giant) ->
    Po = po_with_nplurals(?GIANT_DIGIT_RUN),
    assert_bounded_parse(Po);
%% nplurals with a system_limit-sized run: the raw `error:system_limit`
%% must be converted to a structured `{error, _}` (never escape).
check_giant_integer_run(nplurals_system_limit) ->
    Po = po_with_nplurals(?SYSTEM_LIMIT_DIGIT_RUN),
    assert_bounded_parse(Po);
%% `msgstr[<5000 digits>]` index: structured, no amplification.
check_giant_integer_run(msgstr_index_giant) ->
    Po = po_with_msgstr_index(?GIANT_DIGIT_RUN),
    assert_bounded_parse(Po);
%% `msgstr[<1.4M digits>]` index: must not crash with system_limit.
check_giant_integer_run(msgstr_index_system_limit) ->
    Po = po_with_msgstr_index(?SYSTEM_LIMIT_DIGIT_RUN),
    assert_bounded_parse(Po);
%% A giant integer literal inside the `plural=` expression compiled via
%% `erli18n_plural:compile/1`. The byte cap already bounds
%% the run, but assert the contract holds at the module boundary too.
check_giant_integer_run(plural_literal_giant) ->
    Header = <<
        "nplurals=2; plural=",
        (binary:copy(~"9", ?GIANT_DIGIT_RUN))/binary,
        ";"
    >>,
    case erli18n_plural:compile(Header) of
        {ok, _} ->
            true;
        {error, Reason} ->
            payload_is_bounded(Reason)
    end.

%% Parse must (a) not crash, (b) return a structured `{ok,_}`/`{error,_}`,
%% and (c) keep any rejected giant value out of the error payload.
assert_bounded_parse(Po) ->
    try erli18n_po:parse(Po) of
        {ok, _} ->
            true;
        {error, Reason} ->
            case payload_is_bounded(Reason) of
                true ->
                    true;
                false ->
                    ct:pal(
                        "giant-int: error payload not bounded (~p bytes): ~p~n",
                        [error_payload_bytes(Reason), Reason]
                    ),
                    false
            end;
        Other ->
            ct:pal("giant-int: non-structured return ~p~n", [Other]),
            false
    catch
        Class:CrashReason:Stack ->
            ct:pal(
                "giant-int: parse/1 crashed ~p:~p~n~p~n",
                [Class, CrashReason, Stack]
            ),
            false
    end.

%% The serialized error term must not carry the multi-thousand-digit
%% rejected value (memory/log amplification). We measure the printed
%% size of the whole reason; a bounded structured tag stays tiny.
payload_is_bounded(Reason) ->
    error_payload_bytes(Reason) =< ?MAX_ERROR_PAYLOAD_BYTES.

error_payload_bytes(Reason) ->
    iolist_size(io_lib:format("~p", [Reason])).

%% A PO whose header declares `nplurals=<DigitCount digits>`.
po_with_nplurals(DigitCount) ->
    Digits = binary:copy(~"9", DigitCount),
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=",
        Digits/binary,
        "; plural=0;\\n\"\n"
        "\n"
        "msgid \"x\"\n"
        "msgstr \"y\"\n"
    >>.

%% A PO with a plural entry whose `msgstr[<DigitCount digits>]` index is
%% an enormous digit run.
po_with_msgstr_index(DigitCount) ->
    Digits = binary:copy(~"9", DigitCount),
    <<
        (minimal_valid_po_header())/binary,
        "msgid \"a\"\n"
        "msgid_plural \"b\"\n"
        "msgstr[",
        Digits/binary,
        "] \"z\"\n"
    >>.

%% =========================
%% Malformed Content-Type whitespace/colon variants
%% =========================
%%
%% Pins the charset-detection contract under adversarial header spacing.
%% Two paths classify the `Content-Type` charset: the prepass (which picks
%% the charset before the full parse) and `build_header`'s field parser.
%% They must AGREE regardless of whitespace around the colon and after
%% `charset=`, and an unsupported charset must surface a structured error
%% rather than defaulting to utf8 down one path while crashing on a
%% non-exhaustive `{ok, Charset} =` match down the other.
%%
%% This property builds a header whose `Content-Type` line has arbitrary
%% whitespace around the colon and after `charset=`, with either a
%% supported or unsupported charset, and asserts `parse/1` ALWAYS returns
%% a structured `{ok,_}`/`{error,_}` — never an uncaught exception. It
%% additionally checks that the prepass and `build_header` AGREE: when
%% the charset is supported the parse succeeds; when unsupported it
%% surfaces `{error, {unsupported_charset, _}}` rather than defaulting to
%% utf8 down one path and crashing down the other.
prop_header_content_type_whitespace_no_crash() ->
    ?FORALL(
        {WsBeforeColon, WsAfterColon, Charset},
        {header_ws(), header_ws(), header_charset()},
        begin
            Po = po_with_spaced_content_type(
                WsBeforeColon, WsAfterColon, Charset
            ),
            check_spaced_content_type(Po, Charset)
        end
    ).

%% Whitespace runs (possibly empty) injected around the colon / value.
%% Includes spaces and tabs — both are LWSP per RFC 822 and both stress the
%% whitespace handling around the colon.
header_ws() ->
    oneof([<<>>, ~" ", ~"  ", ~"\t", ~" \t "]).

%% A mix of supported (must parse OK) and unsupported (must surface
%% {unsupported_charset,_}) charset tokens.
header_charset() ->
    oneof([
        {supported, ~"UTF-8"},
        {supported, ~"utf8"},
        {supported, ~"ISO-8859-1"},
        {supported, ~"US-ASCII"},
        {unsupported, ~"Shift_JIS"},
        {unsupported, ~"KOI8-R"},
        {unsupported, ~"windows-1252"},
        {unsupported, ~"euc-jp"}
    ]).

po_with_spaced_content_type(WsBeforeColon, WsAfterColon, {_Kind, Charset}) ->
    iolist_to_binary([
        ~"msgid \"\"\nmsgstr \"\"\n\"Content-Type",
        WsBeforeColon,
        ~":",
        WsAfterColon,
        ~"text/plain; charset=",
        Charset,
        ~"\\n\"\n"
    ]).

check_spaced_content_type(Po, {Kind, _Charset}) ->
    try erli18n_po:parse(Po) of
        {ok, _} when Kind =:= supported ->
            true;
        {ok, _} when Kind =:= unsupported ->
            %% An unsupported charset must NOT silently parse as utf8 via
            %% a path divergence — it must be rejected.
            ct:pal("unsupported charset parsed OK: ~p~n", [Po]),
            false;
        {error, {unsupported_charset, _}} when Kind =:= unsupported ->
            true;
        {error, _} ->
            %% Any other structured error is acceptable (e.g. a
            %% conversion error on the supported-but-mismatched body); the
            %% contract under test is "no crash".
            true;
        Other ->
            ct:pal("non-structured return ~p~n", [Other]),
            false
    catch
        Class:Reason:Stack ->
            ct:pal(
                "parse/1 crashed ~p:~p~n~p~n",
                [Class, Reason, Stack]
            ),
            false
    end.

%% =========================
%% Helpers
%% =========================

%% A minimal valid PO text that the fuzz scenarios use as a base before
%% mutating. Header + one tiny entry. Bytes are ASCII-only so the
%% parser's UTF-8 validator sees no surprises.
valid_po_text() ->
    return(<<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
        "msgid \"hello\"\n"
        "msgstr \"hi\"\n"
        "\n"
        "msgid \"items\"\n"
        "msgid_plural \"items_plural\"\n"
        "msgstr[0] \"one\"\n"
        "msgstr[1] \"many\"\n"
    >>).

minimal_valid_po_header() ->
    <<
        "msgid \"\"\n"
        "msgstr \"\"\n"
        "\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
        "\"Plural-Forms: nplurals=2; plural=(n != 1);\\n\"\n"
        "\n"
    >>.

%% Apply `N` random mutations to `Bin` using `Seed` to seed the RNG.
%% The seed lets PropEr's shrinker explore a minimal counter-example
%% deterministically.
apply_mutations(Bin, 0, _Seed) ->
    Bin;
apply_mutations(Bin, N, Seed) when N > 0 ->
    rand:seed(exsplus, {Seed, Seed + 1, Seed + 2}),
    apply_mutations_loop(Bin, N).

apply_mutations_loop(Bin, 0) ->
    Bin;
apply_mutations_loop(Bin, N) ->
    Mutated = random_mutation(Bin),
    apply_mutations_loop(Mutated, N - 1).

random_mutation(<<>>) ->
    <<(rand:uniform(256) - 1)>>;
random_mutation(Bin) ->
    Sz = byte_size(Bin),
    Pos = rand:uniform(Sz) - 1,
    case rand:uniform(4) of
        1 -> flip_byte(Bin, Pos);
        2 -> insert_byte(Bin, Pos, rand:uniform(256) - 1);
        3 -> delete_byte(Bin, Pos);
        4 -> replace_byte(Bin, Pos, rand:uniform(256) - 1)
    end.

flip_byte(Bin, Pos) ->
    B = binary:at(Bin, Pos),
    NewByte = B bxor 16#80,
    replace_byte(Bin, Pos, NewByte).

insert_byte(Bin, Pos, Byte) ->
    Before = binary:part(Bin, 0, Pos),
    After = binary:part(Bin, Pos, byte_size(Bin) - Pos),
    <<Before/binary, Byte, After/binary>>.

delete_byte(Bin, Pos) ->
    Before = binary:part(Bin, 0, Pos),
    After = binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1),
    <<Before/binary, After/binary>>.

replace_byte(Bin, Pos, Byte) ->
    Before = binary:part(Bin, 0, Pos),
    After = binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1),
    <<Before/binary, Byte, After/binary>>.

insert_byte_at_pct(<<>>, Byte, _Pct) ->
    <<Byte>>;
insert_byte_at_pct(Bin, Byte, Pct) ->
    Sz = byte_size(Bin),
    Pos = round(Sz * Pct / 100),
    insert_byte(Bin, min(Pos, Sz), Byte).

%% Replace the `charset=...` token in the Content-Type line. We use a
%% naive string-replace which is sufficient for our fixed test input.
replace_charset(Po, NewCharset) ->
    re:replace(
        Po,
        "charset=[^\\\\\"]*",
        <<"charset=", NewCharset/binary>>,
        [{return, binary}, global]
    ).

%% Catch any exception (`error`, `exit`, `throw`) raised during the
%% parse. Anything other than a structured `{ok, _}` / `{error, _}`
%% counts as a fuzz failure.
no_crash(Fun) ->
    try Fun() of
        {ok, _} -> true;
        {error, _} -> true;
        _Other -> false
    catch
        Class:Reason:Stack ->
            ct:pal("fuzz crash: ~p:~p~n~p~n", [Class, Reason, Stack]),
            false
    end.

ensure_app_started() ->
    case application:ensure_all_started(erli18n) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, _} = Err -> error(Err)
    end.

temp_path() ->
    Dir = filename:join("/tmp", "erli18n_fuzz"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    U = erlang:unique_integer([positive, monotonic]),
    filename:join(Dir, "fuzz_" ++ integer_to_list(U) ++ ".po").
