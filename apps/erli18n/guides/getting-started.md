# Getting started

This guide walks you from an empty project to your first translated string. It
is a focused on-ramp; the [README](readme.html) is the complete tour of the API
surface, and every public function is documented in the module reference (start
with [`erli18n`](erli18n.html), the facade).

## 1. Add the dependency

```erlang
%% rebar.config
{deps, [{erli18n, "~> 0.6"}]}.
```

`erli18n` runs on `kernel` + `stdlib` alone. [`telemetry`](https://github.com/beam-telemetry/telemetry)
and the web frameworks (`cowboy` / `elli`) are *optional* — add them only if you
use them. See the README's "Installation" section for the optional extras.

## 2. Start the application and load a catalog

A *catalog* is the translations for one `(domain, locale)` pair, loaded from a
GNU `gettext` `.po` file. Loading parses the file, compiles its `Plural-Forms`
rule, validates it against CLDR, and inserts it — one atomic step.

```erlang
application:ensure_all_started(erli18n).

{ok, _Loaded} = erli18n_server:ensure_loaded(
    my_domain, <<"pt_BR">>,
    <<"priv/locale/pt_BR/LC_MESSAGES/my_domain.po">>).
```

A *domain* (here `my_domain`) is a gettext text domain — your way of grouping
translations. Catalogs are keyed by `domain` + `locale`; you load each once.

## 3. Translate

The whole lookup surface is the GNU gettext C-macro family, as Erlang
functions on the [`erli18n`](erli18n.html) facade:

```erlang
%% Singular.
<<"Olá, mundo">> = erli18n:gettext(my_domain, <<"Hello, world">>, <<"pt_BR">>).

%% Plural — ngettext selects the correct form for N.
<<"arquivo">>  = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"pt_BR">>).
<<"arquivos">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"pt_BR">>).

%% Contextual — the same source word, disambiguated by a msgctxt.
<<"Maio">> = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"pt_BR">>).
```

`pgettext` (contextual) and `npgettext` (contextual + plural) round out the
family, each with `d` / `dc` domain-explicit variants.

## 4. Set the locale once per process

Threading the locale through every call is tedious. Set it once for the calling
process — every lookup in that process then uses it with no locale argument:

```erlang
erli18n:setlocale(<<"pt_BR">>),                 %% this process only
<<"Olá, mundo">> = erli18n:gettext(my_domain, <<"Hello, world">>),
<<"arquivos">>   = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42).
```

> **The locale is per-process and is NOT inherited across a `spawn`.** A worker
> you spawn starts at `which_locale() = undefined` and falls back to the
> application-wide default (`set_default_locale/1`). Capture
> `erli18n:which_locale()` and re-`setlocale/1` it in the worker, or pass the
> locale explicitly. For web requests the optional Cowboy/Elli middleware does
> this for you — see [Locale negotiation](locale-negotiation.html).

## 5. Interpolate values

Every lookup family has an interpolating `f`-suffix sibling (`gettextf`,
`ngettextf`, ...) that takes a trailing `Bindings :: map()` and splices named
`%{var}` placeholders into the result:

```erlang
%% Source msgid "Hello, %{name}!" with pt_BR msgstr "Olá, %{name}!"
<<"Olá, Ada!">> = erli18n:gettextf(my_domain, <<"Hello, %{name}!">>,
    #{name => <<"Ada">>}).
```

Plural members auto-bind `count => N`, so `%{count}` is always available. The
`f`-family on the facade is *lenient* (an unbound placeholder is left literal
and nothing crashes); opt into *strict* errors with
[`erli18n_interp:format/3`](erli18n_interp.html). The README's "Interpolation"
section covers escaping (`%%`, `%%{name}`) and the RTL/bidi caveat.

## Misses degrade gracefully

A lookup with no catalog, no entry, or an empty translation returns the
original `msgid` (or `msgid_plural`) — your UI never shows a blank. Catalogs
live in `persistent_term`, so a crash of the catalog `gen_server` does not wipe
loaded translations.

## Where to next

- [Pluralization](pluralization.html) — how the `Plural-Forms` evaluator and the
  inlined CLDR rules choose a form.
- [Locale negotiation](locale-negotiation.html) — picking the best locale per
  request, the fallback chain, and the Cowboy/Elli middleware.
- [`erli18n`](erli18n.html) — the full facade reference.
- The README's "Common patterns" section — default domain, batch loading at
  startup, and telemetry.
