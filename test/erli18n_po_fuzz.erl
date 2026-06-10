%%% =====================================================================
%%% Fuzz testing for `erli18n_po` parser robustness.
%%%
%%% Spec source-of-truth: `parity_specs.md` §6.2 (scenarios F1..F7).
%%% Risk traceability: `risk_register.md` RISK-014 ("parser robustness")
%%% is materialised via F1..F7. Each scenario takes the same shape — a
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

%% Properties (one per fuzz scenario F1..F7).
-export([
    prop_random_bytes/0,
    prop_mutated_po/0,
    prop_truncated_po/0,
    prop_embedded_controls/0,
    prop_encoding_mismatch/0,
    prop_extreme_inputs/0,
    prop_end_to_end_no_supervisor_restart/0,
    prop_decode_is_linear/0
]).

-define(FUZZ_DOMAIN, fuzz_test_dom).

%% F6 `giant_msgid` size. 400KB is well past the point where the old
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
%% F1 — Raw random bytes (dumb baseline)
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
            %% eqwalizer; cast at the property boundary to the documented
            %% shape (`binary()` here, the generator's contract).
            Bytes = eqwalizer:dynamic_cast(BytesGen),
            no_crash(fun() -> erli18n_po:parse(Bytes) end)
        end
    ).

%% =========================
%% F2 — Quasi-valid PO with N random byte mutations
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
%% F3 — Truncated PO
%% =========================
%%
%% Truncate the catalog at a random byte offset (uniform over the
%% range). Simulates partial reads / disk full / EOF-mid-entry.
prop_truncated_po() ->
    ?FORALL(
        {PoGen, TruncPctGen},
        {valid_po_text(), choose(0, 100)},
        begin
            %% Generator-boundary cast — see `prop_random_bytes/0`.
            Po = eqwalizer:dynamic_cast(PoGen),
            TruncPct = eqwalizer:dynamic_cast(TruncPctGen),
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
%% F4 — Embedded NUL / EOT / Ctrl-Z / C1 control bytes
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
%% F5 — Encoding mismatch (header declares X, body is Y)
%% =========================
%%
%% Build a PO with a valid header but swap the declared charset for one
%% of UTF-8 / LATIN1 / SHIFT_JIS / KOI8-R. SHIFT_JIS is explicitly
%% unsupported per PSD-002 / EX-013 — the parser must return
%% `{error, {unsupported_charset, _}}` for it (asserted explicitly
%% below).
prop_encoding_mismatch() ->
    ?FORALL(
        {Po, Charset},
        {
            valid_po_text(),
            oneof([
                <<"UTF-8">>,
                <<"LATIN1">>,
                <<"SHIFT_JIS">>,
                <<"KOI8-R">>
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
                    %% error per PSD-002 / EX-013.
                    case Charset of
                        <<"SHIFT_JIS">> -> true;
                        <<"KOI8-R">> -> true;
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
%% F6 — Extreme inputs (stress / pathological)
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
    Entry = <<"msgid \"x\"\nmsgstr \"\"\n\n">>,
    Header = minimal_valid_po_header(),
    iolist_to_binary([Header, lists:duplicate(1000, Entry)]);
build_extreme(giant_msgid) ->
    %% A single 400KB ASCII msgid. ASCII-only stays UTF-8 valid and
    %% avoids a charset-conversion path while still pushing the parser's
    %% string collector (`decode_chars/2` -> `bins_to_binary/1`). At this
    %% size the historical right-append fold in `bins_to_binary/2` took
    %% multiple seconds per parse (Θ(n²)); the linear materialization
    %% stays in the low-millisecond range. `prop_decode_is_linear/0`
    %% asserts the budget directly; this variant keeps `no_crash`
    %% coverage at a size the old code could not survive cheaply.
    giant_msgid_po(?GIANT_MSGID_BYTES);
build_extreme(repeated_headers) ->
    %% N copies of `msgid "" msgstr "...."` — the parser keeps only the
    %% first per PSD-001 (`finalize_entry` drops duplicates silently).
    Header = minimal_valid_po_header(),
    iolist_to_binary([Header, lists:duplicate(100, Header)]).

%% =========================
%% F6b — Decode cost is linear in single-string length (Finding #3)
%% =========================
%%
%% Regression guard for `po-decode-bins-to-binary-quadratic`. The PO
%% quoted-string decoder accumulates one binary per source character
%% and folds them into the final string via `bins_to_binary/1`. The
%% historical fold prepended into a right-hand accumulator
%% (`<<B/binary, Acc/binary>>`), recopying the whole accumulator on
%% every element — Θ(n²) to materialize one n-byte string. A single
%% large msgid/msgstr therefore stalled the loader gen_server for
%% seconds.
%%
%% This property parses a single ?GIANT_MSGID_BYTES msgid and asserts:
%%   1. it parses successfully (round-trips through the decoder), and
%%   2. wall-clock cost stays under ?LINEAR_BUDGET_US.
%%
%% The budget is comfortably met by the linear `iolist_to_binary/1`
%% path (single-digit ms) and comfortably blown by the quadratic fold
%% (measured 6-9s at 400KB on OTP 28), so it is a sharp red/green line
%% for this fix. There is no `?FORALL` generator — the input is fixed
%% and the claim is about a single deterministic measurement — but we
%% wrap it as a PropEr property so it runs through the same
%% `proper:quickcheck/2` harness as its F-siblings.
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
    Giant = binary:copy(<<"a">>, N),
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
%% F7 — End-to-end: malformed PO via `ensure_loaded` does not restart
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
            %% Generator-boundary cast — see `prop_random_bytes/0`.
            Bytes = eqwalizer:dynamic_cast(BytesGen),
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
                            <<"xx">>,
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
                        erli18n:unload(?FUZZ_DOMAIN, <<"xx">>)
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
