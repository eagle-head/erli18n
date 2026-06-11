# Catalogos (.po / .pot)

Um **catalogo** em `erli18n` e o conteudo de um arquivo `.po` carregado em
memoria para um par `(dominio, locale)`. Esta pagina cobre o ciclo de vida
completo: carregar, recarregar e descarregar; as opcoes de resource-bound;
a garantia de atomicidade; o layout de caminho por convencao; e o uso
multi-tenant.

Toda a API de orquestracao de load e exposta pelo modulo facade `erli18n`,
que delega para `erli18n_server`. O caminho de leitura/parse/compile pesado
roda no **processo chamador** (nao no `gen_server`), de modo que um `.po`
grande ou patologico de um tenant nunca bloqueia o load de outro. So o
payload validado atravessa a mailbox do servidor para o commit serializado.

## Tipos

| Argumento | Tipo | Exemplo |
| --- | --- | --- |
| `Domain` | `atom()` | `my_domain` |
| `Locale` | `binary()` | `<<"fr">>` |
| `PoPath` | `file:filename()` | `<<"priv/locale/fr/LC_MESSAGES/my_domain.po">>` |
| `Opts`   | `map()` (ver abaixo) | `#{include_fuzzy => true}` |

## Carregar: ensure_loaded/3,4

`ensure_loaded/3` carrega um catalogo se ele ainda nao estiver carregado.
A operacao e **idempotente**: se o par `(Domain, Locale)` ja esta em
memoria, retorna `{ok, already}` sem tocar no disco — uma leitura ETS pura,
sem roundtrip ao servidor.

```erlang
%% Carrega (se ainda nao carregado). Domain = atom, Locale = binary.
{ok, NewlyLoaded} = erli18n:ensure_loaded(my_domain, <<"fr">>,
    <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).

%% Segunda chamada: fast-path idempotente, sem I/O de disco.
{ok, already} = erli18n:ensure_loaded(my_domain, <<"fr">>,
    <<"priv/locale/fr/LC_MESSAGES/my_domain.po">>).
```

O resultado segue o tipo `ensure_result()`:

```erlang
{ok, NewlyLoaded :: non_neg_integer()}  %% load real: N entradas inseridas
| {ok, already}                          %% fast-path idempotente
| {error, ensure_error()}                %% erro estruturado; ETS intacto
```

`ensure_loaded/4` aceita um mapa de opcoes como quarto argumento:

```erlang
{ok, _N} = erli18n:ensure_loaded(my_domain, <<"fr">>, PoPath,
    #{include_fuzzy => true, max_bytes => 4194304, timeout => 10000}).
```

### Pipeline de load

Em um load real (cache miss), o pipeline executa, **nesta ordem**, todas as
etapas falhaveis ANTES de qualquer mutacao na ETS:

0. **Cap de tamanho** (`filelib:file_size/1`, sem ler os bytes) — `{input_too_large, _, _}`
1. **Leitura do arquivo** (`file:read_file/1`) — `{file_error, Posix}`
2. **Parse** do `.po` (`erli18n_po:parse/2`) — `parse_error()`
3. **Cap de entradas** (pos-parse) — `{too_many_entries, _, _}`
4. **Compilacao do header** `Plural-Forms` — `{plural_compile_error, _}`
5. **Divergencia vs CLDR** — nunca falha (so informativa)

Como todos os erros ocorrem antes da insercao, um `ensure_loaded` que falha
deixa a ETS exatamente como estava — nada e parcialmente inserido.

## Opcoes: opts()

```erlang
-type opts() :: #{
    include_fuzzy => boolean(),
    max_bytes     => non_neg_integer() | infinity,
    max_entries   => non_neg_integer() | infinity,
    timeout       => timeout()
}.
```

Todo campo e **opcional**; omitir preserva o comportamento legado (modulo os
caps de seguranca default). Chamadas existentes com `#{}` ou
`#{include_fuzzy => _}` continuam validas.

| Campo | Default | Significado |
| --- | --- | --- |
| `include_fuzzy` | `false` | Inclui entradas marcadas `#, fuzzy`. Por default (paridade com `msgfmt`) elas sao descartadas. Ver [PSD-001](/reference/psds). |
| `max_bytes` | `16 * 1024 * 1024` (16 MiB) | Rejeita o arquivo via `filelib:file_size/1` **antes** de le-lo inteiro para a memoria. `infinity` = sem cap. Default ajustavel via env `max_po_bytes`. |
| `max_entries` | `500000` | Rejeita o catalogo **depois** do parse se tiver mais que N entradas. `infinity` = sem cap. Default ajustavel via env `max_po_entries`. |
| `timeout` | `5000` (ms) | Timeout do `gen_server:call/3` que faz o commit. A fase pesada nao roda mais atras da mailbox, entao o prazo cobre apenas o bulk insert (medido ~26ms para 40k entradas). |

Os erros de bound sao estruturados e surgem na fase do chamador, antes de
qualquer mutacao:

```erlang
{error, {input_too_large, Bytes :: non_neg_integer(), Limit :: non_neg_integer()}}
{error, {too_many_entries, Count :: non_neg_integer(), Limit :: non_neg_integer()}}
```

::: tip Configuracao via application env
Os defaults de `max_bytes` e `max_entries` saem de `application:get_env/3`:

```erlang
%% sys.config
{erli18n, [
    {max_po_bytes, 33554432},    %% 32 MiB (ou `infinity`)
    {max_po_entries, 1000000}    %% (ou `infinity`)
]}.
```
:::

## Recarregar: reload/3,4 (atomico)

`reload/3,4` re-faz parse e re-instala o catalogo **sempre** — nunca pega o
fast-path idempotente. Resolve a semantica de overwrite: o catalogo novo
sobrescreve o antigo entrada-por-entrada.

```erlang
{ok, N} = erli18n:reload(my_domain, <<"fr">>, PoPath).
{ok, N} = erli18n:reload(my_domain, <<"fr">>, PoPath, #{include_fuzzy => true}).
```

O `reload` e **STAGE -> ATOMIC-SWAP**. Toda a metade falhavel do pipeline
(read, parse, compile de plural, divergencia CLDR) roda num registro
`staged` em memoria, **sem tocar na ETS**. Consequencias:

- Se o novo `.po` for invalido (erro de sintaxe, charset nao suportado,
  `Plural-Forms` ruim, arquivo ausente), `reload` retorna `{error, _}` e o
  **catalogo bom anterior permanece totalmente intacto** — nunca destruido.
- No sucesso, a unica mutacao observavel e **insert-before-prune**: cada
  chave retida (presente em ambos os catalogos) e sobrescrita
  velho->novo por um `ets:insert/2` atomico, e somente as chaves ausentes
  do novo catalogo sao podadas depois. Um leitor concorrente de uma chave
  retida nunca observa uma janela de miss.

::: warning ensure_loaded e atomico; reload tambem
Ambos sao construidos para garantir "erros antes de qualquer mutacao".
`reload` adiciona a garantia de zero-janela-de-miss para chaves retidas
durante a troca.
:::

## Descarregar: unload/2

`unload/2` remove todas as entradas (singular, plural e header) de um par
`(Domain, Locale)`. E serializado via `gen_server` e sempre retorna `ok`.

```erlang
ok = erli18n:unload(my_domain, <<"fr">>).
```

Apos o unload, lookups daquele `(Domain, Locale)` voltam a cair no fallback
para `msgid` / `msgid_plural` (ver [API de Lookup](/guide/lookup-api)).

## Layout de caminho: default_po_path/3

Em vez de montar o caminho na mao, deixe `erli18n` resolve-lo pela
convencao GNU gettext a partir do `priv/` de uma aplicacao OTP:

```
<PrivDir>/locale/<Locale>/LC_MESSAGES/<Domain>.po
```

```erlang
%% App = atom, Domain = atom, Locale = binary.
PoPath = erli18n:default_po_path(my_app, my_domain, <<"fr">>),
%% Ex.: ".../my_app/priv/locale/fr/LC_MESSAGES/my_domain.po"
{ok, _N} = erli18n:ensure_loaded(my_domain, <<"fr">>, PoPath).
```

`default_po_path/3` usa `code:priv_dir/1`. Se a aplicacao for desconhecida
(`{error, bad_name}`), ele falha explicitamente com `{priv_dir_not_found,
App}` — uma configuracao incorreta vira um crash visivel, nao um caminho
silenciosamente corrompido.

::: tip Caminho explicito vs. convencao
`ensure_loaded` sempre recebe o caminho **explicitamente** — nao ha
resolucao implicita dentro do load. `default_po_path/3` e apenas um helper
de conveniencia: o chamador decide se honra a convencao ou usa um caminho
proprio.
:::

## Multi-tenant

O design suporta deployments multi-tenant onde varios catalogos coexistem
para o mesmo dominio em locales diferentes, ou para dominios distintos por
tenant:

- **Isolamento por chamador.** A fase pesada de cada load roda no processo
  chamador, entao um `.po` grande/lento/patologico de um tenant nunca
  bloqueia o load de outro tenant nem queima a mailbox do servidor.
- **Boundary knobs.** `max_bytes` e `max_entries` sao a alavanca que um
  deployment multi-tenant precisa no boundary para rejeitar entrada
  adversarial antes que ela consuma memoria; `timeout` da um prazo
  tunavel por chamada.
- **Layout por tenant.** Use `default_po_path/3` (ou monte caminhos
  proprios) para mapear cada `(App, Domain, Locale)` ao seu `.po` no
  filesystem.

### Observabilidade de catalogos carregados

```erlang
%% Lista os catalogos carregados: [{Domain, Locale, NumEntries}].
Catalogs = erli18n:loaded_catalogs().

%% Uso de memoria agregado da ETS.
#{ets_bytes := _, num_catalogs := _, num_keys := _} = erli18n:memory_info().

%% Enumera as chaves de um catalogo: singular e plural (plural deduplicado).
Keys = erli18n:which_keys(my_domain, <<"fr">>).
```

`memory_info/0` tambem alimenta o evento de telemetria
`[erli18n, catalog, memory_warning]` — ver [Telemetry](/guide/telemetry).
