# Elixir Forum announcement — erli18n (draft)

Metadata for posting (not part of the post body):

- **Category:** Your Libraries & Projects → **Libraries**
- **Suggested tags:** `erlang`, `i18n`, `gettext`, `hex`
- **Title:** `erli18n — GNU gettext-compatible i18n for Erlang/OTP (a learning project — feedback very welcome)`

> Do **not** post in the archived "Erlang & BEAM Forum" — the forum is now polyglot, so Erlang content goes in the main categories.

---

## Post body (copy from here)

Hi everyone! 👋

I just published my first Hex package, **erli18n** — a GNU `gettext`–compatible internationalization library for **Erlang/OTP**, written in pure Erlang (and callable from Elixir too, since it's a normal Hex dep: `:erli18n.gettext(...)`).

I want to be upfront about one thing: **the main goal of this project is learning.** I built it to dig deep into Erlang/OTP — `gen_server` + supervision, ETS ownership/heir patterns, the `.po` format and CLDR plural rules, property-based testing with PropEr, `telemetry`, native EEP-59 docs, and the whole Hex release pipeline. So please read it as a `0.1.0` learning project rather than battle-tested production infra — though I worked hard to make it correct and thoroughly tested.

**What it does** — the full GNU gettext C-macro family as plain Erlang functions:

```erlang
application:ensure_all_started(erli18n).

{ok, _} = erli18n_server:ensure_loaded(my_domain, <<"pt_BR">>,
    <<"priv/locale/pt_BR/LC_MESSAGES/my_domain.po">>).

<<"Olá, mundo">> = erli18n:gettext(my_domain, <<"Hello, world">>, <<"pt_BR">>).

%% ngettext returns the correct plural FORM for N (you format the number yourself)
<<"arquivo">>  = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 1,  <<"pt_BR">>).
<<"arquivos">> = erli18n:ngettext(my_domain, <<"file">>, <<"files">>, 42, <<"pt_BR">>).

%% pgettext for context; npgettext for context + plural
<<"Maio">> = erli18n:pgettext(my_domain, <<"month">>, <<"May">>, <<"pt_BR">>).
```

A few things I focused on:

- 📦 **Drop-in `.po` / `.pot`** — loads the files translators already produce in Poedit, Crowdin, Weblate, or `xgettext`.
- 🌍 **Real CLDR pluralization** — an actual `Plural-Forms` evaluator, CLDR rules inlined for **49 locales**.
- ⚡ **Lock-free lookups** — reads run straight from ETS in the calling process; only writes go through a `gen_server`, so there's no bottleneck on the hot path.
- 📊 **Optional telemetry** — 7 events (catalog spans, lookup misses, plural divergence, memory warnings); `telemetry` is an *optional* dependency.
- ✅ **Heavily tested** — Common Test + PropEr + fuzzing, plus a parity suite that checks output byte-for-byte against GNU `msgfmt` as a ground-truth oracle.

(Pure Erlang, OTP 27+, Apache-2.0.)

**Why I'm posting here:**

1. I'd genuinely love **feedback** — on the API design, the OTP patterns, anything that makes a seasoned BEAM dev wince. Since I'm here to learn, blunt and critical opinions are exactly what I'm after.
2. If you have an Erlang project that wants gettext-style i18n **without** routing through Elixir's build, please **try it** and tell me where it breaks.

**Links:**

- 📦 Hex: <https://hex.pm/packages/erli18n>
- 📚 Docs: <https://hexdocs.pm/erli18n>
- 🐙 GitHub: <https://github.com/eagle-head/erli18n>

If you find it useful or even just interesting to read, a ⭐ on GitHub would mean a lot and helps me gauge whether it's worth continuing. Thanks for reading — any feedback, however harsh, is hugely appreciated! 🙏
