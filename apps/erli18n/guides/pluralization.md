# Pluralization

Different languages have different numbers of plural forms — English has 2
(singular / plural), Portuguese 2, Russian 3, Arabic 6. `erli18n` selects the
correct form the same way GNU gettext does, so the catalogs your translators
already produce work unchanged. This guide is the mental model; the
[`erli18n_plural`](erli18n_plural.html) module reference has the evaluator
details.

## Selecting a form: `ngettext`

You give `ngettext` a singular `msgid`, a plural `msgid`, and the count `N`. It
returns the translation for the form `N` falls into:

```erlang
<<"arquivo">>  = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"pt_BR">>).
<<"arquivos">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"pt_BR">>).
```

`npgettext` adds a context; the `d` / `dc` variants make the domain explicit.
To splice the number into the string, use the interpolating sibling
`ngettextf` — it auto-binds `count => N`, so the translator decides where the
number lands:

```erlang
%% pt_BR msgstr[1] "%{count} arquivos"
<<"42 arquivos">> = erli18n:ngettextf(my_domain,
    <<"%{count} file">>, <<"%{count} files">>, 42, <<"pt_BR">>, #{}).
```

## The `.po` header is the source of truth

Each catalog's `Plural-Forms` header carries a C expression that maps a count to
a form index. For example, the standard 2-form Western European rule:

```
"Plural-Forms: nplurals=2; plural=(n != 1);\n"
```

and the corresponding plural entries:

```
msgid "%{count} file"
msgid_plural "%{count} files"
msgstr[0] "%{count} arquivo"
msgstr[1] "%{count} arquivos"
```

At load time `erli18n` compiles that expression into a small AST (a
recursive-descent parser + interpreter — no dynamic code generation, so
dialyzer and eqwalizer can reason about it). At lookup time it evaluates the AST
for `N` and returns `msgstr[index]`. Erlang `rem` matches C99 `%`, so the
selected index is byte-for-byte what GNU `msgfmt` would choose — a property the
project pins with a parity oracle against the real gettext CLI.

## CLDR is a validator, not an override

`erli18n` ships the [Unicode CLDR](https://cldr.unicode.org/index/cldr-spec/plural-rules)
plural rules inlined as a static table — one rule per locale the upstream GNU
gettext / CLDR data defines, regenerated from that source rather than
hand-maintained. Those rules are consulted **only at
load time**, to emit a telemetry warning when a catalog's `Plural-Forms` header
diverges from CLDR's expectation for that locale. They never override the
header: the `.po` file you load is always authoritative at runtime. This keeps
the hot path a single header-driven evaluation and lets a translator
intentionally ship a non-standard rule.

To observe divergences, attach to the plural telemetry event (see the README's
telemetry example and the [`erli18n_telemetry`](erli18n_telemetry.html)
reference).

## Edge behavior

- A count with no matching `msgstr[index]` (a malformed catalog) degrades to the
  source `msgid` / `msgid_plural` rather than crashing.
- The evaluator always returns an index in `[0, nplurals)`; an out-of-range
  expression in the `.po` file is a catalog bug, surfaced via the load-time CLDR
  check, not a runtime exception.

## Where to next

- [Getting started](getting-started.html) — load a catalog and translate.
- [Locale negotiation](locale-negotiation.html) — choosing which locale's
  catalog (and thus which plural rule) to use per request.
- [`erli18n_plural`](erli18n_plural.html) — the `compile/1` + `evaluate/2`
  evaluator reference.
