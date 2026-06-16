-module(erli18n_interp).

-moduledoc """
Pure, total, fail-soft substituter for named `%{name}` placeholders.

This is the Phase 1 interpolation engine that backs the `f`-suffix family
on `erli18n` (`gettextf`, `ngettextf`, `pgettextf`, `npgettextf` and their
`d`/`dc` aliases). It takes a resolved translation `msgstr` plus a map of
`Bindings` and produces the final binary with each `%{name}` replaced by
its bound value.

## The problem it solves

A translated string frequently needs runtime values spliced in
(`<<"Hello, %{name}!">>`). gettext itself has no interpolation; consumers
usually hand-roll `io_lib:format/2` with positional `~s`, which couples the
translation to argument ORDER and breaks the moment a translator reorders
words. Named placeholders (`%{name}`) decouple the wording from the call
site: the translator can move `%{name}` anywhere in the sentence and the
binding still resolves by name.

## Mental model — totality on the hot path

`format/2` runs on EVERY `gettextf`/`ngettextf` lookup, so it carries the
SAME totality bar as `erli18n_plural:evaluate/2`: it is TOTAL and
fail-soft — for ANY `msgstr` bytes and ANY `Bindings` map it NEVER raises
and ALWAYS returns a binary. There is exactly one opt-in path allowed to
raise: `format/3` with `#{on_missing => strict}`, used when a caller wants
a missing binding to be a hard error rather than a silently-retained
literal.

The substitution is a single left-to-right pass over the input:

- `"%%"` collapses to a literal `"%"` (both bytes consumed).
- `"%{<name>}"`, where `<name>` matches `[A-Za-z_][A-Za-z0-9_]*`, is
  replaced by the bound value, or handled per the `on_missing` policy if
  the name is unbound.
- To emit a literal `"%{name}"` un-substituted, author `"%%{name}"`: the
  `"%%"` collapses to `"%"`, leaving the following `"{name}"` untouched.
- A lone `"%"` that begins neither `"%%"` nor a valid `"%{name}"`, and a
  `"%{"` that never closes into a valid placeholder, are emitted
  literally. Nothing crashes.

## Binding values and atom safety

Binding keys are atoms (`#{name => <<"World">>}`). Values may be a
`binary`, an iolist/string, an `integer`, a `float`, or an `atom`; every
value is coerced to UTF-8 text TOTALLY — an unknown or malformed term
renders via a bounded safe fallback rather than raising.

A placeholder name is resolved with `binary_to_existing_atom/2` wrapped in
`try`: a name that is not an already-existing atom is treated as a MISSING
binding and NEVER creates a new atom. This closes the atom-table-exhaustion
DoS that `binary_to_atom/2` would open on untrusted `msgstr`.

## Anti-DoS

Consistent with the project's plural caps (see `erli18n_plural` and
`include/erli18n.hrl`), the work is bounded fail-closed. Because `format/2`
must stay total, the lenient path CLAMPS rather than raises:

- `?MAX_OUTPUT_BYTES` (65536) — the accumulated output is truncated once it
  would exceed this size; the remaining input is dropped.
- `?MAX_EXPANSIONS` (1024) — once this many placeholders have been
  expanded, further `%{name}` references are emitted literally instead of
  substituted.
- `?MAX_NAME_BYTES` (256) — a `%{` whose name run exceeds this many bytes
  before the closing `}` is treated as a malformed reference and emitted
  literally (this also bounds the `binary_to_existing_atom/2` probe).

## Bidi (RTL) hazard

v1 does NOT auto-insert Unicode bidi isolation marks (U+2066..U+2069)
around interpolated values. Splicing an RTL value (Arabic/Hebrew) into an
LTR sentence — or vice versa — can therefore reorder neighbouring
punctuation under the Unicode Bidirectional Algorithm. Callers that mix
directions should isolate values themselves until a future version offers
opt-in isolation.

## Quickstart

```erlang
1> erli18n_interp:format(<<"Hello, %{name}!">>, #{name => <<"World">>}).
<<"Hello, World!">>
2> erli18n_interp:format(<<"%{a} then %{b}">>, #{a => 1, b => two}).
<<"1 then two">>
3> erli18n_interp:format(<<"100%% sure about %{x}">>, #{}).
<<"100% sure about %{x}">>
4> erli18n_interp:format(<<"need %{x}">>, #{}, #{on_missing => strict}).
** exception error: {erli18n_interp,{missing_binding,x}}
```
""".

-export([
    format/2,
    format/3
]).

-export_type([bindings/0, on_missing/0, opts/0]).

%% ===================================================================
%% Anti-DoS caps. Bound the work fail-closed, mirroring the plural caps
%% in `erli18n_plural`. On the lenient (total) path these CLAMP/truncate;
%% they never raise.
%% ===================================================================

%% Maximum number of UTF-8 bytes the result may reach before the pass
%% stops appending (truncation, fail-soft).
-define(MAX_OUTPUT_BYTES, 65536).

%% Maximum number of `%{name}` placeholders expanded in a single pass.
%% Beyond this, further references are emitted literally.
-define(MAX_EXPANSIONS, 1024).

%% Maximum byte length of a placeholder name run; also bounds the
%% `binary_to_existing_atom/2` probe against an atom-length DoS.
-define(MAX_NAME_BYTES, 256).

%% Maximum bytes rendered for a single coerced binding value (per-value
%% clamp so one huge value cannot blow the budget on its own).
-define(MAX_VALUE_BYTES, 8192).

-doc """
Map of placeholder bindings: atom keys to coercible values.

A key is the atom form of a `%{name}` placeholder. A value is coerced to
UTF-8 text totally and may be a `binary`, an iolist/string, an `integer`,
a `float`, or an `atom`. Any other term renders via a bounded safe
fallback instead of raising.
""".
-type bindings() :: #{atom() => term()}.

-doc """
Policy for a `%{name}` whose name resolves to no binding.

- `lenient` (default): the placeholder is emitted literally, unchanged
  (`%{name}` stays `%{name}`), and the pass continues. `format/2` always
  uses this policy.
- `strict`: the pass raises `error({erli18n_interp, {missing_binding,
  Name}})`. This is the ONLY path in the module allowed to raise and is
  opt-in via `format/3`.
""".
-type on_missing() :: lenient | strict.

-doc """
Options for `format/3`. Currently a single key, `on_missing`, defaulting
to `lenient` (which makes `format/3` equal to `format/2`).
""".
-type opts() :: #{on_missing => on_missing()}.

-doc """
Interpolate `%{name}` placeholders in `Msgstr` using `Bindings`, leniently.

TOTAL and fail-soft: for ANY `Msgstr` bytes and ANY `Bindings` map this
never raises and always returns a binary. A missing binding leaves its
`%{name}` literal in place. Equivalent to `format(Msgstr, Bindings,
#{on_missing => lenient})`.

See the module doc for the substitution grammar, value coercion, and the
anti-DoS caps.

## Examples

```erlang
1> erli18n_interp:format(<<"Hi %{who}">>, #{who => <<"Sam">>}).
<<"Hi Sam">>
2> erli18n_interp:format(<<"Hi %{who}">>, #{}).
<<"Hi %{who}">>
3> erli18n_interp:format(<<"50%% off">>, #{}).
<<"50% off">>
```
""".
-spec format(binary(), bindings()) -> binary().
format(Msgstr, Bindings) when is_binary(Msgstr), is_map(Bindings) ->
    format(Msgstr, Bindings, #{}).

-doc """
Interpolate `%{name}` placeholders in `Msgstr` using `Bindings`, with
`Opts` controlling the missing-binding policy.

`Opts` supports `#{on_missing => lenient | strict}`. With `lenient` (the
default) this is TOTAL and equals `format/2`. With `strict`, a `%{name}`
whose name has no binding raises `error({erli18n_interp, {missing_binding,
Name}})` — the only raising path in this module.

`Name` in the error is the atom form of the placeholder when it already
exists as an atom, otherwise the raw name binary (a non-existing atom name
is never interned).

## Examples

```erlang
1> erli18n_interp:format(<<"Hi %{who}">>, #{who => <<"Sam">>},
1>                       #{on_missing => strict}).
<<"Hi Sam">>
2> erli18n_interp:format(<<"Hi %{who}">>, #{},
2>                       #{on_missing => strict}).
** exception error: {erli18n_interp,{missing_binding,who}}
```
""".
-spec format(binary(), bindings(), opts()) -> binary().
format(Msgstr, Bindings, Opts) when
    is_binary(Msgstr), is_map(Bindings), is_map(Opts)
->
    OnMissing = on_missing(Opts),
    Acc = scan(Msgstr, Bindings, OnMissing, 0, 0, []),
    iolist_to_binary(lists:reverse(Acc)).

%% ===================================================================
%% Internal — single left-to-right pass with running output-size tracking.
%%
%% `scan/6` walks the input, building a REVERSED list of binary chunks
%% (left-side accumulator, flushed via `iolist_to_binary/1` for linear
%% concatenation — same idiom as `erli18n_po`). `Count` tracks expansions
%% for the anti-DoS cap. `OutSize` tracks the running accumulated byte size
%% in O(1), so EVERY append operation (literal chunk, coerced bound value,
%% literal placeholder) updates OutSize and checks it against MAX_OUTPUT_BYTES
%% immediately, enabling fail-soft truncation with no O(k^2) traversals.
%% ===================================================================

-spec on_missing(opts()) -> on_missing().
on_missing(#{on_missing := strict}) -> strict;
on_missing(_) -> lenient.

-spec scan(binary(), bindings(), on_missing(), non_neg_integer(), non_neg_integer(), [binary()]) ->
    [binary()].
%% `%%` -> literal `%`.
scan(<<$%, $%, Rest/binary>>, B, OM, Count, OutSize, Acc) ->
    case append_and_check(<<$%>>, OutSize) of
        {ok, NewOutSize} ->
            scan(Rest, B, OM, Count, NewOutSize, [<<$%>> | Acc]);
        {truncate, TruncBin} ->
            case TruncBin of
                <<>> -> Acc;
                _ -> [TruncBin | Acc]
            end;
        stop ->
            Acc
    end;
%% `%{` -> attempt a placeholder.
scan(<<$%, ${, Rest/binary>>, B, OM, Count, OutSize, Acc) ->
    handle_placeholder(Rest, B, OM, Count, OutSize, Acc);
%% Lone `%` at end of input -> literal.
scan(<<$%>>, _B, _OM, _Count, OutSize, Acc) ->
    case append_and_check(<<$%>>, OutSize) of
        {ok, _NewOutSize} ->
            [<<$%>> | Acc];
        {truncate, TruncBin} ->
            case TruncBin of
                <<>> -> Acc;
                _ -> [TruncBin | Acc]
            end;
        stop ->
            Acc
    end;
%% Any other `%X` (X not `%` or `{`) -> emit `%` literally, continue at X.
scan(<<$%, Rest/binary>>, B, OM, Count, OutSize, Acc) ->
    case append_and_check(<<$%>>, OutSize) of
        {ok, NewOutSize} ->
            scan(Rest, B, OM, Count, NewOutSize, [<<$%>> | Acc]);
        {truncate, TruncBin} ->
            case TruncBin of
                <<>> -> Acc;
                _ -> [TruncBin | Acc]
            end;
        stop ->
            Acc
    end;
%% Plain text run up to the next `%`: take it in one chunk (linear).
scan(Bin, B, OM, Count, OutSize, Acc) when is_binary(Bin), Bin =/= <<>> ->
    {Chunk, Rest} = take_literal(Bin),
    case append_and_check(Chunk, OutSize) of
        {ok, NewOutSize} ->
            scan(Rest, B, OM, Count, NewOutSize, [Chunk | Acc]);
        {truncate, TruncBin} ->
            case TruncBin of
                <<>> -> Acc;
                _ -> [TruncBin | Acc]
            end;
        stop ->
            Acc
    end;
scan(<<>>, _B, _OM, _Count, _OutSize, Acc) ->
    Acc.

%% Split `Bin` into the leading run with no `%` and the remainder (which
%% starts with `%` or is empty). One pass via `binary:match/2`.
-spec take_literal(binary()) -> {binary(), binary()}.
take_literal(Bin) ->
    case binary:match(Bin, <<$%>>) of
        nomatch ->
            {Bin, <<>>};
        {Pos, _Len} ->
            <<Chunk:Pos/binary, Rest/binary>> = Bin,
            {Chunk, Rest}
    end.

%% At this point we have consumed `%{`. Try to read a valid name run and a
%% closing `}`. On any malformation, emit `%{` literally and resume.
-spec handle_placeholder(
    binary(), bindings(), on_missing(), non_neg_integer(), non_neg_integer(), [binary()]
) ->
    [binary()].
handle_placeholder(Rest, B, OM, Count, OutSize, Acc) ->
    case read_name(Rest, 0, []) of
        {ok, NameBin, AfterRest} ->
            resolve(NameBin, AfterRest, B, OM, Count, OutSize, Acc);
        error ->
            %% Malformed `%{...` (no valid name, unclosed, or name too
            %% long): emit the `%{` literally and continue scanning at
            %% `Rest` (the byte after `{`).
            case append_and_check(<<$%, ${>>, OutSize) of
                {ok, NewOutSize} ->
                    scan(Rest, B, OM, Count, NewOutSize, [<<$%, ${>> | Acc]);
                {truncate, TruncBin} ->
                    case TruncBin of
                        <<>> -> Acc;
                        _ -> [TruncBin | Acc]
                    end;
                stop ->
                    Acc
            end
    end.

%% Read `[A-Za-z_][A-Za-z0-9_]*` up to `}`. Returns the name binary and
%% the remainder AFTER the `}`. `error` on: empty name, illegal char,
%% unterminated, or name exceeding `?MAX_NAME_BYTES`.
-spec read_name(binary(), non_neg_integer(), [byte()]) ->
    {ok, binary(), binary()} | error.
read_name(_Bin, Len, _RevChars) when Len > ?MAX_NAME_BYTES ->
    error;
read_name(<<$}, Rest/binary>>, Len, RevChars) when Len > 0 ->
    {ok, list_to_binary(lists:reverse(RevChars)), Rest};
read_name(<<C, Rest/binary>>, 0, []) when
    (C >= $A andalso C =< $Z) orelse
        (C >= $a andalso C =< $z) orelse
        C =:= $_
->
    %% First char of the name: letter or underscore only.
    read_name(Rest, 1, [C]);
read_name(<<C, Rest/binary>>, Len, RevChars) when
    Len > 0 andalso
        ((C >= $A andalso C =< $Z) orelse
            (C >= $a andalso C =< $z) orelse
            (C >= $0 andalso C =< $9) orelse
            C =:= $_)
->
    read_name(Rest, Len + 1, [C | RevChars]);
read_name(_Other, _Len, _RevChars) ->
    %% Empty name, illegal char, or end of input before `}`.
    error.

%% A syntactically valid `%{name}` was read. Resolve it against bindings.
-spec resolve(binary(), binary(), bindings(), on_missing(), non_neg_integer(), non_neg_integer(), [
    binary()
]) ->
    [binary()].
resolve(NameBin, AfterRest, B, OM, Count, OutSize, Acc) ->
    case lookup_binding(NameBin, B) of
        {ok, Value} ->
            case Count >= ?MAX_EXPANSIONS of
                true ->
                    %% Expansion cap reached: emit the placeholder
                    %% literally (fail-soft, no raise) and continue.
                    PlaceholderBin = literal_placeholder(NameBin),
                    case append_and_check(PlaceholderBin, OutSize) of
                        {ok, NewOutSize} ->
                            scan(AfterRest, B, OM, Count, NewOutSize, [PlaceholderBin | Acc]);
                        {truncate, TruncBin} ->
                            case TruncBin of
                                <<>> -> Acc;
                                _ -> [TruncBin | Acc]
                            end;
                        stop ->
                            Acc
                    end;
                false ->
                    Text = coerce(Value),
                    case append_and_check(Text, OutSize) of
                        {ok, NewOutSize} ->
                            scan(AfterRest, B, OM, Count + 1, NewOutSize, [Text | Acc]);
                        {truncate, TruncBin} ->
                            case TruncBin of
                                <<>> -> Acc;
                                _ -> [TruncBin | Acc]
                            end;
                        stop ->
                            Acc
                    end
            end;
        missing ->
            handle_missing(NameBin, AfterRest, B, OM, Count, OutSize, Acc)
    end.

-spec handle_missing(
    binary(), binary(), bindings(), on_missing(), non_neg_integer(), non_neg_integer(), [binary()]
) ->
    [binary()].
handle_missing(NameBin, _AfterRest, _B, strict, _Count, _OutSize, _Acc) ->
    erlang:error({erli18n_interp, {missing_binding, missing_name_term(NameBin)}});
handle_missing(NameBin, AfterRest, B, lenient, Count, OutSize, Acc) ->
    %% Lenient: leave the placeholder literal and continue.
    PlaceholderBin = literal_placeholder(NameBin),
    case append_and_check(PlaceholderBin, OutSize) of
        {ok, NewOutSize} ->
            scan(AfterRest, B, lenient, Count, NewOutSize, [PlaceholderBin | Acc]);
        {truncate, TruncBin} ->
            case TruncBin of
                <<>> -> Acc;
                _ -> [TruncBin | Acc]
            end;
        stop ->
            Acc
    end.

%% Resolve `NameBin` to a binding. Uses `binary_to_existing_atom/2` inside
%% a `try` so an unknown name is treated as MISSING and never interns a
%% new atom (anti-atom-table-DoS).
-spec lookup_binding(binary(), bindings()) -> {ok, term()} | missing.
lookup_binding(NameBin, B) ->
    try binary_to_existing_atom(NameBin, utf8) of
        Atom ->
            case B of
                #{Atom := Value} -> {ok, Value};
                _ -> missing
            end
    catch
        error:badarg -> missing
    end.

%% The error term for a strict miss: the atom if it already exists,
%% otherwise the raw binary (never interns a new atom).
-spec missing_name_term(binary()) -> atom() | binary().
missing_name_term(NameBin) ->
    try binary_to_existing_atom(NameBin, utf8) of
        Atom -> Atom
    catch
        error:badarg -> NameBin
    end.

%% Reconstruct the literal `%{name}` for the lenient/cap paths.
-spec literal_placeholder(binary()) -> binary().
literal_placeholder(NameBin) ->
    <<$%, ${, NameBin/binary, $}>>.

%% ===================================================================
%% Output-size tracking and clamping (O(1) per-append checks)
%% ===================================================================

%% Check if appending a binary would exceed the output cap. Returns:
%% - {ok, NewOutSize}: the chunk fits entirely, use NewOutSize for next call
%% - {truncate, TruncBin}: the chunk would exceed; TruncBin is truncated to fit
%%   (or empty if no room); use this and stop scanning
%% - stop: we're already at/over the cap, don't append anything, stop scanning
-spec append_and_check(binary(), non_neg_integer()) ->
    {ok, non_neg_integer()} | {truncate, binary()} | stop.
append_and_check(Bin, OutSize) ->
    ChunkSize = byte_size(Bin),
    NewSize = OutSize + ChunkSize,
    case NewSize > ?MAX_OUTPUT_BYTES of
        false ->
            %% Fits entirely.
            {ok, NewSize};
        true ->
            %% Would exceed. Calculate how much room is left.
            RoomLeft = ?MAX_OUTPUT_BYTES - OutSize,
            case RoomLeft > 0 of
                true ->
                    %% Truncate the chunk to fit; extract the part and make a copy
                    %% to avoid pinning the original when we only use a small part.
                    TruncSize = min(byte_size(Bin), RoomLeft),
                    Part = binary:part(Bin, 0, TruncSize),
                    TruncBin = binary:copy(Part),
                    {truncate, TruncBin};
                false ->
                    %% No room left, don't add anything.
                    stop
            end
    end.

%% ===================================================================
%% Value coercion — TOTAL. Never raises; unknown terms render via a
%% bounded safe fallback. Output clamped to `?MAX_VALUE_BYTES`.
%% ===================================================================

-spec coerce(term()) -> binary().
coerce(V) when is_binary(V) ->
    clamp_value(ensure_utf8(V));
coerce(V) when is_integer(V) ->
    integer_to_binary(V);
coerce(V) when is_float(V) ->
    clamp_value(safe_float(V));
coerce(V) when is_atom(V) ->
    clamp_value(atom_to_binary(V, utf8));
coerce(V) when is_list(V) ->
    clamp_value(safe_iolist(V));
coerce(V) ->
    %% Unknown term (tuple, map, pid, ...): bounded safe fallback.
    clamp_value(safe_inspect(V)).

%% A binding binary may not be valid UTF-8 (it is caller-supplied). Keep
%% valid UTF-8 verbatim; otherwise re-encode latin1 bytes so the result is
%% always valid UTF-8 and the function stays total.
-spec ensure_utf8(binary()) -> binary().
ensure_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Out when is_binary(Out) ->
            Out;
        _ ->
            case unicode:characters_to_binary(Bin, latin1, utf8) of
                Out2 when is_binary(Out2) -> Out2;
                _ -> safe_inspect(Bin)
            end
    end.

%% Strings / iolists -> UTF-8 binary, totally.
-spec safe_iolist(list()) -> binary().
safe_iolist(L) ->
    case unicode:characters_to_binary(L, unicode, utf8) of
        Out when is_binary(Out) -> Out;
        _ -> safe_inspect(L)
    end.

-spec safe_float(float()) -> binary().
safe_float(F) ->
    try float_to_binary(F, [short]) of
        Out -> Out
    catch
        _:_ -> safe_inspect(F)
    end.

%% Bounded `io_lib` rendering for any non-text term. Truncated and total.
-spec safe_inspect(term()) -> binary().
safe_inspect(Term) ->
    try
        Chars = io_lib:format("~tp", [Term]),
        case unicode:characters_to_binary(Chars, unicode, utf8) of
            B when is_binary(B) -> B;
            _ -> <<"?">>
        end
    catch
        _:_ -> <<"?">>
    end.

-spec clamp_value(binary()) -> binary().
clamp_value(Bin) when byte_size(Bin) =< ?MAX_VALUE_BYTES ->
    Bin;
clamp_value(Bin) ->
    binary:copy(binary:part(Bin, 0, ?MAX_VALUE_BYTES)).
