-module(rebar3_erli18n_keywords).

-moduledoc """
Name-AND-arity keyword spec for the erli18n facade family.

Extraction keys every recognized call site by `{Name, Arity}` and reads the
literal-bearing argument slots from a data-driven table. Keying by arity is
mandatory: the `d`/`dc` families put `Domain` in the FIRST argument, which
shifts `Context`/`Msgid`/`MsgidPlural` one slot right relative to the bare
family, and the interpolating `f`-family APPENDS a trailing `Bindings` map that
the spec ignores for msgid extraction (the leading slots are identical to
the non-`f` sibling).

Each row is a `slots()` map giving 1-based argument indices:

- `domain` — index of a literal-atom Domain argument (d/dc families), or
  `from_macro` when the call carries no Domain slot (the bare family, which
  the extractor keys under the module's `?GETTEXT_DOMAIN`).
- `context` — index of a literal `msgctxt` argument (p/np families), absent
  otherwise.
- `msgid` — index of the literal `msgid` (always present).
- `plural` — index of the literal `msgid_plural` (n/np families), absent
  otherwise.

Slots are verified against the `erli18n` clause heads. A call whose
referenced slot is not a compile-time literal (string/charlist or, for
`domain`, a literal atom) is skipped by the extractor — never mis-keyed.
""".

-export([spec/0, lookup/2]).

-export_type([slots/0, kind/0]).

-doc """
The literal-bearing argument slots for one `{Name, Arity}` row.

`domain` is either a 1-based argument index (when the function carries a
Domain slot) or the atom `from_macro`, meaning "no Domain argument; the
extractor supplies the module's `?GETTEXT_DOMAIN`". `context`/`plural` are
present only for the families that carry them.
""".
-type slots() :: #{
    domain := pos_integer() | from_macro,
    msgid := pos_integer(),
    context => pos_integer(),
    plural => pos_integer(),
    kind := kind()
}.

-doc "Whether a recognized call yields a singular or a plural catalog entry.".
-type kind() :: singular | plural.

-doc """
Look up the slots for a `{Name, Arity}` call site.

Returns `{ok, slots()}` for a recognized facade function, or `error` for any
other call (which the extractor leaves untouched).
""".
-spec lookup(atom(), arity()) -> {ok, slots()} | error.
lookup(Name, Arity) ->
    maps:find({Name, Arity}, spec()).

-doc """
The full `{Name, Arity} => slots()` table for the erli18n facade.

Covers the `gettext`/`ngettext`/`pgettext`/`npgettext` families, their
`d`/`dc` variants, and the interpolating `f`-family — roughly fifty
arities in all.

The table is a single literal map, so the compiler builds it once and every
call returns the same shared constant. `lookup/2` is therefore a single
`maps:find` over a constant — no per-call construction or merge.
""".
-spec spec() -> #{{atom(), arity()} => slots()}.
spec() ->
    #{
        %% =========================
        %% Non-`f` families
        %% =========================

        %% gettext/dgettext/dcgettext — singular.
        {gettext, 1} => #{domain => from_macro, msgid => 1, kind => singular},
        {gettext, 2} => #{domain => 1, msgid => 2, kind => singular},
        {gettext, 3} => #{domain => 1, msgid => 2, kind => singular},
        {dgettext, 2} => #{domain => 1, msgid => 2, kind => singular},
        {dgettext, 3} => #{domain => 1, msgid => 2, kind => singular},
        {dcgettext, 3} => #{domain => 1, msgid => 2, kind => singular},

        %% ngettext/dngettext/dcngettext — plural.
        {ngettext, 3} => #{domain => from_macro, msgid => 1, plural => 2, kind => plural},
        {ngettext, 4} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {ngettext, 5} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dngettext, 4} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dngettext, 5} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dcngettext, 5} => #{domain => 1, msgid => 2, plural => 3, kind => plural},

        %% pgettext/dpgettext/dcpgettext — contextual singular.
        {pgettext, 2} => #{domain => from_macro, context => 1, msgid => 2, kind => singular},
        {pgettext, 3} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {pgettext, 4} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dpgettext, 3} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dpgettext, 4} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dcpgettext, 4} => #{domain => 1, context => 2, msgid => 3, kind => singular},

        %% npgettext/dnpgettext/dcnpgettext — contextual plural.
        {npgettext, 4} =>
            #{domain => from_macro, context => 1, msgid => 2, plural => 3, kind => plural},
        {npgettext, 5} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {npgettext, 6} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dnpgettext, 5} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dnpgettext, 6} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dcnpgettext, 6} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},

        %% =========================
        %% Interpolating `f`-family
        %% =========================
        %%
        %% Every member appends a trailing `Bindings` map. The leading slots
        %% are byte-identical to the non-`f` sibling, so the spec reuses the
        %% same indices and simply ignores the trailing argument.

        %% gettextf/dgettextf/dcgettextf.
        {gettextf, 2} => #{domain => from_macro, msgid => 1, kind => singular},
        {gettextf, 3} => #{domain => 1, msgid => 2, kind => singular},
        {gettextf, 4} => #{domain => 1, msgid => 2, kind => singular},
        {dgettextf, 3} => #{domain => 1, msgid => 2, kind => singular},
        {dgettextf, 4} => #{domain => 1, msgid => 2, kind => singular},
        {dcgettextf, 4} => #{domain => 1, msgid => 2, kind => singular},

        %% ngettextf/dngettextf/dcngettextf.
        {ngettextf, 4} => #{domain => from_macro, msgid => 1, plural => 2, kind => plural},
        {ngettextf, 5} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {ngettextf, 6} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dngettextf, 5} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dngettextf, 6} => #{domain => 1, msgid => 2, plural => 3, kind => plural},
        {dcngettextf, 6} => #{domain => 1, msgid => 2, plural => 3, kind => plural},

        %% pgettextf/dpgettextf/dcpgettextf.
        {pgettextf, 3} => #{domain => from_macro, context => 1, msgid => 2, kind => singular},
        {pgettextf, 4} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {pgettextf, 5} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dpgettextf, 4} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dpgettextf, 5} => #{domain => 1, context => 2, msgid => 3, kind => singular},
        {dcpgettextf, 5} => #{domain => 1, context => 2, msgid => 3, kind => singular},

        %% npgettextf/dnpgettextf/dcnpgettextf.
        {npgettextf, 5} =>
            #{domain => from_macro, context => 1, msgid => 2, plural => 3, kind => plural},
        {npgettextf, 6} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {npgettextf, 7} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dnpgettextf, 6} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dnpgettextf, 7} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural},
        {dcnpgettextf, 7} => #{domain => 1, context => 2, msgid => 3, plural => 4, kind => plural}
    }.
