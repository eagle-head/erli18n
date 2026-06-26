# erli18n_cowboy_demo

A standalone, runnable example of the optional [`erli18n_cowboy`](https://hexdocs.pm/erli18n/erli18n_cowboy.html)
middleware: **per-request locale negotiation for [Cowboy](https://github.com/ninenines/cowboy)**.

## What it shows

`erli18n_cowboy` is installed in the middleware chain ahead of the handler. On
every request it negotiates the locale — default precedence **query string >
cookie > `Accept-Language` header > default** — and calls `erli18n:setlocale/1`
on the request process **before** the handler runs. The handler
([`erli18n_cowboy_demo_handler`](src/erli18n_cowboy_demo_handler.erl)) then
translates with **no locale argument**: the gettext family reads the per-process
locale the middleware set.

Two catalogs are loaded at boot — `pt_BR` and `es` — into the `default` gettext
domain. `en` is the (deliberately unloaded) default locale, so a request that
matches nothing falls back to the raw English msgids.

The wiring lives in [`erli18n_cowboy_demo_app`](src/erli18n_cowboy_demo_app.erl):

```erlang
middlewares => [erli18n_cowboy, cowboy_router, cowboy_handler]
```

`erli18n_cowboy` runs **before** the handler. The default sources need no router
binding, so it can run ahead of `cowboy_router`. (Only if you negotiate from a
`path_binding` source must it run *after* the router, which fills the binding —
see the module docs.)

## First-time setup

`erli18n` 0.6.0 is not yet on Hex, so this example resolves it from the in-repo
source through a gitignored `_checkouts/` symlink. Create it once:

```sh
ln -s ../../../apps/erli18n examples/erli18n_cowboy_demo/_checkouts/erli18n
```

(`cowboy` resolves normally from Hex.)

## Run

```sh
cd examples/erli18n_cowboy_demo
rebar3 shell
```

The listener starts on **`http://localhost:8080/`**.

## Prove the negotiation

```sh
# query string wins; "pt-BR" canonicalizes to the loaded "pt_BR" -> Portuguese
curl 'http://localhost:8080/?locale=pt-BR'

# cookie source -> Spanish
curl -H 'Cookie: locale=es' http://localhost:8080/

# Accept-Language header source -> Portuguese
curl -H 'Accept-Language: pt-BR,en;q=0.8' http://localhost:8080/

# precedence: query > cookie > header (all three present -> query "es" wins)
curl -H 'Cookie: locale=pt-BR' -H 'Accept-Language: pt-BR' 'http://localhost:8080/?locale=es'

# no signal -> default "en" (unloaded) -> raw English msgids
curl http://localhost:8080/

# unmatched locale -> default "en"
curl 'http://localhost:8080/?locale=fr'

# fail-soft: a malformed percent-escape is skipped, not fatal -> 200 (default en), never 500
curl -i 'http://localhost:8080/?locale=%ZZ'
```

Each response is three translated lines plus the resolved `locale:` it used.

## Mind the spawn boundary

The negotiated locale is **per-process** and is **not** inherited across a spawn.
Cowboy runs the middleware and handler in one request process, so the handler
sees it — but any cross-process handoff (a pooled worker, a `gen_server`, a
`Task`-style spawn, a stream handler that offloads) starts at
`erli18n:which_locale() = undefined`. Capture `Locale = erli18n:which_locale()`
and re-`erli18n:setlocale(Locale)` in the worker, or pass it explicitly. The
middleware also sets `logger` process metadata `#{locale => L}` by default. See
the [`erli18n_cowboy`](https://hexdocs.pm/erli18n/erli18n_cowboy.html) module docs
for the full discussion and a Phoenix interop note.
