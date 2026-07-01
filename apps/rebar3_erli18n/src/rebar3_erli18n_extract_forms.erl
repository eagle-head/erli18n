-module(rebar3_erli18n_extract_forms).

-moduledoc """
Abstract-form extractor for erli18n facade call sites.

Reads an Erlang source file through `epp` (NOT text scanning), so every
macro — including the public `?GETTEXT_DOMAIN` from `include/erli18n.hrl` —
is expanded to a literal node BEFORE the walk. It then walks the parsed
forms looking for remote calls `erli18n:Fn(Args)` whose `{Fn, Arity}` is in
the keyword spec (`rebar3_erli18n_keywords`), and pulls the literal
`msgid`/`msgid_plural`/`msgctxt` and the literal-atom `Domain`.

## What is extractable, what is skipped

Only COMPILE-TIME-CONSTANT operands are extracted, exactly as Elixir Gettext
documents the dynamic-key caveat:

- `msgid`/`msgid_plural`/`msgctxt` must be a literal string (`"..."`) or a
  literal binary (`<<"...">>` / `~"..."`). A variable, concatenation, or any
  other expression in those slots SKIPS the whole call site — never errors.
- `Domain` (d/dc families) must be a literal atom after expansion. A
  non-literal Domain SKIPS the call site rather than mis-domaining it. The
  bare families (no Domain slot) are keyed under the module's
  `?GETTEXT_DOMAIN`, which `epp` has already expanded to a literal atom.

This is what guarantees the `check` gate never false-fails on a legitimately
dynamic key: a dynamic operand simply produces no `.pot` entry.

## Output

`extract_file/2` returns a list of `extracted()` records — one per recognized
call site — carrying the source reference `{File, Line}` so the `.pot` writer
can emit `#:` reference lines.
""".

-export([extract_file/2, scan_file/2]).

-export_type([extracted/0]).

-doc """
One extracted catalog entry plus its source location.

`domain` is the resolved literal atom. `kind` is `singular` or `plural`.
`context` is `undefined` or the literal binary `msgctxt`. `msgid` is the
literal binary. `plural` is `undefined` (singular) or the literal binary
`msgid_plural`. `reference` is `{RelPath, Line}` for the `#:` line.
""".
-type extracted() :: #{
    domain := atom(),
    kind := rebar3_erli18n_keywords:kind(),
    context := undefined | binary(),
    msgid := binary(),
    plural := undefined | binary(),
    reference := {file:filename(), pos_integer()}
}.

%% Include directories handed to epp so `-include_lib("erli18n/...")` and
%% project-local includes resolve.
-doc """
Parse `File` through `epp` and extract every recognized erli18n call site,
using the module's own `?GETTEXT_DOMAIN` for bare-family calls.

A thin wrapper over `scan_file/2` that drops the resolved domain. Returns
`{ok, [extracted()]}` on success, or `{error, Reason}` if `epp` cannot open
the file.
""".
-spec extract_file(file:filename(), [file:filename()]) ->
    {ok, [extracted()]} | {error, term()}.
extract_file(File, IncludeDirs) ->
    case scan_file(File, IncludeDirs) of
        {ok, _Domain, Entries} -> {ok, Entries};
        {error, _} = Err -> Err
    end.

-doc """
Parse `File` through `epp` ONCE, returning both the module's expanded
`?GETTEXT_DOMAIN` and the extracted call sites.

This is the single-pass entry point the provider walk uses: it opens one
`epp` handle, drains every form (so all `-define`/`-include` directives are
applied), reads `?GETTEXT_DOMAIN` from the macro table, and walks the
drained forms for facade call sites — avoiding a second parse and the
redundant error branch a two-call sequence would carry.

Returns `{ok, Domain, [extracted()]}` or `{error, Reason}` when `epp` cannot
open the file.
""".
-spec scan_file(file:filename(), [file:filename()]) ->
    {ok, atom(), [extracted()]} | {error, term()}.
scan_file(File, IncludeDirs) ->
    case epp:open([{name, File}, {includes, IncludeDirs}]) of
        {ok, Epp} ->
            Forms = drain_forms(Epp, []),
            Macros = epp:macro_defs(Epp),
            epp:close(Epp),
            Domain = macro_atom(Macros, 'GETTEXT_DOMAIN', default),
            {ok, Domain, walk_forms(Forms, File, Domain)};
        {error, Reason} ->
            {error, Reason}
    end.

%% Collect every form from an open epp handle (in source order), skipping
%% the error/warning/eof markers — the walk only cares about real forms.
-spec drain_forms(pid(), [term()]) -> [term()].
drain_forms(Epp, Acc) ->
    case epp:parse_erl_form(Epp) of
        {eof, _} -> lists:reverse(Acc);
        {ok, Form} -> drain_forms(Epp, [Form | Acc]);
        {error, _} -> drain_forms(Epp, Acc);
        {warning, _} -> drain_forms(Epp, Acc)
    end.

%% The abstract-form list `epp` yields is a union of real forms and
%% `{error, _}` / `{eof, _}` markers; the recursive walk treats every node as
%% an untyped term and pattern-matches the shapes it cares about, ignoring the
%% rest. We enter the walk through a single identity cast that re-announces
%% the node as `dynamic()` rather than threading the loose epp union through
%% every clause.
%%
%% A plain identity whose `-spec` re-announces the result as `dynamic()`;
%% eqwalizer accepts assigning any term to `dynamic()`, so no annotation is
%% needed. This deliberately does NOT use a runtime `eqwalizer:dynamic_cast/1`
%% call (that helper lives in the test-only `eqwalizer_support` dep, would be
%% `undefined` in a real build, and adds a runtime hop). See
%% `erli18n_server:cast_ensure_result/1` for the same zero-cost approach.
-spec dyn(term()) -> dynamic().
dyn(Term) ->
    Term.

%% Read a zero-arity (object-like) macro's literal-atom value out of
%% `epp:macro_defs/1`. The shape is
%% `{{atom, Name}, [{none, {_Use, Tokens}}]}` — the value is a LIST of
%% arity-keyed definitions; the object-like one is keyed `none` and carries
%% the replacement token list. We accept exactly a single `{atom, _, Atom}`
%% token (a literal atom). Anything else (a non-atom macro, a multi-token
%% expansion, an undefined macro) falls back to `Default`.
-spec macro_atom([term()], atom(), atom()) -> atom().
macro_atom(Macros, Name, Default) ->
    case lists:keyfind({atom, Name}, 1, Macros) of
        {{atom, Name}, Defs} when is_list(Defs) ->
            case lists:keyfind(none, 1, Defs) of
                {none, {_Use, [{atom, _Anno, Atom}]}} when is_atom(Atom) -> Atom;
                _ -> Default
            end;
        _ ->
            Default
    end.

%% =========================
%% Form walk
%% =========================

%% The walk threads a single accumulator (extractions in reverse source
%% order) through the whole descent, prepending each call site exactly once.
%% This keeps the walk O(nodes): no per-level `lists:flatten`/`++` that would
%% re-copy the accumulated extractions at every recursion level
%% (that shape would be O(extractions × ast-depth)). The accumulator is reversed
%% once at the top, restoring source order.
-spec walk_forms([term()], file:filename(), atom()) -> [extracted()].
walk_forms(Forms, File, DefaultDomain) ->
    lists:reverse(walk_children(Forms, File, DefaultDomain, [])).

%% Recursively descend any abstract node, collecting extractions from every
%% `erli18n:Fn(Args)` remote call encountered. We do not special-case
%% function clauses vs expressions: a uniform descent over tuples/lists
%% reaches call sites wherever they appear (clause bodies, guards excluded
%% by Erlang syntax, list/tuple/map literals, etc.). The node is dynamic
%% (it comes from the epp form union via `dyn/1`), so the matched `Fn`/`Args`
%% flow on as dynamic and satisfy the typed call-site resolvers.
%%
%% `Acc` holds extractions found so far, in reverse source order; each clause
%% prepends its own finds and returns the extended accumulator.
-spec walk_node(dynamic(), file:filename(), atom(), [extracted()]) -> [extracted()].
walk_node(
    {call, _Anno, {remote, _RAnno, {atom, _MAnno, erli18n}, {atom, _FAnno, Fn}}, Args} =
        Node,
    File,
    DefaultDomain,
    Acc
) ->
    Here = extract_call(Fn, Args, anno_line(Node), File, DefaultDomain),
    %% Prepend this call site's finds (reversed so the final top-level reverse
    %% restores source order), then descend into the args.
    walk_children(Args, File, DefaultDomain, prepend_reverse(Here, Acc));
walk_node(Tuple, File, DefaultDomain, Acc) when is_tuple(Tuple) ->
    walk_children(tuple_to_list(Tuple), File, DefaultDomain, Acc);
walk_node(List, File, DefaultDomain, Acc) when is_list(List) ->
    walk_children(List, File, DefaultDomain, Acc);
walk_node(_Leaf, _File, _DefaultDomain, Acc) ->
    Acc.

%% Fold the walk over each child, threading the accumulator left to right so
%% extractions land in reverse source order (undone by the top-level reverse).
%% The children may themselves be the loose epp form union, so each is cast to
%% `dynamic()` via `dyn/1` before matching.
-spec walk_children([term()], file:filename(), atom(), [extracted()]) -> [extracted()].
walk_children(Children, File, DefaultDomain, Acc) ->
    lists:foldl(
        fun(Child, A) -> walk_node(dyn(Child), File, DefaultDomain, A) end,
        Acc,
        Children
    ).

%% Prepend a call-site result onto the reverse-order accumulator, reversing it
%% so that after the single top-level `lists:reverse/1` the entries come out in
%% source order. (A recognized call site yields 0 or 1 entries, but this
%% stays correct for any length without assuming that invariant.)
-spec prepend_reverse([extracted()], [extracted()]) -> [extracted()].
prepend_reverse([], Acc) -> Acc;
prepend_reverse([Entry | Rest], Acc) -> prepend_reverse(Rest, [Entry | Acc]).

%% =========================
%% Single call-site resolution
%% =========================

-spec extract_call(atom(), [dynamic()], pos_integer(), file:filename(), atom()) ->
    [extracted()].
extract_call(Fn, Args, Line, File, DefaultDomain) ->
    Arity = length(Args),
    case rebar3_erli18n_keywords:lookup(Fn, Arity) of
        error ->
            [];
        {ok, Slots} ->
            resolve(Slots, Args, Line, File, DefaultDomain)
    end.

-spec resolve(
    rebar3_erli18n_keywords:slots(), [dynamic()], pos_integer(), file:filename(), atom()
) ->
    [extracted()].
resolve(Slots, Args, Line, File, DefaultDomain) ->
    case resolve_domain(maps:get(domain, Slots), Args, DefaultDomain) of
        skip ->
            [];
        {ok, Domain} ->
            resolve_strings(Slots, Args, Domain, Line, File)
    end.

%% `from_macro` slot: the bare family carries no Domain argument, so the
%% entry is keyed under the module's epp-expanded `?GETTEXT_DOMAIN`
%% (`DefaultDomain`, resolved once per module by `default_domain/2`). The
%% d/dc families instead read the literal-atom Domain argument; a
%% non-literal Domain there SKIPS the call site rather than mis-domaining.
-spec resolve_domain(pos_integer() | from_macro, [dynamic()], atom()) ->
    {ok, atom()} | skip.
resolve_domain(from_macro, _Args, DefaultDomain) ->
    {ok, DefaultDomain};
resolve_domain(Index, Args, _DefaultDomain) when is_integer(Index) ->
    case literal_atom(lists:nth(Index, Args)) of
        {ok, Atom} -> {ok, Atom};
        error -> skip
    end.

-spec resolve_strings(
    rebar3_erli18n_keywords:slots(), [dynamic()], atom(), pos_integer(), file:filename()
) ->
    [extracted()].
resolve_strings(Slots, Args, Domain, Line, File) ->
    MsgidArg = lists:nth(maps:get(msgid, Slots), Args),
    case literal_string(MsgidArg) of
        error ->
            [];
        {ok, Msgid} ->
            case resolve_context(Slots, Args) of
                skip ->
                    [];
                {ok, Context} ->
                    case resolve_plural(Slots, Args) of
                        skip ->
                            [];
                        {ok, Plural} ->
                            [
                                #{
                                    domain => Domain,
                                    kind => maps:get(kind, Slots),
                                    context => Context,
                                    msgid => Msgid,
                                    plural => Plural,
                                    reference => {File, Line}
                                }
                            ]
                    end
            end
    end.

-spec resolve_context(rebar3_erli18n_keywords:slots(), [dynamic()]) ->
    {ok, undefined | binary()} | skip.
resolve_context(Slots, Args) ->
    resolve_optional_string(maps:get(context, Slots, undefined), Args).

-spec resolve_plural(rebar3_erli18n_keywords:slots(), [dynamic()]) ->
    {ok, undefined | binary()} | skip.
resolve_plural(Slots, Args) ->
    resolve_optional_string(maps:get(plural, Slots, undefined), Args).

%% Resolve an optional literal-string slot. `undefined` index means the
%% family has no such slot (-> `{ok, undefined}`); otherwise the argument at
%% that index must be a literal string, else the call site is skipped.
-spec resolve_optional_string(undefined | pos_integer(), [dynamic()]) ->
    {ok, undefined | binary()} | skip.
resolve_optional_string(undefined, _Args) ->
    {ok, undefined};
resolve_optional_string(Index, Args) when is_integer(Index) ->
    case literal_string(lists:nth(Index, Args)) of
        {ok, _Value} = Ok -> Ok;
        error -> skip
    end.

%% =========================
%% Literal resolution
%% =========================

%% A literal atom node, after epp expansion. The argument is a dynamic AST
%% node; a matched `{atom, _, Atom}` yields a genuine atom, narrowed with an
%% `is_atom/1` guard so the result type is honest.
-spec literal_atom(dynamic()) -> {ok, atom()} | error.
literal_atom({atom, _Anno, Atom}) when is_atom(Atom) -> {ok, Atom};
literal_atom(_) -> error.

%% A literal string the extractor accepts as a msgid/msgctxt/msgid_plural:
%%   * a binary literal `<<"...">>` / `~"..."` whose only segment is a
%%     UTF-8/default string,
%%   * a plain string literal `"..."` (charlist), normalized to a binary.
%% Anything else (variable, call, concatenation, interpolation) is `error`,
%% which skips the whole call site.
-spec literal_string(dynamic()) -> {ok, binary()} | error.
literal_string({bin, _Anno, Segments}) when is_list(Segments) ->
    bin_segments_to_binary(Segments, []);
literal_string({string, _Anno, Chars}) ->
    {ok, chars_to_binary(Chars)};
literal_string(_) ->
    error.

%% Fold a binary literal's segments into a single binary, accepting only
%% the constant-string shapes a translator-facing msgid takes: a literal
%% string segment (`<<"abc">>`) or a literal integer segment with default
%% size used as a character (`<<65>>`). A variable-sized or
%% expression-valued segment makes the whole literal non-constant -> error.
%%
%% An integer segment is accepted only when it is a valid Unicode scalar
%% value, i.e. in `0..16#10FFFF` AND outside the UTF-16 surrogate range
%% `16#D800..16#DFFF`. Surrogates are NOT valid scalar values: `<<Int/utf8>>`
%% raises `badarg` on them, so admitting them would crash the whole
%% extract/check/merge/report run on a stacktrace. Excluding them here makes
%% such a segment non-resolvable, so the call site is SKIPPED exactly like any
%% other non-compile-time-literal msgid (the documented dynamic-key-skip
%% contract) rather than aborting.
-spec bin_segments_to_binary([dynamic()], [binary()]) -> {ok, binary()} | error.
bin_segments_to_binary([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
bin_segments_to_binary([{bin_element, _Anno, {string, _SAnno, Chars}, default, _TS} | Rest], Acc) ->
    %% A `{string, _, Chars}` node came from the parser, so `Chars` is always
    %% a valid charlist; the conversion to a binary cannot fail.
    bin_segments_to_binary(Rest, [chars_to_binary(Chars) | Acc]);
bin_segments_to_binary(
    [{bin_element, _Anno, {integer, _IAnno, Int}, default, _TS} | Rest], Acc
) when
    is_integer(Int), Int >= 0, Int =< 16#10FFFF, (Int < 16#D800 orelse Int > 16#DFFF)
->
    bin_segments_to_binary(Rest, [<<Int/utf8>> | Acc]);
bin_segments_to_binary(_, _Acc) ->
    error.

%% Convert a parser-produced charlist to a binary. The input always comes
%% from a `{string, _, Chars}` AST node, so it is valid char data and the
%% conversion never returns an error tuple; the `is_binary` assertion makes
%% that contract explicit (a non-binary would crash here, not mis-extract).
-spec chars_to_binary(dynamic()) -> binary().
chars_to_binary(Chars) ->
    Bin = unicode:characters_to_binary(Chars),
    true = is_binary(Bin),
    Bin.

%% Line of an abstract node's annotation.
-spec anno_line(dynamic()) -> pos_integer().
anno_line(Node) ->
    erl_anno:line(element(2, Node)).
