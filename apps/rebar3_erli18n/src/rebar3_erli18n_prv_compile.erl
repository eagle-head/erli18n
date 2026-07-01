-module(rebar3_erli18n_prv_compile).

-moduledoc """
`rebar3 erli18n compile` — opt-in compile-time `.po`->BEAM catalog codegen.

For every `(Domain, Locale)` catalog under the catalog root this provider
reads the `.po`, parses its entries and compiles its `Plural-Forms` rule
AHEAD of time, then emits a tiny generated carrier module
(`erli18n_cc_<Domain>__<Locale>.erl`) whose `catalog/0` returns the
ALREADY-parsed entries plus the ALREADY-compiled plural rule baked into the
BEAM literal pool (see `rebar3_erli18n_codegen`). A consumer registers them
at boot through `erli18n:register_compiled_catalogs/1` with NO runtime `.po`
parse and NO plural compile.

The whole surface is OPT-IN: with no `{compiled_catalogs, true}` in
`rebar.config` the provider is a loud-logged no-op and writes nothing, so a
project that uses no compiled catalogs sees zero change. Reading the runtime
`ensure_loaded/3` path stays the default.

## Configuration (read from `rebar.config`)

The entire surface is read via `rebar3_erli18n_host:get_config/3` under the
`erli18n` key:

- `compiled_catalogs` — master gate; `false`/absent makes the provider a
  loud-logged no-op.
- `key_check` — `off | warn | strict`; an unknown atom normalises to `warn`
  (logged once). Folds in the compiled-catalog key-existence check after
  codegen.
- `compiled_domains` — `all` (default: every extracted domain that has a
  catalog) or an explicit `[atom()]` list; scopes BOTH the codegen and the
  key check.
- `gen_dir` — output directory for the generated carriers (default
  `"src/erli18n_gen"`, resolved relative to the root app).
- `include_fuzzy` — include `#, fuzzy` entries (default `false`), passed to
  `erli18n_po:parse/2` and baked into `header.fuzzy_included`.
- `gen_eqwalizer_nowarn` — emit the function-scoped eqwalizer nowarn on each
  carrier's `catalog/0` (default `true`), passed as render options.
- `max_po_bytes` — reject a `.po` larger than this many bytes BEFORE reading it
  (default: the runtime library's `erli18n_server:default_max_bytes/0`, 16 MiB);
  `infinity` disables the size cap.
- `max_entries` — reject a parsed catalog with more than this many entries
  (default: the runtime library's `erli18n_server:default_max_entries/0`,
  500000); `infinity` disables the entry cap. Both caps mirror the runtime
  loader so a compiled carrier can never carry more than `ensure_loaded/3`
  would accept; a violation is a loud build error.

## Command-line options

`--strict` (treat missing keys as a build failure), `--no-key-check` (skip
the key check entirely), `--check` (dry run: generate nothing, only validate)
plus the shared `--domain` and `--pot-dir`. Policy precedence:
`--no-key-check` > `--strict`/`--check` > the `{key_check}` config > the
default `warn`.
""".

%% This module implements the rebar3 `provider` contract (`init/1`, `do/1`,
%% `format_error/1`); it is registered via
%% `rebar3_erli18n_host:create_provider/1` in `init/1`, mirroring the other
%% `erli18n`-namespace providers. The `-behaviour(provider)` attribute is
%% intentionally omitted: the `provider` behaviour ships inside the rebar3
%% escript (stripped of debug_info and not on Hex), so neither dialyzer nor
%% eqwalizer can load its callback info standalone.

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, compile).
-define(NAMESPACE, erli18n).
%% No deps: the provider can be wired as a pre-compile hook, so it must not
%% depend on the app compile having run first.
-define(DEPS, []).
-define(DEFAULT_GEN_DIR, "src/erli18n_gen").
%% A generated-source directory ships nothing to version control: the carriers
%% are a build artifact regenerated from the source `.po`.
-define(GITIGNORE_BODY, <<"*\n">>).

%% A single built carrier, ready to render and key-check: its module name, the
%% rendered source, the `{Domain, Locale}` pair it was built for, and the
%% ALREADY-parsed entries used for the compiled key universe.
-type built() :: #{
    module := binary(),
    source := unicode:chardata(),
    domain := binary(),
    locale := erli18n_server:locale(),
    entries := [erli18n_po:entry()]
}.

%% The build-time anti-DoS caps applied to each `.po`, mirroring the runtime
%% loader's bounds so a compiled carrier can never carry more than
%% `erli18n:ensure_loaded/3` would accept: `max_bytes` is checked before the file
%% is read (via `filelib:file_size/1`), `max_entries` after the parse. Both
%% default to the runtime library's values and are overridable per project;
%% `infinity` disables that cap.
-type caps() :: #{
    max_bytes := non_neg_integer() | infinity,
    max_entries := non_neg_integer() | infinity
}.

-doc "Register the `compile` provider under the `erli18n` namespace.".
-spec init(rebar3_erli18n_host:state()) -> {ok, rebar3_erli18n_host:state()}.
init(State) ->
    Provider = rebar3_erli18n_host:create_provider([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 erli18n compile"},
        {opts, compile_opts()},
        {short_desc, "Generate compile-time .po->BEAM catalog carriers (opt-in)."},
        {desc,
            "Opt-in compile-time catalog codegen. With {compiled_catalogs, true} in "
            "rebar.config, parses each .po and compiles its plural rule ahead of time, "
            "emitting an erli18n_cc_* carrier per (Domain, Locale) whose catalog/0 returns "
            "the already-parsed entries plus the already-compiled plural baked into BEAM. "
            "Without that gate it is a no-op."}
    ]),
    {ok, rebar3_erli18n_host:add_provider(State, Provider)}.

%% The getopt spec: the shared `--domain`/`--pot-dir` plus the three
%% compile-specific boolean switches.
-spec compile_opts() ->
    [{atom(), char() | undefined, string(), atom() | tuple(), string()}].
compile_opts() ->
    [
        {domain, $d, "domain", string, "Restrict to a single gettext domain (default: all)."},
        {pot_dir, undefined, "pot-dir", string,
            "Catalog root directory (default: <app>/priv/gettext)."},
        {strict, undefined, "strict", boolean,
            "Fail the build when a call-site key is missing from the compiled catalog."},
        {no_key_check, undefined, "no-key-check", boolean,
            "Skip the compiled-catalog key-existence check entirely."},
        {check, undefined, "check", boolean,
            "Dry run: validate (parse + plural compile + key check) without writing carriers."}
    ].

-doc """
Run the compile provider.

A loud-logged no-op (writing nothing) unless `{compiled_catalogs, true}` is in
`rebar.config`. Otherwise generates one carrier per `(Domain, Locale)` and runs
the folded key check.
""".
-spec do(rebar3_erli18n_host:state()) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
do(State) ->
    Cfg = config(State),
    case proplists:get_value(compiled_catalogs, Cfg, false) of
        true ->
            do_compile(State, Cfg);
        _Absent ->
            rebar3_erli18n_host:warn(
                "erli18n compile: opt-in codegen is disabled (no {compiled_catalogs, true} "
                "in rebar.config) — generating nothing.",
                []
            ),
            {ok, State}
    end.

-doc "Render a provider error to a human-readable string.".
-spec format_error(term()) -> string().
format_error({input_too_large, Size, MaxBytes}) ->
    lists:flatten(
        io_lib:format(
            "erli18n compile: input_too_large — a .po file is ~w bytes, over the "
            "~w-byte cap. Set {max_po_bytes, infinity} in the erli18n rebar.config "
            "to disable the build-time size cap.",
            [Size, MaxBytes]
        )
    );
format_error({too_many_entries, Count, MaxEntries}) ->
    lists:flatten(
        io_lib:format(
            "erli18n compile: too_many_entries — a catalog has ~w entries, over the "
            "~w-entry cap. Set {max_entries, infinity} in the erli18n rebar.config "
            "to disable the build-time entry cap.",
            [Count, MaxEntries]
        )
    );
format_error(Reason) ->
    rebar3_erli18n_common:format_error(Reason).

%% =========================
%% Pipeline
%% =========================

-spec do_compile(rebar3_erli18n_host:state(), [term()]) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
do_compile(State, Cfg) ->
    PotDir = rebar3_erli18n_common:pot_dir(State),
    IncludeFuzzy = cfg_bool(include_fuzzy, Cfg, false),
    NoWarn = cfg_bool(gen_eqwalizer_nowarn, Cfg, true),
    Caps = caps(Cfg),
    case scope_domains(State, Cfg) of
        {error, Reason} ->
            {error, format_error(Reason)};
        {ok, Scope} ->
            Catalogs = discover_catalogs(PotDir, Scope),
            case build_all(Catalogs, IncludeFuzzy, NoWarn, Caps) of
                {error, Reason} ->
                    {error, format_error(Reason)};
                {ok, Built} ->
                    continue_after_build(State, Cfg, Scope, Built)
            end
    end.

-spec continue_after_build(
    rebar3_erli18n_host:state(), [term()], all | {only, [binary()]}, [built()]
) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
continue_after_build(State, Cfg, Scope, Built) ->
    case assert_unique_modules(Built) of
        {error, Reason} ->
            {error, format_error(Reason)};
        ok ->
            DryRun = proplists:get_bool(check, args(State)),
            GenDir = gen_dir(State, Cfg),
            case maybe_write(DryRun, Scope, GenDir, Built) of
                {error, Reason} ->
                    {error, format_error(Reason)};
                ok ->
                    run_key_check(State, Cfg, Built)
            end
    end.

%% =========================
%% Config accessors
%% =========================

%% The plugin's `rebar.config` surface under the `erli18n` key, normalised to a
%% proplist (a non-list config value — a misconfiguration — degrades to the
%% empty list, i.e. all-defaults, rather than crashing the build).
-spec config(rebar3_erli18n_host:state()) -> [term()].
config(State) ->
    case rebar3_erli18n_host:get_config(State, ?NAMESPACE, []) of
        L when is_list(L) -> L;
        _Other -> []
    end.

%% Read a boolean config key, defaulting a missing/ill-typed value.
-spec cfg_bool(atom(), [term()], boolean()) -> boolean().
cfg_bool(Key, Cfg, Default) ->
    case proplists:get_value(Key, Cfg, Default) of
        true -> true;
        false -> false;
        _Other -> Default
    end.

%% The build-time anti-DoS caps. Defaults come from the runtime library
%% (`erli18n_server:default_max_bytes/0` and `default_max_entries/0`) as the
%% single source of truth, so the caps enforced at build time and at
%% `ensure_loaded/3` time never drift; a per-project `{max_po_bytes, _}` /
%% `{max_entries, _}` overrides, and `infinity` disables that cap.
-spec caps([term()]) -> caps().
caps(Cfg) ->
    #{
        max_bytes => cfg_bound(max_po_bytes, Cfg, erli18n_server:default_max_bytes()),
        max_entries => cfg_bound(max_entries, Cfg, erli18n_server:default_max_entries())
    }.

%% Read a non-negative-integer-or-`infinity` bound from config, defaulting a
%% missing or ill-typed value.
-spec cfg_bound(atom(), [term()], non_neg_integer() | infinity) -> non_neg_integer() | infinity.
cfg_bound(Key, Cfg, Default) ->
    case proplists:get_value(Key, Cfg, Default) of
        infinity -> infinity;
        N when is_integer(N), N >= 0 -> N;
        _Other -> Default
    end.

%% The parsed getopt args (the proplist half) for this command.
-spec args(rebar3_erli18n_host:state()) -> [{atom(), term()}].
args(State) ->
    rebar3_erli18n_host:parsed_args(State).

%% The generated-carrier output directory: the `{gen_dir}` config (default
%% `"src/erli18n_gen"`), resolved relative to the root app dir when relative.
-spec gen_dir(rebar3_erli18n_host:state(), [term()]) -> file:filename().
gen_dir(State, Cfg) ->
    Configured =
        case proplists:get_value(gen_dir, Cfg, ?DEFAULT_GEN_DIR) of
            Dir when is_list(Dir) -> Dir;
            _Other -> ?DEFAULT_GEN_DIR
        end,
    case filename:pathtype(Configured) of
        absolute -> Configured;
        _Relative -> filename:join(root_dir(State), Configured)
    end.

%% The root app directory (the first project app, or the state dir if there are
%% none) — the anchor for a relative `gen_dir`, mirroring the catalog root.
-spec root_dir(rebar3_erli18n_host:state()) -> file:filename().
root_dir(State) ->
    case rebar3_erli18n_host:project_apps(State) of
        [App | _] -> rebar3_erli18n_host:app_dir(App);
        [] -> rebar3_erli18n_host:state_dir(State)
    end.

%% The domain scoping: `all`, or `{only, Domains}` restricting both
%% codegen and the key check. `--domain` narrows the `{compiled_domains}` config
%% (or, when the config is `all`, pins to that single domain).
-spec scope_domains(rebar3_erli18n_host:state(), [term()]) ->
    {ok, all | {only, [binary()]}} | {error, {invalid_compiled_domains, [term()]}}.
scope_domains(State, Cfg) ->
    case base_scope(Cfg) of
        {error, _} = Err -> Err;
        {ok, Base} -> {ok, apply_cli_domain(State, Base)}
    end.

%% The `{compiled_domains, [atom()]}` config, normalised to binaries. A non-atom
%% entry is a configuration error and FAILS LOUDLY rather than being silently
%% dropped: silently dropping a `["default"]` string typo would scope the build
%% to nothing and (combined with pruning) wipe every carrier, so it is rejected.
%% Accepted config atoms are mapped to binaries via `atom_to_binary` (reading an
%% atom's name, interning nothing) so the scope threads as binary domains.
-spec base_scope([term()]) ->
    {ok, all | {only, [binary()]}} | {error, {invalid_compiled_domains, [term()]}}.
base_scope(Cfg) ->
    case proplists:get_value(compiled_domains, Cfg, all) of
        all ->
            {ok, all};
        List when is_list(List) ->
            case lists:all(fun is_atom/1, List) of
                true -> {ok, {only, [atom_to_binary(D, utf8) || D <- List, is_atom(D)]}};
                false -> {error, {invalid_compiled_domains, [D || D <- List, not is_atom(D)]}}
            end;
        Other ->
            {error, {invalid_compiled_domains, [Other]}}
    end.

%% Intersect the config scope with an optional `--domain` CLI override. The CLI
%% value is threaded as a binary (interning no atom): it is compared by value
%% against the binary config scope and, when the config is `all`, pins to that
%% single binary domain.
-spec apply_cli_domain(rebar3_erli18n_host:state(), all | {only, [binary()]}) ->
    all | {only, [binary()]}.
apply_cli_domain(State, Base) ->
    case proplists:get_value(domain, args(State)) of
        undefined ->
            Base;
        DStr when is_list(DStr) ->
            D = to_binary(DStr),
            case Base of
                all -> {only, [D]};
                {only, Domains} -> {only, [X || X <- Domains, X =:= D]}
            end
    end.

-spec in_scope(binary(), all | {only, [binary()]}) -> boolean().
in_scope(_Domain, all) -> true;
in_scope(Domain, {only, Domains}) -> lists:member(Domain, Domains).

%% =========================
%% Catalog discovery
%% =========================

%% Every `(Domain, Locale)` catalog under `PotDir` in scope, as
%% `{Domain, Locale, PoPath}`. Each `<Locale>/LC_MESSAGES/<Domain>.po`
%% contributes one catalog; `Locale` is canonicalised
%% (`erli18n:canonicalize_locale/1`) so two directory spellings of the same
%% logical locale (`pt_BR` and `pt-BR`) resolve to the SAME catalog and are
%% caught by the module-name collision guard rather than silently double-built.
-spec discover_catalogs(file:filename(), all | {only, [binary()]}) ->
    [{binary(), binary(), file:filename()}].
discover_catalogs(PotDir, Scope) ->
    LocaleDirs = [
        Dir
     || Dir <- lists:sort(filelib:wildcard(filename:join(PotDir, "*"))),
        filelib:is_dir(filename:join(Dir, "LC_MESSAGES"))
    ],
    Catalogs = lists:flatmap(fun(Dir) -> catalogs_in(Dir) end, LocaleDirs),
    [C || {Domain, _L, _P} = C <- Catalogs, in_scope(Domain, Scope)].

-spec catalogs_in(file:filename()) -> [{binary(), binary(), file:filename()}].
catalogs_in(LocaleDir) ->
    Locale = erli18n:canonicalize_locale(to_binary(filename:basename(LocaleDir))),
    Pos = lists:sort(filelib:wildcard(filename:join([LocaleDir, "LC_MESSAGES", "*.po"]))),
    [{domain_name(P), Locale, P} || P <- Pos].

%% The gettext domain of a `.po`, as the BINARY basename (sans `.po`). No atom
%% is interned from the filesystem name here; the carrier's domain atom is
%% interned by the compiler from `rebar3_erli18n_codegen:quote_atom_source/1`.
-spec domain_name(file:filename()) -> binary().
domain_name(PoPath) ->
    to_binary(filename:basename(PoPath, ".po")).

%% =========================
%% Build (parse + plural compile + render)
%% =========================

-spec build_all([{binary(), binary(), file:filename()}], boolean(), boolean(), caps()) ->
    {ok, [built()]} | {error, term()}.
build_all(Catalogs, IncludeFuzzy, NoWarn, Caps) ->
    build_all(Catalogs, IncludeFuzzy, NoWarn, Caps, []).

-spec build_all([{binary(), binary(), file:filename()}], boolean(), boolean(), caps(), [built()]) ->
    {ok, [built()]} | {error, term()}.
build_all([], _IncludeFuzzy, _NoWarn, _Caps, Acc) ->
    {ok, lists:reverse(Acc)};
build_all([{Domain, Locale, PoPath} | Rest], IncludeFuzzy, NoWarn, Caps, Acc) ->
    case build_one(Domain, Locale, PoPath, IncludeFuzzy, NoWarn, Caps) of
        {ok, Built} -> build_all(Rest, IncludeFuzzy, NoWarn, Caps, [Built | Acc]);
        {error, _} = Err -> Err
    end.

%% The size cap runs BEFORE the file is read into memory, so an over-large `.po`
%% is rejected loudly (via `filelib:file_size/1`) rather than risking an OOM at
%% build time — the same order the runtime loader uses.
-spec build_one(binary(), binary(), file:filename(), boolean(), boolean(), caps()) ->
    {ok, built()} | {error, term()}.
build_one(Domain, Locale, PoPath, IncludeFuzzy, NoWarn, #{max_bytes := MaxBytes} = Caps) ->
    case check_size(PoPath, MaxBytes) of
        {error, _} = Err ->
            Err;
        ok ->
            case file:read_file(PoPath) of
                {error, Reason} ->
                    {error, {po_parse_failed, PoPath, Reason}};
                {ok, Bin} ->
                    case erli18n_po:parse(Bin, #{include_fuzzy => IncludeFuzzy}) of
                        {error, Reason} ->
                            {error, {po_parse_failed, PoPath, Reason}};
                        {ok, Parsed} ->
                            build_parsed(Domain, Locale, PoPath, IncludeFuzzy, NoWarn, Caps, Parsed)
                    end
            end
    end.

%% The entry cap runs AFTER the parse (the count is only known then), mirroring
%% the runtime loader so a compiled carrier can never register more entries than
%% `ensure_loaded/3` would accept; within the cap, the baked header is built and
%% the carrier rendered.
-spec build_parsed(
    binary(), binary(), file:filename(), boolean(), boolean(), caps(), erli18n_po:parsed_catalog()
) ->
    {ok, built()} | {error, term()}.
build_parsed(Domain, Locale, PoPath, IncludeFuzzy, NoWarn, Caps, Parsed) ->
    #{header := Header, entries := Entries} = Parsed,
    #{max_entries := MaxEntries} = Caps,
    NumEntries = length(Entries),
    case within_entry_cap(NumEntries, MaxEntries) of
        {too_many, Max} ->
            {error, {too_many_entries, NumEntries, Max}};
        ok ->
            case baked_header(Domain, Locale, PoPath, IncludeFuzzy, Header, NumEntries) of
                {error, _} = Err ->
                    Err;
                {ok, Baked} ->
                    Spec = {Domain, Locale, Entries, Baked},
                    {Module, Source} = rebar3_erli18n_codegen:render(
                        Spec, #{eqwalizer_nowarn => NoWarn}
                    ),
                    {ok, #{
                        module => Module,
                        source => Source,
                        domain => Domain,
                        locale => Locale,
                        entries => Entries
                    }}
            end
    end.

%% Build the `baked_header()` at BUILD time, mirroring the runtime
%% `erli18n_server:stage_compiled/8` exactly (minus the `loaded_at` field, which
%% is stamped at registration): the same `plural_raw` fallback, the same
%% ahead-of-time plural compile, and the same vs-CLDR divergence. A broken
%% `Plural-Forms` rule aborts the build loudly. A non-`none` divergence is
%% emitted ONCE here at build time (the baked header still carries it, but
%% boot-time registration installs SILENTLY).
-spec baked_header(
    binary(), binary(), file:filename(), boolean(), erli18n_po:header_map(), non_neg_integer()
) ->
    {ok, erli18n_server:baked_header()} | {error, term()}.
baked_header(Domain, Locale, PoPath, IncludeFuzzy, Header, NumEntries) ->
    PluralRaw =
        case maps:get(plural_forms, Header, <<>>) of
            <<>> -> erli18n_plural:fallback_rule();
            Other -> Other
        end,
    case compile_plural(Header) of
        {error, Reason} ->
            {error, {plural_compile_error_at_codegen, Domain, Locale, Reason}};
        {ok, PluralCompiled} ->
            Divergence = divergence(Locale, PluralCompiled),
            emit_divergence(Domain, Locale, Divergence),
            {ok, #{
                plural => PluralCompiled,
                plural_raw => PluralRaw,
                po_path => to_binary(PoPath),
                divergence => Divergence,
                fuzzy_included => IncludeFuzzy,
                num_entries => NumEntries
            }}
    end.

%% Compile the plural header ahead of time, mirroring
%% `erli18n_server:maybe_compile_plural/1`: an absent/empty `Plural-Forms`
%% header yields the `fallback` sentinel; otherwise the raw rule is compiled.
-spec compile_plural(erli18n_po:header_map()) ->
    {ok, erli18n_plural:plural_compiled() | fallback} | {error, term()}.
compile_plural(Header) ->
    case maps:get(plural_forms, Header, <<>>) of
        <<>> ->
            {ok, fallback};
        PluralRaw ->
            erli18n_plural:compile(PluralRaw)
    end.

%% The vs-CLDR divergence, mirroring `erli18n_server:compute_divergence/2`:
%% `none` for the `fallback` rule or a locale absent from the CLDR table, else
%% the `{plural_divergence, HeaderRule, CldrRule}` payload.
-spec divergence(binary(), erli18n_plural:plural_compiled() | fallback) ->
    erli18n_server:divergence_info().
divergence(_Locale, fallback) ->
    none;
divergence(Locale, #{} = PluralCompiled) ->
    case erli18n_plural:validate_against_cldr_ast(Locale, PluralCompiled) of
        ok ->
            none;
        {warning, {plural_divergence, _Loc, HdrRule, CldrRule}} ->
            {plural_divergence, HdrRule, CldrRule}
    end.

%% Emit a vs-CLDR divergence ONCE at build time. Boot-time registration is
%% deliberately silent (the baked header still carries the divergence), so this
%% is the single place a maintainer is told a catalog's plural rule diverges.
-spec emit_divergence(binary(), binary(), erli18n_server:divergence_info()) -> ok.
emit_divergence(_Domain, _Locale, none) ->
    ok;
emit_divergence(Domain, Locale, {plural_divergence, HdrRule, CldrRule}) ->
    rebar3_erli18n_host:warn(
        "erli18n compile: ~ts/~ts plural rule diverges from CLDR "
        "(header ~ts vs CLDR ~ts); compiling the header rule as written.",
        [Domain, Locale, HdrRule, CldrRule]
    ).

%% =========================
%% Module-name uniqueness
%% =========================

%% Every `{Domain, Locale}` must mangle to a UNIQUE carrier module name. The
%% mangling is injective over distinct pairs, so a collision means two source
%% catalogs resolved to the SAME logical `(Domain, Locale)` — e.g. a `pt_BR` and
%% a `pt-BR` directory both canonicalising to `pt_BR`. That is an ambiguous
%% source tree, aborted loudly rather than silently double-built.
-spec assert_unique_modules([built()]) -> ok | {error, term()}.
assert_unique_modules(Built) ->
    Folded = lists:foldl(
        fun(#{module := Mod, domain := D, locale := L}, Acc) ->
            maps:update_with(Mod, fun(Ps) -> [{D, L} | Ps] end, [{D, L}], Acc)
        end,
        #{},
        Built
    ),
    Collisions = [
        {Mod, lists:reverse(Pairs)}
     || {Mod, Pairs} <- maps:to_list(Folded), length(Pairs) > 1
    ],
    case Collisions of
        [] -> ok;
        [{Mod, Pairs} | _] -> {error, {module_name_collision, Mod, Pairs}}
    end.

%% =========================
%% Writing carriers
%% =========================

%% Write the carriers (and the `.gitignore`) and prune orphaned carriers, unless
%% this is a `--check` dry run (which writes NOTHING).
-spec maybe_write(boolean(), all | {only, [binary()]}, file:filename(), [built()]) ->
    ok | {error, term()}.
maybe_write(true, _Scope, _GenDir, _Built) ->
    ok;
maybe_write(false, Scope, GenDir, Built) ->
    chain([
        fun() -> ensure_gen_dir(GenDir) end,
        fun() -> write_gitignore(GenDir) end,
        fun() -> write_modules(GenDir, Built) end,
        fun() -> maybe_prune(Scope, GenDir, Built) end
    ]).

%% Orphan pruning (deleting carriers whose `.po` is gone) is a WHOLE-TREE
%% maintenance step, so it runs ONLY on a full build (`Scope =:= all` — the
%% default `rebar3 erli18n compile` / pre-compile-hook invocation). A scoped
%% build (`--domain X` or `{compiled_domains, [...]}`) is an explicit partial
%% build; pruning there would delete the OTHER domains' still-valid carriers
%% (they were not built this run but their `.po` is intact), so it is skipped.
%% A full build still cleans every genuine orphan.
-spec maybe_prune(all | {only, [binary()]}, file:filename(), [built()]) ->
    ok | {error, term()}.
maybe_prune(all, GenDir, Built) ->
    prune_orphans(GenDir, Built);
maybe_prune({only, _Domains}, _GenDir, _Built) ->
    ok.

%% Run a list of `() -> ok | {error, _}` steps, short-circuiting on the first
%% error.
-spec chain([fun(() -> ok | {error, term()})]) -> ok | {error, term()}.
chain([]) ->
    ok;
chain([Step | Rest]) ->
    case Step() of
        ok -> chain(Rest);
        {error, _} = Err -> Err
    end.

-spec ensure_gen_dir(file:filename()) -> ok | {error, term()}.
ensure_gen_dir(GenDir) ->
    case filelib:ensure_path(GenDir) of
        ok -> ok;
        {error, Reason} -> {error, {codegen_write_failed, GenDir, Reason}}
    end.

-spec write_gitignore(file:filename()) -> ok | {error, term()}.
write_gitignore(GenDir) ->
    write_file(filename:join(GenDir, ".gitignore"), ?GITIGNORE_BODY).

-spec write_modules(file:filename(), [built()]) -> ok | {error, term()}.
write_modules(_GenDir, []) ->
    ok;
write_modules(GenDir, [#{module := Mod, source := Source} | Rest]) ->
    Path = filename:join(GenDir, <<Mod/binary, ".erl">>),
    case write_file(Path, to_binary(Source)) of
        ok -> write_modules(GenDir, Rest);
        {error, _} = Err -> Err
    end.

-spec write_file(file:filename(), binary()) -> ok | {error, term()}.
write_file(Path, Bin) ->
    case file:write_file(Path, Bin) of
        ok -> ok;
        {error, Reason} -> {error, {codegen_write_failed, Path, Reason}}
    end.

%% Delete any `erli18n_cc_*.erl` carrier in `GenDir` that the CURRENT build did
%% not produce, so a deleted `.po` does not leave a stale carrier behind.
-spec prune_orphans(file:filename(), [built()]) -> ok | {error, term()}.
prune_orphans(GenDir, Built) ->
    Keep = sets:from_list(
        [binary_to_list(Mod) ++ ".erl" || #{module := Mod} <- Built], [{version, 2}]
    ),
    Existing = filelib:wildcard(filename:join(GenDir, "erli18n_cc_*.erl")),
    Orphans = [F || F <- Existing, not sets:is_element(filename:basename(F), Keep)],
    delete_all(Orphans).

-spec delete_all([file:filename()]) -> ok | {error, term()}.
delete_all([]) ->
    ok;
delete_all([F | Rest]) ->
    case file:delete(F) of
        ok -> delete_all(Rest);
        {error, Reason} -> {error, {codegen_write_failed, F, Reason}}
    end.

%% =========================
%% Folded key check (domain scoping)
%% =========================

%% Run the compiled-catalog key-existence check after codegen. The compiled key
%% universe is built from the just-parsed catalog entries (scoped to the
%% compiled domains); the call sites come from `extract_project/1`.
%% `off` short-circuits without extracting; `warn` logs each diagnostic and
%% succeeds; `strict` fails the build.
-spec run_key_check(rebar3_erli18n_host:state(), [term()], [built()]) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
run_key_check(State, Cfg, Built) ->
    case resolve_policy(State, Cfg) of
        off ->
            {ok, State};
        Policy ->
            case rebar3_erli18n_common:extract_project(State) of
                {error, Reason} ->
                    {error, format_error(Reason)};
                {ok, CallSites} ->
                    Universe = atom_keyed_universe(key_universe(Built), CallSites),
                    decide_key_check(
                        State,
                        Policy,
                        rebar3_erli18n_keycheck:check(Universe, CallSites, Policy)
                    )
            end
    end.

-spec decide_key_check(
    rebar3_erli18n_host:state(), warn | strict, ok | {violations, [rebar3_erli18n_keycheck:diag()]}
) ->
    {ok, rebar3_erli18n_host:state()} | {error, string()}.
decide_key_check(State, _Policy, ok) ->
    {ok, State};
decide_key_check(State, warn, {violations, Diags}) ->
    lists:foreach(
        fun(Diag) ->
            rebar3_erli18n_host:warn("~ts", [rebar3_erli18n_keycheck:format_diag(Diag)])
        end,
        Diags
    ),
    {ok, State};
decide_key_check(_State, strict, {violations, Diags}) ->
    {error, format_error({missing_keys, Diags})}.

%% The per-domain compiled key universe: for each compiled domain, the UNION
%% across its compiled locales of every entry's `{Context, Msgid}` identity key.
-spec key_universe([built()]) ->
    #{binary() => sets:set({undefined | binary(), binary()})}.
key_universe(Built) ->
    lists:foldl(
        fun(#{domain := Domain, entries := Entries}, Acc) ->
            Keys = sets:from_list(
                [rebar3_erli18n_common:entry_key(E) || E <- Entries], [{version, 2}]
            ),
            maps:update_with(Domain, fun(S) -> sets:union(S, Keys) end, Keys, Acc)
        end,
        #{},
        Built
    ).

%% Re-key the binary-keyed compiled universe to the ATOM-keyed shape
%% `rebar3_erli18n_keycheck:check/3` consumes, WITHOUT interning any atom from a
%% domain string: fold over the call sites' atom keys (the only atoms ever passed
%% to the checker), read each name with `atom_to_binary` (interning nothing), and
%% carry over the matching binary-keyed universe set. The result is the universe
%% restricted to the domains present in BOTH maps. `keycheck:collect/2` only
%% indexes the universe by call-site keys, so this intersection yields IDENTICAL
%% diagnostics to an atom-keyed full universe; a universe-only domain (with no
%% call site) is dropped exactly as the checker's domain-scoping skip would drop it, and
%% threading the call-site atoms straight through avoids a never-called domain's
%% name forcing a `binary_to_existing_atom` badarg.
-spec atom_keyed_universe(
    #{binary() => sets:set({undefined | binary(), binary()})},
    #{atom() => [rebar3_erli18n_common:dedup_entry()]}
) ->
    #{atom() => sets:set({undefined | binary(), binary()})}.
atom_keyed_universe(UniBin, CallSites) ->
    maps:fold(
        fun(DAtom, _Entries, Acc) ->
            case maps:find(atom_to_binary(DAtom, utf8), UniBin) of
                {ok, KeySet} -> Acc#{DAtom => KeySet};
                error -> Acc
            end
        end,
        #{},
        CallSites
    ).

%% Resolve the key-check policy. Precedence: `--no-key-check` > `--strict` /
%% `--check` > the `{key_check}` config > the default `warn`. `--check` is a CI
%% dry run, so it enforces (strict) while writing nothing.
-spec resolve_policy(rebar3_erli18n_host:state(), [term()]) -> rebar3_erli18n_keycheck:policy().
resolve_policy(State, Cfg) ->
    Args = args(State),
    case proplists:get_bool(no_key_check, Args) of
        true ->
            off;
        false ->
            case proplists:get_bool(strict, Args) orelse proplists:get_bool(check, Args) of
                true -> strict;
                false -> normalize_policy(proplists:get_value(key_check, Cfg, warn))
            end
    end.

%% Normalise a `{key_check}` config value to a policy; an unknown atom degrades
%% to `warn` (logged once per run).
-spec normalize_policy(term()) -> rebar3_erli18n_keycheck:policy().
normalize_policy(off) ->
    off;
normalize_policy(warn) ->
    warn;
normalize_policy(strict) ->
    strict;
normalize_policy(Other) ->
    rebar3_erli18n_host:warn(
        "erli18n compile: unknown {key_check, ~p} in rebar.config; using 'warn'.",
        [Other]
    ),
    warn.

%% =========================
%% Helpers
%% =========================

%% Narrow a directory/locale name to a binary. Catalog directory names are valid
%% char data, so the conversion always yields a binary; the assertion narrows
%% the union result and an impossible non-binary crashes explicitly.
-spec to_binary(unicode:chardata()) -> binary().
to_binary(Chars) ->
    Bin = unicode:characters_to_binary(Chars),
    true = is_binary(Bin),
    Bin.

%% Size cap applied BEFORE reading the whole file into memory, mirroring
%% `erli18n_server:check_size/2`: `filelib:file_size/1` stats the file without
%% loading its bytes, so an over-large `.po` is rejected loudly here instead of
%% risking an OOM. `infinity` disables the cap.
-spec check_size(file:filename(), non_neg_integer() | infinity) ->
    ok | {error, {input_too_large, non_neg_integer(), non_neg_integer()}}.
check_size(_PoPath, infinity) ->
    ok;
check_size(PoPath, MaxBytes) when is_integer(MaxBytes) ->
    case filelib:file_size(PoPath) of
        Size when Size =< MaxBytes ->
            ok;
        Size ->
            {error, {input_too_large, Size, MaxBytes}}
    end.

%% Entry-count cap applied AFTER the parse, mirroring
%% `erli18n_server:within_entry_cap/2`: `ok` within the cap, or `{too_many, Max}`
%% carrying the INTEGER cap when exceeded (`infinity` never reaches the error
%% path).
-spec within_entry_cap(non_neg_integer(), non_neg_integer() | infinity) ->
    ok | {too_many, non_neg_integer()}.
within_entry_cap(_N, infinity) ->
    ok;
within_entry_cap(N, Max) when is_integer(Max) ->
    case N =< Max of
        true -> ok;
        false -> {too_many, Max}
    end.
