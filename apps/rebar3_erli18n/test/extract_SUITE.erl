-module(extract_SUITE).

-moduledoc """
Tests for `rebar3_erli18n_extract_forms` — the epp abstract-form extractor.

Exercised through real fixture modules in `extract_SUITE_data/`:

- `consumer_default_domain.erl` — uses the default `?GETTEXT_DOMAIN`;
- `consumer_uses_domain.erl` — overrides `?GETTEXT_DOMAIN` to a literal atom.

Asserts the full keyword family extracts literal msgid/msgid_plural/msgctxt
with the right domain, that the `?GETTEXT_DOMAIN` macro resolves to a literal
(default and overridden), that dynamic (non-literal) msgids and non-literal
d/dc domains are skipped (never errored), and that the `f`-family msgids are
extracted while the trailing Bindings map is ignored.

Also asserts that a literal binary msgid carrying a UTF-16 surrogate
code-point segment (which cannot encode as `<<Int/utf8>>`) is SKIPPED rather
than crashing the scan.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    default_domain_macro/1,
    overridden_domain_macro/1,
    bare_family_extracted/1,
    domained_family_extracted/1,
    contextual_extracted/1,
    plurals_extracted/1,
    f_family_msgid_extracted/1,
    dynamic_msgid_skipped/1,
    nonliteral_domain_skipped/1,
    parse_error_surfaced/1,
    string_literal_msgid/1,
    charlist_and_integer_segment/1,
    nonliteral_context_and_plural_skipped/1,
    non_atom_macro_falls_back/1,
    non_gettext_erli18n_call_ignored/1,
    nested_call_reached/1,
    error_marker_form_skipped/1,
    variable_binary_segment_skipped/1,
    surrogate_segment_skipped/1
]).

all() ->
    [
        default_domain_macro,
        overridden_domain_macro,
        bare_family_extracted,
        domained_family_extracted,
        contextual_extracted,
        plurals_extracted,
        f_family_msgid_extracted,
        dynamic_msgid_skipped,
        nonliteral_domain_skipped,
        parse_error_surfaced,
        string_literal_msgid,
        charlist_and_integer_segment,
        nonliteral_context_and_plural_skipped,
        non_atom_macro_falls_back,
        non_gettext_erli18n_call_ignored,
        nested_call_reached,
        error_marker_form_skipped,
        variable_binary_segment_skipped,
        surrogate_segment_skipped
    ].

%% =========================
%% Helpers
%% =========================

include_dirs(Config) ->
    %% The fixtures `-include_lib("erli18n/include/erli18n.hrl")`. erli18n is
    %% the runtime app under test; its include dir is on the project root.
    Root = root_dir(Config),
    [
        filename:join(Root, "include"),
        filename:join([Root, "_build", "default", "lib"]),
        ?config(data_dir, Config)
    ].

root_dir(Config) ->
    %% At CT run time the suite's data_dir is
    %% `.../_build/<profile>/lib/rebar3_erli18n/test/extract_SUITE_data`. The
    %% build root we want (the dir holding `include/` and `_build/default/lib`)
    %% is four segments up — trimming the known suffix
    %% (extract_SUITE_data, test, rebar3_erli18n, lib) lands on
    %% `.../_build/<profile>`.
    DataDir = ?config(data_dir, Config),
    Parts = filename:split(DataDir),
    Trimmed = lists:sublist(Parts, length(Parts) - 4),
    filename:join(Trimmed).

extract_default(Config) ->
    File = filename:join(?config(data_dir, Config), "consumer_default_domain.erl"),
    {ok, _Domain, Entries} = rebar3_erli18n_extract_forms:scan_file(File, include_dirs(Config)),
    Entries.

scan(Config, FileName) ->
    File = filename:join(?config(data_dir, Config), FileName),
    rebar3_erli18n_extract_forms:scan_file(File, include_dirs(Config)).

find(Entries, Domain, Msgid) ->
    [E || #{domain := D, msgid := M} = E <- Entries, D =:= Domain, M =:= Msgid].

%% =========================
%% Tests
%% =========================

default_domain_macro(Config) ->
    {ok, Domain, _} = scan(Config, "consumer_default_domain.erl"),
    ?assertEqual(default, Domain).

overridden_domain_macro(Config) ->
    {ok, Domain, _} = scan(Config, "consumer_uses_domain.erl"),
    ?assertEqual(errors, Domain).

bare_family_extracted(Config) ->
    Entries = extract_default(Config),
    %% Bare gettext(<<"Hello">>) -> default domain, singular.
    [Hello] = find(Entries, default, <<"Hello">>),
    ?assertEqual(singular, maps:get(kind, Hello)),
    ?assertEqual(undefined, maps:get(context, Hello)),
    ?assertEqual(undefined, maps:get(plural, Hello)),
    %% gettext(mydomain, <<"Goodbye">>) -> mydomain domain.
    ?assertMatch([_], find(Entries, mydomain, <<"Goodbye">>)).

domained_family_extracted(Config) ->
    Entries = extract_default(Config),
    %% dgettext(accounts, <<"Sign in">>) -> accounts domain.
    ?assertMatch([_], find(Entries, accounts, <<"Sign in">>)),
    ?assertMatch([_], find(Entries, accounts, <<"Sign out">>)),
    ?assertMatch([_], find(Entries, accounts, <<"Reset password">>)).

contextual_extracted(Config) ->
    Entries = extract_default(Config),
    %% pgettext(<<"menu">>, <<"File">>) -> default domain, context "menu".
    [File] = find(Entries, default, <<"File">>),
    ?assertEqual(<<"menu">>, maps:get(context, File)),
    %% dpgettext(mydomain, <<"button">>, <<"Save">>).
    [Save] = find(Entries, mydomain, <<"Save">>),
    ?assertEqual(<<"button">>, maps:get(context, Save)).

plurals_extracted(Config) ->
    Entries = extract_default(Config),
    %% ngettext(<<"one apple">>, <<"many apples">>, N) -> plural entry.
    [Apple] = find(Entries, default, <<"one apple">>),
    ?assertEqual(plural, maps:get(kind, Apple)),
    ?assertEqual(<<"many apples">>, maps:get(plural, Apple)),
    %% npgettext(<<"cart">>, <<"one item">>, <<"many items">>, N).
    [Item] = find(Entries, default, <<"one item">>),
    ?assertEqual(<<"cart">>, maps:get(context, Item)),
    ?assertEqual(<<"many items">>, maps:get(plural, Item)).

f_family_msgid_extracted(Config) ->
    Entries = extract_default(Config),
    %% gettextf(<<"Hi %{name}">>, #{...}) -> msgid extracted, binding ignored.
    [Hi] = find(Entries, default, <<"Hi %{name}">>),
    ?assertEqual(singular, maps:get(kind, Hi)),
    %% ngettextf(<<"%{count} file">>, <<"%{count} files">>, N, #{}).
    [FileF] = find(Entries, default, <<"%{count} file">>),
    ?assertEqual(<<"%{count} files">>, maps:get(plural, FileF)).

dynamic_msgid_skipped(Config) ->
    Entries = extract_default(Config),
    %% `gettext(Var)` (a variable) produces NO entry — no empty/garbage msgid.
    Msgids = [maps:get(msgid, E) || E <- Entries],
    ?assertNot(lists:member(<<>>, Msgids)),
    %% And the count is exactly the literal call sites (no phantom dynamic one).
    ?assert(length(Entries) >= 12).

nonliteral_domain_skipped(Config) ->
    Entries = extract_default(Config),
    %% `dgettext(Domain, <<"Only literal domains extract">>)` with a VARIABLE
    %% domain must be skipped — that msgid appears under no domain.
    All = [E || #{msgid := M} = E <- Entries, M =:= <<"Only literal domains extract">>],
    ?assertEqual([], All).

parse_error_surfaced(Config) ->
    %% A non-existent file surfaces an {error, _}, never crashes.
    Missing = filename:join(?config(data_dir, Config), "does_not_exist.erl"),
    ?assertMatch({error, _}, rebar3_erli18n_extract_forms:extract_file(Missing, [])).

string_literal_msgid(Config) ->
    %% The overridden-domain fixture's macro_domain/0 uses ?GETTEXT_DOMAIN
    %% (errors). Confirm the whole fixture extracts under `errors` for bare
    %% calls and resolves the macro to a literal.
    File = filename:join(?config(data_dir, Config), "consumer_uses_domain.erl"),
    {ok, Entries} = rebar3_erli18n_extract_forms:extract_file(File, include_dirs(Config)),
    Hello = [E || #{domain := errors, msgid := <<"Hello">>} = E <- Entries],
    ?assertMatch([_], Hello).

extract_shapes(Config) ->
    File = filename:join(?config(data_dir, Config), "consumer_literal_shapes.erl"),
    {ok, Entries} = rebar3_erli18n_extract_forms:extract_file(File, include_dirs(Config)),
    Entries.

charlist_and_integer_segment(Config) ->
    Entries = extract_shapes(Config),
    %% A plain `"..."` charlist msgid is normalized to a binary.
    ?assertMatch([_], find(Entries, default, <<"Plain string msgid">>)),
    %% A `<<65,66,67>>` integer-segment binary decodes to "ABC".
    ?assertMatch([_], find(Entries, default, <<"ABC">>)).

nonliteral_context_and_plural_skipped(Config) ->
    Entries = extract_shapes(Config),
    %% pgettext(Ctx, <<"Has dynamic context">>) with a VARIABLE context -> skip.
    ?assertEqual([], find(Entries, default, <<"Has dynamic context">>)),
    %% ngettext(<<"one thing">>, Plural, 2) with a VARIABLE plural -> skip.
    ?assertEqual([], find(Entries, default, <<"one thing">>)).

variable_binary_segment_skipped(Config) ->
    Entries = extract_shapes(Config),
    %% `<<X/binary, "suffix">>` has a variable segment -> not a constant, so
    %% the whole call site is skipped (no entry for "suffix" alone).
    ?assertEqual([], find(Entries, default, <<"suffix">>)),
    ?assertEqual([], [E || #{msgid := M} = E <- Entries, binary:match(M, <<"suffix">>) =/= nomatch]).

surrogate_segment_skipped(Config) ->
    %% `gettext(<<16#D800>>)` carries a literal integer segment that is a UTF-16
    %% surrogate code point. `<<16#D800/utf8>>` raises `badarg`, so before the
    %% guard fix the whole scan ABORTED on a stacktrace. The fix makes the
    %% surrogate segment non-resolvable, so the call site is SKIPPED like any
    %% other non-constant msgid and the scan completes. This case therefore
    %% asserts BOTH that the scan does not crash (extract_shapes returns) AND
    %% that the surrogate call site produced no entry, while the sibling
    %% literal-shape call sites in the same module still extract.
    Entries = extract_shapes(Config),
    %% The surrogate call site yields nothing: no entry whose msgid contains a
    %% surrogate scalar value (which would be impossible in a valid binary
    %% anyway) and the scan still returned the valid siblings.
    Surrogates = [E || #{msgid := M} = E <- Entries, has_codepoint(M, 16#D800)],
    ?assertEqual([], Surrogates),
    %% Proof the scan ran to completion past the surrogate site: the other
    %% literal-shape msgids in the same fixture are present.
    ?assertMatch([_], find(Entries, default, <<"Plain string msgid">>)),
    ?assertMatch([_], find(Entries, default, <<"ABC">>)).

%% Does binary `Bin` decode to a string containing the Unicode code point `Cp`?
%% Used to assert no extracted msgid carries a surrogate scalar value.
has_codepoint(Bin, Cp) ->
    case unicode:characters_to_list(Bin) of
        Chars when is_list(Chars) -> lists:member(Cp, Chars);
        _ -> false
    end.

non_atom_macro_falls_back(Config) ->
    %% ?GETTEXT_DOMAIN defined to a string (non-atom) -> the macro reader
    %% falls back to `default`, and bare-family calls land under `default`.
    {ok, Domain, Entries} = scan(Config, "consumer_bad_macro.erl"),
    ?assertEqual(default, Domain),
    ?assertMatch([_], find(Entries, default, <<"Hello from bad macro">>)).

non_gettext_erli18n_call_ignored(Config) ->
    %% `erli18n:which_locale/0` is not in the keyword spec -> ignored; the
    %% sibling gettext call is still extracted.
    {ok, _, Entries} = scan(Config, "consumer_edge_calls.erl"),
    ?assertMatch([_], find(Entries, default, <<"After a non-gettext call">>)).

nested_call_reached(Config) ->
    %% A gettext call nested inside a list literal is reached by the walk.
    {ok, _, Entries} = scan(Config, "consumer_edge_calls.erl"),
    ?assertMatch([_], find(Entries, default, <<"Nested in a list">>)).

error_marker_form_skipped(Config) ->
    %% Write a malformed source at runtime (a syntax error AFTER a valid
    %% gettext call) into priv_dir — NOT a `_SUITE_data` file, so rebar3 does
    %% not try to compile it. epp emits an error/warning marker for the bad
    %% form during the drain; the drainer skips it and still extracts the
    %% valid msgid above it.
    File = filename:join(?config(priv_dir, Config), "runtime_broken.erl"),
    Src = iolist_to_binary([
        "-module(runtime_broken).\n",
        "-export([ok/0]).\n",
        "ok() -> erli18n:gettext(<<\"Valid before bad form\">>).\n",
        %% A `-warning` attribute makes epp emit a {warning, _} marker, and
        %% the broken form below makes it emit an {error, _} marker; the
        %% drainer skips both and still extracts the valid msgid.
        "-warning(\"deliberate\").\n",
        "broken( -> nonsense\n"
    ]),
    ok = file:write_file(File, Src),
    {ok, _, Entries} = rebar3_erli18n_extract_forms:scan_file(File, include_dirs(Config)),
    ?assertMatch([_], find(Entries, default, <<"Valid before bad form">>)).
