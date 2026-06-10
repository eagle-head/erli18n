-module(erli18n_server).

-behaviour(gen_server).

-include("erli18n.hrl").
-include_lib("kernel/include/logger.hrl").

%% Write API (serialized via gen_server, only owner writes to protected ETS).
-export([
    start_link/0,
    insert_singular/5,
    insert_plural/5,
    insert_catalog/3,
    unload/2
]).

%% Read API (direct ETS lookup from caller process — lock-free hot path,
%% per RISK-012 anti-bottleneck pattern).
-export([
    lookup_singular/4,
    lookup_plural/5,
    lookup_header/2,
    lookup_plural_form/5
]).

%% Observability (read-only scan from caller process).
-export([
    memory_info/0,
    loaded_catalogs/0,
    which_keys/2
]).

%% Load orchestration: parse .po + compile plural + validate vs CLDR +
%% insert atomically. Per BR-MIGRAR-022/029 and RISK-012, this is a
%% serialized write path; idempotency makes the second call cheap.
-export([
    ensure_loaded/3,
    ensure_loaded/4,
    reload/3,
    reload/4,
    default_po_path/3
]).

%% gen_server callbacks.
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-type domain() :: atom().
-type locale() :: binary().
-type context() :: undefined | binary().
-type msgid() :: binary().
-type translation() :: binary().
-type plural_index() :: non_neg_integer().
-type plural_entries() :: [{plural_index(), translation()}].
-type singular_entry() :: {singular, context(), msgid(), translation()}.
-type plural_entry() :: {plural, context(), msgid(), plural_entries()}.
-type catalog_entry() :: singular_entry() | plural_entry().

%% Load orchestration types (Parte 5).
-type opts() :: #{include_fuzzy => boolean()}.
%% `{ok, NewlyLoaded :: pos_integer()}`: number of entries inserted on a
%% real load (parsed + compiled + installed).
%% `{ok, already}`: idempotent fast-path, the catalog was already loaded.
%% `{error, ensure_error()}`: structured error; ETS untouched.
-type ensure_result() ::
    {ok, NewlyLoaded :: non_neg_integer()}
    | {ok, already}
    | {error, ensure_error()}.
-type ensure_error() ::
    erli18n_po:parse_error()
    | {plural_compile_error, erli18n_plural:compile_error()}
    | {file_error, file:posix() | badarg | terminated | system_limit}
    | {load_failed, term()}.
-type divergence_info() ::
    none
    | {plural_divergence, binary(), binary()}.
-type header_state() :: #{
    plural := erli18n_plural:plural_compiled() | fallback,
    plural_raw := binary(),
    po_path := file:filename(),
    loaded_at := integer(),
    divergence := divergence_info(),
    fuzzy_included := boolean(),
    num_entries := non_neg_integer()
}.

-export_type([
    domain/0,
    locale/0,
    context/0,
    msgid/0,
    translation/0,
    plural_index/0,
    plural_entries/0,
    singular_entry/0,
    plural_entry/0,
    catalog_entry/0,
    opts/0,
    ensure_result/0,
    ensure_error/0,
    divergence_info/0,
    header_state/0
]).

%% =========================
%% Public API
%% =========================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec insert_singular(domain(), locale(), context(), msgid(), translation()) -> ok.
insert_singular(Domain, Locale, Context, Msgid, Translation) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_binary(Translation)
->
    %% `gen_server:call/2` is typed as `term()`. We pattern-match `ok` so
    %% the public contract is enforced: the matching `handle_call/3`
    %% clause is the only writer of this reply tuple and always returns
    %% `{reply, ok, State}`, so any other shape is a contract break and
    %% should crash with badmatch.
    ok = gen_server:call(
        ?MODULE,
        {insert_singular, Domain, Locale, Context, Msgid, Translation}
    ).

-spec insert_plural(domain(), locale(), context(), msgid(), plural_entries()) -> ok.
insert_plural(Domain, Locale, Context, Msgid, Entries) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_list(Entries)
->
    ok = gen_server:call(
        ?MODULE,
        {insert_plural, Domain, Locale, Context, Msgid, Entries}
    ).

-spec insert_catalog(domain(), locale(), [catalog_entry()]) -> ok.
insert_catalog(Domain, Locale, Entries) when
    is_atom(Domain), is_binary(Locale), is_list(Entries)
->
    ok = gen_server:call(?MODULE, {insert_catalog, Domain, Locale, Entries}).

-spec unload(domain(), locale()) -> ok.
unload(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    ok = gen_server:call(?MODULE, {unload, Domain, Locale}).

-spec lookup_singular(domain(), locale(), context(), msgid()) ->
    {ok, translation()} | undefined.
lookup_singular(Domain, Locale, Context, Msgid) ->
    case ets:lookup(?ETS_TABLE, ?SINGULAR_KEY(Domain, Locale, Context, Msgid)) of
        [{_, Translation}] -> {ok, Translation};
        [] -> undefined
    end.

-spec lookup_plural(domain(), locale(), context(), msgid(), plural_index()) ->
    {ok, translation()} | undefined.
lookup_plural(Domain, Locale, Context, Msgid, Index) ->
    case ets:lookup(?ETS_TABLE, ?PLURAL_KEY(Domain, Locale, Context, Msgid, Index)) of
        [{_, Translation}] -> {ok, Translation};
        [] -> undefined
    end.

%% Read-only header lookup. ETS direct from caller process — lock-free
%% hot path, mirrors lookup_singular/lookup_plural shape.
-spec lookup_header(domain(), locale()) -> {ok, header_state()} | undefined.
lookup_header(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    case ets:lookup(?ETS_TABLE, ?HEADER_KEY(Domain, Locale)) of
        [{_, HeaderState}] -> {ok, HeaderState};
        [] -> undefined
    end.

%% Plural-aware lookup: looks up the header, evaluates the compiled plural
%% rule against N, then issues a plural lookup at the computed form index.
%% Returns the translation if present, or `undefined` (caller is
%% responsible for msgid_plural fallback per PSD-003).
%%
%% Hot path: 1 ETS lookup for header + 1 ETS lookup for the entry, no
%% gen_server roundtrip. Fallback rule (header missing entirely) uses the
%% C/Germanic default `N == 1 -> form 0; else form 1`.
-spec lookup_plural_form(
    domain(),
    locale(),
    context(),
    msgid(),
    integer()
) ->
    {ok, translation()} | undefined.
lookup_plural_form(Domain, Locale, Context, Msgid, N) when
    is_atom(Domain),
    is_binary(Locale),
    (Context =:= undefined orelse is_binary(Context)),
    is_binary(Msgid),
    is_integer(N)
->
    case lookup_header(Domain, Locale) of
        {ok, #{plural := fallback}} ->
            Index = fallback_form_index(N),
            lookup_plural(Domain, Locale, Context, Msgid, Index);
        {ok, #{plural := Compiled}} ->
            %% Boundary guard (finding #1, plural-eval-throws-per-lookup-
            %% dos, Layer 4). `evaluate/2` is now total — it clamps
            %% malformed rules instead of raising — so this `try` never
            %% fires in practice. It is belt-and-suspenders: should a
            %% future regression reintroduce a throw on this per-request
            %% hot path, we degrade to the default Germanic form index
            %% rather than crash the calling request process.
            Index =
                try
                    erli18n_plural:evaluate(Compiled, N)
                catch
                    error:_ -> fallback_form_index(N)
                end,
            lookup_plural(Domain, Locale, Context, Msgid, Index);
        undefined ->
            undefined
    end.

-spec memory_info() ->
    #{
        ets_bytes := non_neg_integer(),
        num_catalogs := non_neg_integer(),
        num_keys := non_neg_integer()
    }.
memory_info() ->
    %% `ets:info/2` returns `term() | undefined` (eqwalizer view); the
    %% `undefined` only happens when the table doesn't exist. The server
    %% creates the table in `init/1` and never deletes it, so reaching
    %% `undefined` here means the gen_server is dead — at which point
    %% crashing with a descriptive payload is the right answer.
    Words = ets_info_integer(memory),
    Bytes = Words * erlang:system_info(wordsize),
    NumKeys = ets_info_integer(size),
    %% Finding #7: O(1) read of the authoritative side index instead of an
    %% O(total_rows) `ets:tab2list/1' + per-row `sets:add_element/2' scan
    %% on every call (which made N loads O(N^2) and briefly doubled peak
    %% memory by copying the whole table onto the server heap).
    NumCatalogs = index_size(),
    #{
        ets_bytes => Bytes,
        num_catalogs => NumCatalogs,
        num_keys => NumKeys
    }.

%% Narrow `ets:info(?ETS_TABLE, Key)` to `non_neg_integer()`. The `memory`
%% and `size` keys are both documented to return `non_neg_integer()` when
%% the table exists. Any other shape is a contract violation worth crashing
%% on.
-spec ets_info_integer(memory | size) -> non_neg_integer().
ets_info_integer(Key) ->
    case ets:info(?ETS_TABLE, Key) of
        N when is_integer(N), N >= 0 -> N;
        Other -> error({ets_info_invalid, {?ETS_TABLE, Key, Other, expected, non_neg_integer}})
    end.

-spec loaded_catalogs() -> [{domain(), locale(), non_neg_integer()}].
loaded_catalogs() ->
    %% Both `ets:foldl/3` and `lists:foldl/3` are specced as returning
    %% `term()` in OTP — eqwalizer can't carry the accumulator type
    %% through. We compute counts by manual recursion over an
    %% `ets:tab2list/1` snapshot, which preserves the precise
    %% accumulator type. Observability path, not a hot path.
    Counts = build_counts(ets:tab2list(?ETS_TABLE), #{}),
    maps:fold(
        fun({D, L}, N, Acc) -> [{D, L, N} | Acc] end,
        [],
        Counts
    ).

-spec build_counts(
    [tuple()],
    #{{domain(), locale()} => non_neg_integer()}
) -> #{{domain(), locale()} => non_neg_integer()}.
build_counts([], Acc) ->
    Acc;
build_counts([Obj | Rest], Acc) ->
    build_counts(Rest, count_per_catalog(Obj, Acc)).

%% Enumerate the keys (singular and plural) currently loaded for a given
%% (Domain, Locale). Plural entries are deduplicated — a single plural
%% msgid with N forms is reported once, not N times.
%%
%% Paridade com `gettexter:which_keys/2`. ETS scan in the caller process,
%% no gen_server roundtrip.
-spec which_keys(domain(), locale()) ->
    [{singular, context(), msgid()} | {plural, context(), msgid()}].
which_keys(Domain, Locale) when is_atom(Domain), is_binary(Locale) ->
    %% Encapsulate the `ets:foldl/3` call in a tightly-typed helper so
    %% the resulting accumulator carries the precise shape we built
    %% (rather than the OTP-specced `term()`).
    #{singulars := Sings, plurals := PluralSet} =
        fold_keys(Domain, Locale),
    Plurals = plural_set_to_list(PluralSet),
    %% Sorted output for determinism in tests; not strictly required.
    %% Concat into the explicit union list type so eqwalizer carries the
    %% element type all the way through `lists:sort/1`.
    sort_keys(Sings, Plurals).

-type key_entry() ::
    {singular, context(), msgid()} | {plural, context(), msgid()}.

-spec sort_keys(
    [{singular, context(), msgid()}],
    [{plural, context(), msgid()}]
) -> [key_entry()].
sort_keys(Sings, Plurals) ->
    %% `lists:sort/1,2` is specced `[T] -> [T]` but eqwalizer's solver
    %% drops the T binding when T is a union of tuple shapes. A
    %% hand-rolled merge sort over the union type carries the precise
    %% type through and is acceptable here because `which_keys/2` is an
    %% observability call, not a hot path.
    Combined = combine_keys(Sings, Plurals),
    merge_sort(Combined).

-spec merge_sort([key_entry()]) -> [key_entry()].
merge_sort([]) ->
    [];
merge_sort([X]) ->
    [X];
merge_sort(List) ->
    {Left, Right} = split_in_half(List, [], []),
    merge_sorted(merge_sort(Left), merge_sort(Right)).

-spec split_in_half(
    [key_entry()],
    [key_entry()],
    [key_entry()]
) -> {[key_entry()], [key_entry()]}.
split_in_half([], L, R) -> {L, R};
split_in_half([X], L, R) -> {[X | L], R};
split_in_half([X, Y | Rest], L, R) -> split_in_half(Rest, [X | L], [Y | R]).

-spec merge_sorted([key_entry()], [key_entry()]) -> [key_entry()].
merge_sorted([], B) ->
    B;
merge_sorted(A, []) ->
    A;
merge_sorted([Ah | At], [Bh | Bt]) ->
    case Ah =< Bh of
        true -> [Ah | merge_sorted(At, [Bh | Bt])];
        false -> [Bh | merge_sorted([Ah | At], Bt)]
    end.

-spec combine_keys(
    [{singular, context(), msgid()}],
    [{plural, context(), msgid()}]
) -> [{singular, context(), msgid()} | {plural, context(), msgid()}].
combine_keys([], Plurals) ->
    Plurals;
combine_keys([S | Rest], Plurals) ->
    [S | combine_keys(Rest, Plurals)].

%% Materialize the plural set into a precisely-typed list. `sets:to_list/1`
%% has a generic spec that eqwalizer can fail to instantiate when the
%% caller uses the result in heterogeneous contexts (here, mixed singular
%% and plural tuples flowing into `lists:sort/1`). Doing the conversion in
%% a helper with an explicit spec is the idiomatic narrow.
-spec plural_set_to_list(sets:set({context(), msgid()})) ->
    [{plural, context(), msgid()}].
plural_set_to_list(Set) ->
    sets:fold(
        fun({C, M}, Acc) -> [{plural, C, M} | Acc] end,
        [],
        Set
    ).

-type key_acc() ::
    #{
        singulars := [{singular, context(), msgid()}],
        plurals := sets:set({context(), msgid()})
    }.

-spec fold_keys(domain(), locale()) -> key_acc().
fold_keys(Domain, Locale) ->
    %% Manual recursion over an `ets:tab2list/1` snapshot. Same reason
    %% as `loaded_catalogs/0`: both `ets:foldl/3` and `lists:foldl/3`
    %% are typed `term()` and strip the accumulator's precise shape.
    Acc0 = #{
        singulars => [],
        plurals => sets:new([{version, 2}])
    },
    build_keys(ets:tab2list(?ETS_TABLE), Domain, Locale, Acc0).

-spec build_keys([tuple()], domain(), locale(), key_acc()) -> key_acc().
build_keys([], _D, _L, Acc) ->
    Acc;
build_keys([Obj | Rest], Domain, Locale, Acc) ->
    build_keys(Rest, Domain, Locale, collect_key(Domain, Locale, Obj, Acc)).

%% =========================
%% Load orchestration (Parte 5)
%% =========================

%% Idempotent load. If the (Domain, Locale) catalog is already loaded,
%% returns `{ok, already}` without touching disk (RISK-012 mitigation 2).
%% Otherwise performs the full pipeline: read file, parse, compile plural
%% rule, validate against CLDR (warning only, never blocks), install in
%% ETS atomically.
-spec ensure_loaded(domain(), locale(), file:filename()) -> ensure_result().
ensure_loaded(Domain, Locale, PoPath) ->
    ensure_loaded(Domain, Locale, PoPath, #{}).

-spec ensure_loaded(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
ensure_loaded(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    narrow_ensure_result(
        gen_server:call(
            ?MODULE,
            {ensure_loaded, Domain, Locale, PoPath, Opts}
        )
    ).

%% Reload bypasses the idempotency check: always parses and re-installs.
%% Resolves AMB-001 overwrite semantics — the new catalog overwrites the
%% old one entry-by-entry. Atomicity caveat: between `unload/2` and the
%% insert step, the ETS catalog is briefly empty; lookups during that
%% window return `undefined` (v0.1 limitation, documented).
-spec reload(domain(), locale(), file:filename()) -> ensure_result().
reload(Domain, Locale, PoPath) ->
    reload(Domain, Locale, PoPath, #{}).

-spec reload(domain(), locale(), file:filename(), opts()) ->
    ensure_result().
reload(Domain, Locale, PoPath, Opts) when
    is_atom(Domain), is_binary(Locale), is_map(Opts)
->
    narrow_ensure_result(
        gen_server:call(
            ?MODULE,
            {reload, Domain, Locale, PoPath, Opts}
        )
    ).

%% Narrow the `term()` reply from `gen_server:call/2` to the public
%% `ensure_result()` contract. Both `handle_call({ensure_loaded, ...})`
%% and `handle_call({reload, ...})` deterministically return one of the
%% three shapes pattern-matched below — any other shape is a contract
%% violation and crashes with function_clause.
-spec narrow_ensure_result(term()) -> ensure_result().
narrow_ensure_result({ok, already}) ->
    {ok, already};
narrow_ensure_result({ok, N}) when is_integer(N), N >= 0 ->
    {ok, N};
narrow_ensure_result({error, Reason}) ->
    %% `ensure_error()` is a union of structured shapes plus the
    %% catch-all `{load_failed, term()}`. The server callbacks only emit
    %% the structured shapes, so a bare `term()` from `gen_server:call/2`
    %% safely re-classifies as `load_failed` if it doesn't match any
    %% known structured tag — this also future-proofs the API against new
    %% server-side error shapes leaking out untyped.
    {error, classify_ensure_error(Reason)}.

-spec classify_ensure_error(term()) -> ensure_error().
classify_ensure_error(Reason) ->
    %% The server only emits one of the structured `ensure_error()`
    %% shapes (see `do_load/4` and friends), but eqwalizer cannot prove
    %% that through a `gen_server:call/2` reply (specced `term()`).
    %% Validate the shape at the boundary: known structured tags pass
    %% through verbatim; anything else is wrapped in `{load_failed, _}`
    %% so the caller always sees a typed `ensure_error()`.
    case is_known_ensure_error(Reason) of
        true ->
            %% Known structured shape — narrow via runtime check above.
            narrow_known_ensure_error(Reason);
        false ->
            {load_failed, Reason}
    end.

%% Discriminator: a Reason value is a known `ensure_error()` shape iff
%% it matches one of the union members below. Keep in sync with the
%% `ensure_error()` type.
-spec is_known_ensure_error(term()) -> boolean().
is_known_ensure_error({unsupported_charset, B}) when is_binary(B) -> true;
is_known_ensure_error({charset_conversion, B, _}) when is_binary(B) -> true;
is_known_ensure_error({plural_count_mismatch, M, _, G}) when
    is_binary(M), is_list(G)
->
    true;
is_known_ensure_error({syntax_error, L, _}) when is_integer(L), L > 0 -> true;
is_known_ensure_error({file_error, _}) ->
    true;
is_known_ensure_error({plural_compile_error, _}) ->
    true;
is_known_ensure_error({load_failed, _}) ->
    true;
is_known_ensure_error(_) ->
    false.

%% Pre-condition: `is_known_ensure_error(Reason) =:= true`. We rebuild
%% the value with explicit constructors so eqwalizer sees the precise
%% union member, not the inferred `term()` from the reply pattern.
-spec narrow_known_ensure_error(term()) -> ensure_error().
narrow_known_ensure_error({unsupported_charset, B}) when is_binary(B) ->
    {unsupported_charset, B};
narrow_known_ensure_error({charset_conversion, B, T}) when is_binary(B) ->
    {charset_conversion, B, T};
narrow_known_ensure_error({plural_count_mismatch, M, E, G}) when
    is_binary(M), is_integer(E), is_list(G)
->
    %% Strengthen the indices field to a list of non-negative integers
    %% by re-validating. Any element that fails the shape becomes
    %% `{load_failed, _}` — this is the structural escape hatch that
    %% keeps the function total.
    case lists:all(fun(I) -> is_integer(I) andalso I >= 0 end, G) of
        true -> {plural_count_mismatch, M, E, narrow_indices(G)};
        false -> {load_failed, {plural_count_mismatch, M, E, G}}
    end;
narrow_known_ensure_error({syntax_error, L, R}) when is_integer(L), L > 0 ->
    {syntax_error, L, R};
narrow_known_ensure_error({file_error, Posix}) ->
    %% `file:posix() | badarg | terminated | system_limit` is a closed
    %% atom union. Classify at runtime via `is_atom/1` and fall through
    %% to `load_failed` for non-atom shapes (defence-in-depth).
    case is_atom(Posix) of
        true -> {file_error, narrow_file_error(Posix)};
        false -> {load_failed, {file_error, Posix}}
    end;
narrow_known_ensure_error({plural_compile_error, _CompileErr} = E) ->
    %% `erli18n_plural:compile_error()` is opaque to this module; we
    %% trust the upstream tag and wrap.
    classify_plural_compile_error(E);
narrow_known_ensure_error({load_failed, _Term} = E) ->
    E.

%% Cast `[term()]` known to be all `non_neg_integer()` (caller has
%% already verified with `lists:all/2`) into `[non_neg_integer()]`.
-spec narrow_indices([term()]) -> [non_neg_integer()].
narrow_indices([]) ->
    [];
narrow_indices([I | Rest]) when is_integer(I), I >= 0 ->
    [I | narrow_indices(Rest)].

%% Cast an atom known to be a posix-like error code into the
%% `file:posix() | badarg | terminated | system_limit` union. The
%% server only ever surfaces a real `file:read_file/1` error here, so
%% the input atom is guaranteed to be one of the documented values.
-spec narrow_file_error(atom()) ->
    file:posix() | badarg | terminated | system_limit.
narrow_file_error(badarg) -> badarg;
narrow_file_error(terminated) -> terminated;
narrow_file_error(system_limit) -> system_limit;
narrow_file_error(Posix) -> narrow_posix(Posix).

-spec narrow_posix(atom()) -> file:posix().
narrow_posix(eacces) ->
    eacces;
narrow_posix(eagain) ->
    eagain;
narrow_posix(ebadf) ->
    ebadf;
narrow_posix(ebadmsg) ->
    ebadmsg;
narrow_posix(ebusy) ->
    ebusy;
narrow_posix(edeadlk) ->
    edeadlk;
narrow_posix(edeadlock) ->
    edeadlock;
narrow_posix(edquot) ->
    edquot;
narrow_posix(eexist) ->
    eexist;
narrow_posix(efault) ->
    efault;
narrow_posix(efbig) ->
    efbig;
narrow_posix(eftype) ->
    eftype;
narrow_posix(eintr) ->
    eintr;
narrow_posix(einval) ->
    einval;
narrow_posix(eio) ->
    eio;
narrow_posix(eisdir) ->
    eisdir;
narrow_posix(eloop) ->
    eloop;
narrow_posix(emfile) ->
    emfile;
narrow_posix(emlink) ->
    emlink;
narrow_posix(emultihop) ->
    emultihop;
narrow_posix(enametoolong) ->
    enametoolong;
narrow_posix(enfile) ->
    enfile;
narrow_posix(enobufs) ->
    enobufs;
narrow_posix(enodev) ->
    enodev;
narrow_posix(enolck) ->
    enolck;
narrow_posix(enolink) ->
    enolink;
narrow_posix(enoent) ->
    enoent;
narrow_posix(enomem) ->
    enomem;
narrow_posix(enospc) ->
    enospc;
narrow_posix(enosr) ->
    enosr;
narrow_posix(enostr) ->
    enostr;
narrow_posix(enosys) ->
    enosys;
narrow_posix(enotblk) ->
    enotblk;
narrow_posix(enotdir) ->
    enotdir;
narrow_posix(enotsup) ->
    enotsup;
narrow_posix(enxio) ->
    enxio;
narrow_posix(eopnotsupp) ->
    eopnotsupp;
narrow_posix(eoverflow) ->
    eoverflow;
narrow_posix(eperm) ->
    eperm;
narrow_posix(epipe) ->
    epipe;
narrow_posix(erange) ->
    erange;
narrow_posix(erofs) ->
    erofs;
narrow_posix(espipe) ->
    espipe;
narrow_posix(esrch) ->
    esrch;
narrow_posix(estale) ->
    estale;
narrow_posix(etxtbsy) ->
    etxtbsy;
narrow_posix(exdev) ->
    exdev;
narrow_posix(Other) ->
    %% Unknown atom — surface as a load_failed so the caller still gets
    %% a typed error value. Should never happen with a real file:posix()
    %% from `file:read_file/1`.
    error({unknown_posix_atom, Other}).

%% Cast a `{plural_compile_error, Term}` payload where Term is opaque to
%% this module into the `ensure_error()` union. We delegate the shape
%% checking to `erli18n_plural` indirectly: if the inner term is a
%% known `compile_error()` shape, the union holds; otherwise we
%% conservatively wrap in `load_failed`. eqwalizer can't prove the
%% inner shape without import-side help, so we re-typecheck via a
%% guard-narrowed constructor.
-spec classify_plural_compile_error(term()) -> ensure_error().
classify_plural_compile_error({plural_compile_error, Inner}) ->
    case is_known_plural_compile_error(Inner) of
        true -> {plural_compile_error, narrow_plural_compile(Inner)};
        false -> {load_failed, {plural_compile_error, Inner}}
    end.

-spec is_known_plural_compile_error(term()) -> boolean().
is_known_plural_compile_error({syntax_error, _Reason, Pos}) when
    is_integer(Pos), Pos >= 0
->
    true;
is_known_plural_compile_error({missing_nplurals, B}) when is_binary(B) -> true;
is_known_plural_compile_error({missing_plural_expr, B}) when is_binary(B) -> true;
is_known_plural_compile_error({nplurals_out_of_range, N}) when is_integer(N) ->
    true;
is_known_plural_compile_error(_) ->
    false.

-spec narrow_plural_compile(term()) -> erli18n_plural:compile_error().
narrow_plural_compile({syntax_error, R, Pos}) when
    is_integer(Pos), Pos >= 0
->
    {syntax_error, R, Pos};
narrow_plural_compile({missing_nplurals, B}) when is_binary(B) ->
    {missing_nplurals, B};
narrow_plural_compile({missing_plural_expr, B}) when is_binary(B) ->
    {missing_plural_expr, B};
narrow_plural_compile({nplurals_out_of_range, N}) when is_integer(N) ->
    {nplurals_out_of_range, N};
narrow_plural_compile(Other) ->
    error({unknown_plural_compile_error, Other}).

%% Compute the gettext-style convention path for a given application,
%% domain, and locale: `<priv>/locale/<Locale>/LC_MESSAGES/<Domain>.po`.
%% Separation of concerns: the façade (Parte 6) decides whether to honour
%% this convention or use a caller-supplied path. `ensure_loaded` itself
%% takes the path explicitly — no implicit resolution inside this module.
-spec default_po_path(atom(), domain(), locale()) -> file:filename().
default_po_path(App, Domain, Locale) when
    is_atom(App), is_atom(Domain), is_binary(Locale)
->
    %% `code:priv_dir/1` returns `file:filename() | {error, bad_name}`.
    %% A `bad_name` means the application is unknown — crash explicitly
    %% so the operator sees the misconfiguration immediately, instead of
    %% silently building a path with `{error, bad_name}` embedded in it.
    PrivDir =
        case code:priv_dir(App) of
            {error, bad_name} ->
                error({priv_dir_not_found, App});
            Dir when is_list(Dir) ->
                Dir
        end,
    %% `filename:join/1` is specced `file:filename_all()`; we need
    %% `file:filename()` (a string) for the public contract. All inputs
    %% are strings (`PrivDir`, literal strings, `binary_to_list/1`,
    %% `atom_to_list/1` + concat), so the result is a string too.
    %% Narrow at the boundary so an unexpected binary surfaces as a
    %% badmatch instead of corrupting the contract downstream.
    Joined = filename:join([
        PrivDir,
        "locale",
        binary_to_list(Locale),
        "LC_MESSAGES",
        atom_to_list(Domain) ++ ".po"
    ]),
    case Joined of
        Str when is_list(Str) -> Str;
        Other -> error({unexpected_filename_shape, Other, expected, string})
    end.

%% =========================
%% gen_server callbacks
%% =========================

-spec init([]) -> {ok, map()}.
init([]) ->
    %% Finding #10: the server no longer CREATES the table. It asks the
    %% dedicated owner (`erli18n_table_owner', started before us under
    %% `rest_for_one') to hand it over via `give_away/3'. `claim_table/0'
    %% is synchronous; once it returns, the initial `'ETS-TRANSFER'' is on
    %% its way. We become the table proprietor (writer of the protected
    %% table) by consuming it below. This way an abrupt crash of this
    %% worker transfers the table back to the owner (heir) with all rows
    %% intact instead of destroying every loaded catalog.
    ok = erli18n_table_owner:claim_table(),
    receive
        {'ETS-TRANSFER', ?ETS_TABLE, _OwnerPid, ?ETS_HANDOFF_DATA} ->
            ok
    after 5000 ->
        %% The owner is a sibling child started BEFORE us (rest_for_one);
        %% if it has not handed the table over within 5s something is
        %% structurally broken — crashing is the correct OTP behaviour
        %% (the supervisor re-evaluates).
        error({ets_handoff_timeout, ?ETS_TABLE})
    end,
    %% Finding #7: create the authoritative O(1) catalog index and seed it
    %% from whatever rows survived in the data table. On first boot the
    %% data table is empty so this is a no-op; after a worker crash the
    %% data table comes back (heir handoff) populated, so we rebuild the
    %% index once here instead of scanning the table on every load. The
    %% server is the table's sole writer, so an index it owns can never
    %% diverge while the worker is alive.
    _ = create_catalog_index(),
    ok = rebuild_catalog_index(),
    {ok, #{}}.

%% Create the side index table if it does not already exist. The table is
%% server-owned (dies with the worker, rebuilt on `init/1') and protected:
%% only this process writes to it. Re-entrant so a worker restart that
%% inherits a stale name (it won't — the table dies with the old worker)
%% degrades to a no-op rather than crashing.
-spec create_catalog_index() -> ets:table().
create_catalog_index() ->
    case ets:info(?CATALOG_INDEX_TABLE, name) of
        undefined ->
            ets:new(?CATALOG_INDEX_TABLE, [
                set,
                protected,
                named_table,
                {read_concurrency, true},
                {keypos, 1}
            ]);
        _Existing ->
            ?CATALOG_INDEX_TABLE
    end.

%% Rebuild the index from the data table. Runs exactly once per worker
%% lifetime (in `init/1'), NOT on the per-load path. Cost is O(rows) of
%% the surviving table — paid only after a crash, never repeated. We clear
%% first so a re-entrant rebuild stays idempotent.
-spec rebuild_catalog_index() -> ok.
rebuild_catalog_index() ->
    true = ets:delete_all_objects(?CATALOG_INDEX_TABLE),
    seed_index(ets:tab2list(?ETS_TABLE)),
    ok.

-spec seed_index([tuple()]) -> ok.
seed_index([]) ->
    ok;
seed_index([Obj | Rest]) ->
    _ = index_obj(Obj),
    seed_index(Rest).

%% Register the (Domain, Locale) of a single surviving data row. Header
%% rows carry no user-visible entries and so do NOT register — same rule
%% `memory_info/0' has always used (a header-only `.po' is not a catalog
%% for counting purposes).
-spec index_obj(tuple()) -> ok.
index_obj({{singular, D, L, _, _}, _}) ->
    index_put(D, L);
index_obj({{plural, D, L, _, _, _}, _}) ->
    index_put(D, L);
index_obj(_Other) ->
    ok.

handle_call({insert_singular, D, L, Ctx, Msgid, T}, _From, State) ->
    true = ets:insert(?ETS_TABLE, {?SINGULAR_KEY(D, L, Ctx, Msgid), T}),
    %% Finding #7: maintain the O(1) catalog index incrementally. A
    %% singular insert always writes exactly one data row, so the catalog
    %% now has >=1 entry — register it (idempotent).
    index_put(D, L),
    {reply, ok, State};
handle_call({insert_plural, D, L, Ctx, Msgid, Entries}, _From, State) ->
    %% Build a strictly-tuple list so `ets:insert/2` sees the precise
    %% type it expects. The list comprehension binds {Idx, T} from each
    %% entry; the result tuple has fixed arity 2 and is always a tuple.
    Objects = build_plural_objects(D, L, Ctx, Msgid, Entries),
    true = ets:insert(?ETS_TABLE, Objects),
    %% Only register when at least one row was actually written. An empty
    %% form list inserts nothing, so it must not bump the catalog count
    %% (membership rule: index row present <=> >=1 data entry).
    maybe_index_put(D, L, Objects),
    {reply, ok, State};
handle_call({insert_catalog, D, L, Entries}, _From, State) ->
    Objects = build_catalog_objects(D, L, Entries),
    true = ets:insert(?ETS_TABLE, Objects),
    maybe_index_put(D, L, Objects),
    {reply, ok, State};
handle_call({unload, D, L}, _From, State) ->
    %% Span: [erli18n, catalog, unload]. Always-on per observability.md
    %% §6 (frequency is bounded — admin operation, not hot path).
    %% Metadata schema per observability.md §4.1:
    %%   start:     #{domain, locale}
    %%   stop:      #{domain, locale, result :: ok | not_loaded,
    %%                keys_removed}
    %%   exception: #{domain, locale, kind, reason, stacktrace}
    %%
    %% telemetry:span/3 passes ONLY the stop metadata returned by the
    %% closure to the stop event (NOT merged with the start metadata —
    %% see https://hexdocs.pm/telemetry/telemetry.html#span-3 and the
    %% upstream impl in telemetry/src/telemetry.erl). So the closure
    %% must build the full stop metadata, repeating the base fields.
    StartMeta = #{domain => D, locale => L},
    _ = erli18n_telemetry:span(
        erli18n_telemetry:event_catalog_unload(),
        StartMeta,
        fun() ->
            {Result, KeysRemoved} = do_unload_with_count(D, L),
            StopMeta = StartMeta#{
                result => Result,
                keys_removed => KeysRemoved
            },
            {ok, StopMeta}
        end
    ),
    %% Preserve the historical public contract of `unload/2`.
    {reply, ok, State};
handle_call({ensure_loaded, D, L, PoPath, Opts}, _From, State) ->
    %% Span: [erli18n, catalog, load]. Always-on per observability.md
    %% §6. Wraps the entire pipeline — header check, parse, compile,
    %% validate, install. Idempotent fast-path still emits the span so
    %% consumers see both load and "already loaded" traffic; the result
    %% atom in the stop metadata disambiguates.
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => D,
        locale => L,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    Reply =
        erli18n_telemetry:span(
            erli18n_telemetry:event_catalog_load(),
            StartMeta,
            fun() ->
                Inner =
                    case lookup_header(D, L) of
                        {ok, _} ->
                            %% Idempotent fast-path per RISK-012
                            %% mitigation 2: do not re-read the file,
                            %% do not re-parse. The span still emits
                            %% so consumers can see `result => already`
                            %% (observability.md §4.1, note about
                            %% RISK-012 mitigation 2).
                            {ok, already};
                        undefined ->
                            do_load(D, L, PoPath, Opts)
                    end,
                StopMeta = maps:merge(
                    StartMeta,
                    load_stop_metadata(Inner)
                ),
                {Inner, StopMeta}
            end
        ),
    {reply, Reply, State};
handle_call({reload, D, L, PoPath, Opts}, _From, State) ->
    %% Span: [erli18n, catalog, reload]. Identical schema to
    %% [erli18n, catalog, load]; the distinct event name lets consumers
    %% react differently (e.g. invalidate derived caches). Per AMB-001
    %% reload overwrites the existing catalog — atomicity caveat
    %% (lookups during the unload→load gap return undefined) is
    %% documented in `reload/3,4`.
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    StartMeta = #{
        domain => D,
        locale => L,
        language => lc_messages,
        po_path => to_binary_path(PoPath),
        fuzzy_included => IncludeFuzzy
    },
    Reply =
        erli18n_telemetry:span(
            erli18n_telemetry:event_catalog_reload(),
            StartMeta,
            fun() ->
                do_unload(D, L),
                Inner = do_load(D, L, PoPath, Opts),
                StopMeta = maps:merge(
                    StartMeta,
                    load_stop_metadata(Inner)
                ),
                {Inner, StopMeta}
            end
        ),
    {reply, Reply, State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================
%% Internal: load pipeline
%% =========================
%%
%% Atomicity: all error-producing operations (file read, parse, plural
%% compile, CLDR validation) happen BEFORE any ETS mutation. The catalog
%% insert and header insert are the last two steps; if either runs, both
%% run, because ETS `set` is itself atomic at the row level and the
%% gen_server serializes the whole sequence.
%%
%% Order:
%%   1. file:read_file/1            — may fail with {file_error, Posix}
%%   2. erli18n_po:parse/2          — may fail with parse_error()
%%   3. compile plural header       — may fail with {plural_compile_error, _}
%%   4. validate_against_cldr/2     — never fails (returns ok | {warning, _})
%%   5. ets:insert entries          — infallible (ETS set always succeeds)
%%   6. ets:insert header_state     — infallible
%%
%% On failure at steps 1-3, ETS is untouched. The caller sees a structured
%% error and the catalog state is whatever it was before the call.
do_load(Domain, Locale, PoPath, Opts) ->
    IncludeFuzzy = maps:get(include_fuzzy, Opts, false),
    case file:read_file(PoPath) of
        {error, Posix} ->
            {error, {file_error, Posix}};
        {ok, Bin} ->
            case erli18n_po:parse(Bin, #{include_fuzzy => IncludeFuzzy}) of
                {error, _} = E ->
                    E;
                {ok, Parsed} ->
                    %% Loader-level fuzzy_skip telemetry. The parser
                    %% drops fuzzy entries silently (per PSD-001), but
                    %% we want the count surfaced as a single aggregated
                    %% emit per load so consumers can observe how much
                    %% material is being discarded. observability.md
                    %% §4.2 notes that this event is load-time-only on
                    %% the implementation side. We re-parse a second
                    %% time with `include_fuzzy => true` ONLY when (a)
                    %% the consumer has opted in to lookup telemetry,
                    %% and (b) the original load discarded fuzzy
                    %% entries by default — otherwise we have no count
                    %% to surface. Cost: one extra parse per load, paid
                    %% only when explicitly opted in.
                    maybe_emit_fuzzy_skip(
                        Domain,
                        Locale,
                        Bin,
                        IncludeFuzzy,
                        Parsed
                    ),
                    install_parsed(
                        Domain,
                        Locale,
                        PoPath,
                        IncludeFuzzy,
                        Parsed
                    )
            end
    end.

%% Compute the number of fuzzy entries that the parser dropped on this
%% load. Only invoked when both opt-in and not-include-fuzzy hold (the
%% only case where the emit would be meaningful and observability.md §6
%% says the flag controls it). The double-parse pattern keeps
%% `erli18n_po` ignorant of the (Domain, Locale) context — the parser's
%% job is parsing PO, not emitting telemetry.
maybe_emit_fuzzy_skip(Domain, Locale, RawBin, false = _IncludeFuzzy, Parsed) ->
    case erli18n_telemetry:lookup_telemetry_enabled() of
        false ->
            ok;
        true ->
            DefaultCount = length(maps:get(entries, Parsed, [])),
            %% The re-parse uses include_fuzzy => true against the same
            %% input bytes that already parsed successfully with
            %% include_fuzzy => false. The flag only changes which
            %% entries are kept; it cannot affect parser correctness.
            %% A failure here would be a parser invariant break, so we
            %% pattern-match exactly and let badmatch surface it.
            {ok, #{entries := AllEntries}} =
                erli18n_po:parse(RawBin, #{include_fuzzy => true}),
            Diff = length(AllEntries) - DefaultCount,
            case Diff > 0 of
                true ->
                    erli18n_telemetry:emit(
                        erli18n_telemetry:event_lookup_fuzzy_skip(),
                        #{count => Diff},
                        #{domain => Domain, locale => Locale}
                    ),
                    ok;
                false ->
                    ok
            end
    end;
maybe_emit_fuzzy_skip(
    _Domain,
    _Locale,
    _RawBin,
    true = _IncludeFuzzy,
    _Parsed
) ->
    %% include_fuzzy => true was passed — no entries were dropped, so
    %% the event is not emitted (observability.md §4.2 "Quando NÃO é
    %% emitido").
    ok.

install_parsed(Domain, Locale, PoPath, IncludeFuzzy, Parsed) ->
    #{header := Header, entries := Entries} = Parsed,
    PluralRaw =
        case maps:get(plural_forms, Header, <<>>) of
            <<>> -> erli18n_plural:fallback_rule();
            Other -> Other
        end,
    case maybe_compile_plural(Header) of
        {error, CompileErr} ->
            {error, {plural_compile_error, CompileErr}};
        {ok, PluralCompiled} ->
            Divergence = compute_divergence(Locale, Header),
            HeaderState = #{
                plural => PluralCompiled,
                plural_raw => PluralRaw,
                po_path => PoPath,
                loaded_at => erlang:system_time(millisecond),
                divergence => Divergence,
                fuzzy_included => IncludeFuzzy,
                num_entries => length(Entries)
            },
            emit_divergence_log(Domain, Locale, Divergence),
            %% Telemetry: [erli18n, plural, divergence_warning]. Always-on
            %% per observability.md §6 (load-time, infrequent). Schema in
            %% observability.md §4.2.
            emit_divergence_telemetry(Domain, Locale, Divergence),
            Inserted = insert_entries(Domain, Locale, Entries),
            %% Finding #7: register the catalog in the O(1) index iff the
            %% load produced at least one data row. A header-only `.po'
            %% (or a plural with empty form lists) writes only the header
            %% row below, which is intentionally NOT counted as a catalog
            %% (consistent with `loaded_catalogs/0' / the old tab2list
            %% scan). The `?HEADER_KEY' insert is infallible and never
            %% touches the index.
            maybe_index_put_loaded(Domain, Locale, Inserted),
            true = ets:insert(
                ?ETS_TABLE,
                {?HEADER_KEY(Domain, Locale), HeaderState}
            ),
            %% Memory warning check runs after the insert so the
            %% measurement reflects the post-install state — that's the
            %% snapshot a consumer would observe via
            %% `erli18n:memory_info/0`. Always-on, rate-limited inside
            %% `erli18n_telemetry:memory_warning_check/1`. RISK-011
            %% mitigation 2.
            _ = erli18n_telemetry:memory_warning_check(memory_info()),
            {ok, length(Entries)}
    end.

%% Compile the plural header into the in-memory bundle. Returns
%% `{ok, Compiled | fallback}` where `fallback` signals "no header was
%% present" — the lookup hot path then uses the C/Germanic default
%% (`fallback_form_index/1`) instead of evaluating an AST.
%%
%% This avoids paying compile cost on the load path for catalogs that ship
%% without a `Plural-Forms` header, and lets the runtime branch on a
%% small atom rather than a map.
%% The parser always emits #{plural_forms := _} (see erli18n_po
%% `empty_header/0` and `build_header/1`), so the two clauses below are
%% exhaustive for any header produced by erli18n_po:parse/{1,2}. A
%% missing key here would be a parser invariant break and is allowed to
%% crash with function_clause.
maybe_compile_plural(#{plural_forms := <<>>}) ->
    {ok, fallback};
maybe_compile_plural(#{plural_forms := PluralRaw}) ->
    case erli18n_plural:compile(PluralRaw) of
        {ok, _} = OK -> OK;
        {error, _} = E -> E
    end.

%% Header divergence vs CLDR is informational only (PSD-004). When the
%% header is absent we have nothing to compare; when the locale is not in
%% the CLDR table we can't compare either. In both cases we report
%% `none`.
%% Like `maybe_compile_plural/1`, the two clauses below are exhaustive
%% for any header produced by erli18n_po — `plural_forms` is always
%% present (empty binary when no header / no expression was provided).
%% A missing key would be a parser contract violation and is allowed to
%% crash with function_clause.
compute_divergence(_Locale, #{plural_forms := <<>>}) ->
    none;
compute_divergence(Locale, #{plural_forms := HeaderRule}) ->
    case erli18n_plural:validate_against_cldr(Locale, HeaderRule) of
        ok ->
            none;
        {warning, {plural_divergence, _Loc, HdrRule, CldrRule}} ->
            {plural_divergence, HdrRule, CldrRule}
    end.

%% Per BR-MIGRAR-030, log uses OTP logger with `#{domain => [erli18n,
%% server]}` metadata. Telemetry emission is deferred to Parte 7; the
%% divergence info is preserved in the header_state so a later telemetry
%% layer can publish it without re-loading the catalog.
emit_divergence_log(_Domain, _Locale, none) ->
    ok;
emit_divergence_log(Domain, Locale, {plural_divergence, HdrRule, CldrRule}) ->
    ?LOG_WARNING(
        #{
            event => plural_divergence,
            domain_name => Domain,
            locale => Locale,
            header_rule => HdrRule,
            cldr_rule => CldrRule
        },
        #{domain => [erli18n, server]}
    ),
    ok.

%% Telemetry counterpart to the ?LOG_WARNING above. Always emitted on
%% real divergence; skipped on `none`. Schema is the contract in
%% observability.md §4.2 (`[erli18n, plural, divergence_warning]`).
emit_divergence_telemetry(_Domain, _Locale, none) ->
    ok;
emit_divergence_telemetry(
    Domain,
    Locale,
    {plural_divergence, HdrRule, CldrRule}
) ->
    erli18n_telemetry:emit(
        erli18n_telemetry:event_plural_divergence(),
        #{count => 1},
        #{
            domain => Domain,
            locale => Locale,
            po_rule => HdrRule,
            cldr_rule => CldrRule
        }
    ),
    ok.

%% Bulk-insert all entries in a single ETS call so the catalog is
%% installed in one operation. Per `ets:insert/2` docs, multi-object
%% insert on `set` is atomic and isolated — observers either see the old
%% state or the new state, never a mix.
%%
%% Returns `true' iff at least one data row was actually written, so the
%% caller can decide whether the catalog should register in the O(1)
%% index (finding #7): an empty entry list — or entries that flatten to
%% zero ETS objects, e.g. a plural with empty form lists — must NOT count
%% as a loaded catalog.
-spec insert_entries(domain(), locale(), [catalog_entry()]) -> boolean().
insert_entries(_Domain, _Locale, []) ->
    false;
insert_entries(Domain, Locale, Entries) ->
    Objects = build_catalog_objects(Domain, Locale, Entries),
    case Objects of
        [] -> false;
        [_ | _] -> ets:insert(?ETS_TABLE, Objects)
    end.

%% Build the list of ETS objects for a single plural msgid. Each entry
%% is a `{Index, Translation}` tuple; the output rows are
%% `{?PLURAL_KEY/5, Translation}` tuples. The explicit `tuple()` element
%% spec keeps `ets:insert/2` typed without weakening the inner shape.
-spec build_plural_objects(
    domain(),
    locale(),
    context(),
    msgid(),
    [{plural_index(), translation()}]
) -> [tuple()].
build_plural_objects(_D, _L, _Ctx, _Msgid, []) ->
    [];
build_plural_objects(D, L, Ctx, Msgid, [{Idx, T} | Rest]) when
    is_integer(Idx), Idx >= 0
->
    [
        {?PLURAL_KEY(D, L, Ctx, Msgid, Idx), T}
        | build_plural_objects(D, L, Ctx, Msgid, Rest)
    ].

%% Flatten a list of catalog entries to ETS object tuples. The spec
%% pins the element type to `tuple()` so `ets:insert/2` is typed
%% correctly.
-spec build_catalog_objects(
    domain(),
    locale(),
    [catalog_entry()]
) -> [tuple()].
build_catalog_objects(_D, _L, []) ->
    [];
build_catalog_objects(D, L, [E | Rest]) ->
    entry_to_objects(D, L, E) ++ build_catalog_objects(D, L, Rest).

do_unload(Domain, Locale) ->
    _ = do_unload_with_count(Domain, Locale),
    ok.

%% Counts the rows actually deleted so the unload span can report
%% `keys_removed` (observability.md §4.1). The result atom mirrors the
%% schema: `not_loaded` when there was nothing to delete, `ok`
%% otherwise. Defined separately so the legacy `do_unload/2` keeps its
%% simple ok-returning shape for non-telemetry callers (e.g. the
%% internal `reload` step that doesn't need the count).
do_unload_with_count(Domain, Locale) ->
    MatchSpec =
        [
            {{?SINGULAR_KEY(Domain, Locale, '_', '_'), '_'}, [], [true]},
            {{?PLURAL_KEY(Domain, Locale, '_', '_', '_'), '_'}, [], [true]},
            {{?HEADER_KEY(Domain, Locale), '_'}, [], [true]}
        ],
    Deleted = ets:select_delete(?ETS_TABLE, MatchSpec),
    %% Finding #7: drop the catalog from the O(1) index. Unload is the only
    %% bulk removal path (the write API has no per-key delete), so this is
    %% where index rows disappear. `index_delete/2' is idempotent — a
    %% never-loaded (Domain, Locale) was never in the index.
    index_delete(Domain, Locale),
    Result =
        case Deleted of
            0 -> not_loaded;
            _ -> ok
        end,
    {Result, Deleted}.

%% Build the stop metadata for the catalog load/reload span. Maps the
%% internal load result onto the schema in observability.md §4.1:
%%
%%   {ok, N}             -> #{result => ok,    keys_loaded => N}
%%   {ok, already}       -> #{result => already, keys_loaded => 0}
%%   {error, Term}       -> #{result => {error, Term}, keys_loaded => 0}
load_stop_metadata({ok, already}) ->
    #{result => already, keys_loaded => 0};
load_stop_metadata({ok, N}) when is_integer(N) ->
    #{result => ok, keys_loaded => N};
load_stop_metadata({error, Reason}) ->
    #{result => {error, Reason}, keys_loaded => 0}.

%% The `po_path` metadata field must be binary per observability.md
%% §4.1 (catalog_load_metadata typespec). `file:filename()` can be
%% either a list or binary depending on the build; we normalize at the
%% telemetry boundary so handlers never have to guard.
to_binary_path(Path) when is_binary(Path) -> Path;
to_binary_path(Path) when is_list(Path) -> unicode:characters_to_binary(Path).

%% =========================
%% Internal: helpers
%% =========================

%% Fallback plural index used when the .po has no Plural-Forms header.
%% Same as the GNU manual's "Translating plural forms" §"Plural forms"
%% default: N == 1 -> singular (0); otherwise plural (1).
fallback_form_index(1) -> 0;
fallback_form_index(_) -> 1.

-spec entry_to_objects(domain(), locale(), catalog_entry()) -> [tuple()].
entry_to_objects(D, L, {singular, Ctx, Msgid, T}) ->
    [{?SINGULAR_KEY(D, L, Ctx, Msgid), T}];
entry_to_objects(D, L, {plural, Ctx, Msgid, Entries}) ->
    build_plural_objects(D, L, Ctx, Msgid, Entries).

%% =========================
%% Internal: O(1) catalog index (finding #7)
%% =========================
%%
%% The index holds one row `{{Domain, Locale}}' per catalog with >=1 data
%% entry. The server is its only writer, mutating it in lock-step with the
%% data table inside the serialized `handle_call' callbacks, so the two
%% never diverge. All operations are O(1).

%% Register a catalog. Idempotent: re-inserting the same key is a no-op on
%% a `set' table, so repeated inserts into an already-loaded catalog do
%% not corrupt the count.
-spec index_put(domain(), locale()) -> ok.
index_put(D, L) ->
    true = ets:insert(?CATALOG_INDEX_TABLE, {{D, L}}),
    ok.

%% Register iff the just-completed write produced at least one ETS object.
%% Used by the bulk insert paths (`insert_plural'/`insert_catalog') where
%% an empty/degenerate entry set yields zero rows and must not count.
-spec maybe_index_put(domain(), locale(), [tuple()]) -> ok.
maybe_index_put(_D, _L, []) ->
    ok;
maybe_index_put(D, L, [_ | _]) ->
    index_put(D, L).

%% Variant for the load path, keyed on the `insert_entries/3' boolean
%% (did it write any data row?). Header-only loads pass `false' and so do
%% not register as a catalog.
-spec maybe_index_put_loaded(domain(), locale(), boolean()) -> ok.
maybe_index_put_loaded(_D, _L, false) ->
    ok;
maybe_index_put_loaded(D, L, true) ->
    index_put(D, L).

%% Deregister a catalog. Idempotent: deleting an absent key is a no-op.
-spec index_delete(domain(), locale()) -> ok.
index_delete(D, L) ->
    true = ets:delete(?CATALOG_INDEX_TABLE, {D, L}),
    ok.

%% O(1) count of distinct loaded catalogs — the whole point of the index.
%% `ets:info(_, size)' is documented O(1); the table only ever exists
%% after `init/1' creates it, so a real `undefined' here means the server
%% is dead and crashing with a descriptive payload is correct.
-spec index_size() -> non_neg_integer().
index_size() ->
    case ets:info(?CATALOG_INDEX_TABLE, size) of
        N when is_integer(N), N >= 0 ->
            N;
        Other ->
            error(
                {ets_info_invalid, {?CATALOG_INDEX_TABLE, size, Other, expected, non_neg_integer}}
            )
    end.

-spec count_per_catalog(
    tuple(),
    #{{domain(), locale()} => non_neg_integer()}
) -> #{{domain(), locale()} => non_neg_integer()}.
count_per_catalog({{singular, D, L, _, _}, _}, Acc) ->
    maps:update_with({D, L}, fun(N) -> N + 1 end, 1, Acc);
count_per_catalog({{plural, D, L, _, _, _}, _}, Acc) ->
    maps:update_with({D, L}, fun(N) -> N + 1 end, 1, Acc);
count_per_catalog({{header, _, _}, _}, Acc) ->
    Acc;
count_per_catalog(_Other, Acc) ->
    Acc.

%% Used by which_keys/2. Singulars are appended verbatim; plurals are
%% collected into a set keyed on (Context, Msgid) so multi-form plural
%% entries collapse to one user-visible row.
-spec collect_key(domain(), locale(), tuple(), key_acc()) -> key_acc().
collect_key(
    Domain,
    Locale,
    {{singular, Domain, Locale, Ctx, Msgid}, _},
    #{singulars := S} = Acc
) ->
    Acc#{singulars := [{singular, Ctx, Msgid} | S]};
collect_key(
    Domain,
    Locale,
    {{plural, Domain, Locale, Ctx, Msgid, _Idx}, _},
    #{plurals := P} = Acc
) ->
    Acc#{plurals := sets:add_element({Ctx, Msgid}, P)};
collect_key(_Domain, _Locale, _Obj, Acc) ->
    Acc.
