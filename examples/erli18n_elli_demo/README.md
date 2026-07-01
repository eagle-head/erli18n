# erli18n_elli_demo

A standalone, runnable example of the optional [`erli18n_elli`](https://hexdocs.pm/erli18n/erli18n_elli.html)
middleware: **per-request locale negotiation for [Elli](https://github.com/elli-lib/elli)**.

## What it shows

`erli18n_elli` is installed as an `elli_middleware` preprocessor ahead of the
handler. On every request it negotiates the locale — default precedence **query
string > cookie > `Accept-Language` header > default** — and calls
`erli18n:setlocale/1` on the request process **before** the handler runs. The
handler ([`erli18n_elli_demo_handler`](src/erli18n_elli_demo_handler.erl)) then
translates with **no locale argument**: the gettext family reads the per-process
locale the middleware set.

Two catalogs are loaded at boot — `pt_BR` and `es` — into the `default` gettext
domain. `en` is the (deliberately unloaded) default locale, so a request that
matches nothing falls back to the raw English msgids.

The wiring lives in [`erli18n_elli_demo_sup`](src/erli18n_elli_demo_sup.erl):

```erlang
{mods, [
    {erli18n_elli, #{sources => [query, cookie, header]}},
    {erli18n_elli_demo_handler, []}
]}
```

`erli18n_elli` runs **first** (it exports only `preprocess/2`, so
`elli_middleware` skips its handle phase and it never intercepts the real
handler); the real handler runs **last**. The `path` source is Cowboy-only and a
harmless no-op under Elli.

## First-time setup

`erli18n` 0.7.0 is not yet on Hex, so this example resolves it from the in-repo
source through a gitignored `_checkouts/` symlink. Create it once:

```sh
ln -s ../../../apps/erli18n examples/erli18n_elli_demo/_checkouts/erli18n
```

(`elli` resolves normally from Hex.)

## Run

```sh
cd examples/erli18n_elli_demo
rebar3 shell
```

The listener starts on **`http://localhost:8081/`**.

## Prove the negotiation

```sh
# query string wins; "pt-BR" canonicalizes to the loaded "pt_BR" -> Portuguese
curl 'http://localhost:8081/?locale=pt-BR'

# cookie source -> Spanish
curl -H 'Cookie: locale=es' http://localhost:8081/

# Accept-Language header source -> Portuguese
curl -H 'Accept-Language: pt-BR,en;q=0.8' http://localhost:8081/

# precedence: query > cookie > header (all three present -> query "es" wins)
curl -H 'Cookie: locale=pt-BR' -H 'Accept-Language: pt-BR' 'http://localhost:8081/?locale=es'

# no signal -> default "en" (unloaded) -> raw English msgids
curl http://localhost:8081/

# unmatched locale -> default "en"
curl 'http://localhost:8081/?locale=fr'

# fail-soft: a malformed percent-escape is skipped, not fatal -> 200 (default en), never 500
curl -i 'http://localhost:8081/?locale=%ZZ'
```

Each response is three translated lines plus the resolved `locale:` it used.

## Mind the spawn boundary

The negotiated locale is **per-process** and is **not** inherited across a spawn.
Elli runs the middleware and handler in one request process, so the handler sees
it — but any cross-process handoff (a pooled worker, a `gen_server`, a
`Task`-style spawn) starts at `erli18n:which_locale() = undefined`. Capture
`Locale = erli18n:which_locale()` and re-`erli18n:setlocale(Locale)` in the
worker, or pass it explicitly. The middleware also sets `logger` process metadata
`#{locale => L}` by default. See the
[`erli18n_elli`](https://hexdocs.pm/erli18n/erli18n_elli.html) module docs for the
full discussion.
