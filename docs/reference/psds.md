# PSDs (PO-Semantics Decisions)

As **PO-Semantics Decisions** (PSD-001..009) sao as nove decisoes que fixam
como o `erli18n` interpreta a semantica de um arquivo `.po`. Sao a fonte de
verdade do parser (`src/erli18n_po.erl`) e do avaliador de plural
(`src/erli18n_plural.erl`), e estao catalogadas no `CHANGELOG.md`.

| PSD | Decisao em uma linha |
| --- | --- |
| [PSD-001](#psd-001-fuzzy-descartado-por-default) | Entradas fuzzy descartadas por default; opt-in. |
| [PSD-002](#psd-002-charset-restrito) | Charset restrito a UTF-8 / Latin-1 / US-ASCII. |
| [PSD-003](#psd-003-msgstr-vazio-preservado) | `msgstr` vazio preservado; fallback no lookup. |
| [PSD-004](#psd-004-header-plural-forms-e-a-fonte-de-verdade) | Header `Plural-Forms` e a fonte de verdade em runtime. |
| [PSD-005](#psd-005-bom-utf-8-removido) | BOM UTF-8 removido silenciosamente. |
| [PSD-006](#psd-006-msgctxt-como-campo-separado) | `msgctxt` como campo de chave separado. |
| [PSD-007](#psd-007-entradas-obsoletas-puladas) | Entradas obsoletas (`#~`) puladas. |
| [PSD-008](#psd-008-plural-degenerado-aceito) | Plural degenerado (`nplurals=1`) aceito. |
| [PSD-009](#psd-009-mismatch-de-nplurals-rejeitado) | Mismatch de `nplurals` rejeitado com erro estruturado. |

---

## PSD-001 — Fuzzy descartado por default

Entradas marcadas `#, fuzzy` sao **descartadas por default**, em paridade com
o comportamento do `msgfmt`. O opt-in e via `#{include_fuzzy => true}` no
load ([ver Catalogos](/guide/catalogs)). Quando descartadas, a contagem
alimenta o evento de telemetria `[erli18n, lookup, fuzzy_skip]`.

Racional: uma traducao fuzzy e uma sugestao nao confirmada; vaza-la na UI por
default seria menos seguro do que cair no `msgid` fonte.

---

## PSD-002 — Charset restrito

O suporte a charset e restrito a **UTF-8, Latin-1 e US-ASCII** — os tres
nativos do `unicode:characters_to_binary/3`. O charset e detectado no
`Content-Type` do header e normalizado para um de `utf8 | latin1 | us_ascii`,
aceitando nomes case-insensitive (RFC 2978).

Charsets legados que o `msgfmt -c` aceita (windows-1252/cp1252,
iso-8859-15, koi8-r, euc-jp) sao **rejeitados** com
`{error, {unsupported_charset, Bin}}` — fail-closed, com erro estruturado e
sem crash; o catalogo ETS pre-existente fica intacto. E um estreitamento
deliberado e documentado ([ver Paridade](/guide/parity)).

O charset tambem define o code space em que os bytes de escape `\xHH` /
`\OOO` sao interpretados antes da transcodificacao para UTF-8.

---

## PSD-003 — `msgstr` vazio preservado

Um `msgstr ""` significa **"nao traduzido"**. O parser preserva a traducao
vazia (`<<>>`); o **fallback e tratado no lookup**, nao no parse.

No runtime, R1 (singular) e R2 (plural) tratam uma traducao vazia
exatamente como um miss: caem no `msgid` (ou `msgid_plural`). Um guard
defensivo garante que um `<<>>` nunca chegue a UI ([ver API de Lookup](/guide/lookup-api)).

---

## PSD-004 — Header `Plural-Forms` e a fonte de verdade

O cabeçalho `Plural-Forms` do `.po` e a **fonte de verdade em runtime** para
a selecao de forma plural. A tabela CLDR embutida e consultada **apenas no
load**, para emitir um aviso de divergencia (informativo), e como fallback
quando o header esta ausente.

Como o header e a fonte de verdade, `erli18n_plural:evaluate/2` e o hot path
e nunca toca o CLDR. A divergencia detectada no load nunca bloqueia: produz
apenas um `?LOG_WARNING` e o evento `[erli18n, plural, divergence_warning]`
([ver Pluralizacao](/guide/pluralization)).

---

## PSD-005 — BOM UTF-8 removido

O BOM UTF-8 e **removido silenciosamente** — e a primeira coisa que o parser
faz, antes de qualquer outro processamento (extracao de charset, parse do
corpo). Um `.po` exportado com BOM por uma ferramenta Windows carrega sem
ruido.

---

## PSD-006 — `msgctxt` como campo separado

O `msgctxt` (contexto) e armazenado como um **campo de chave ETS separado**,
**nunca byte-glued** com o `msgid`. Isso da paridade com o `gettexter` e
permite desambiguar homografos sem colisao de chave.

A chave da entrada e `{singular | plural, Domain, Locale, Context, Msgid}`,
com `Context :: undefined | binary()` ([ver API de Lookup](/guide/lookup-api)).

---

## PSD-007 — Entradas obsoletas puladas

Entradas obsoletas — qualquer linha iniciando com `#~` — sao **puladas por
completo** no parse. Elas existem em um `.po` como historico que ferramentas
preservam, mas nao sao traducoes ativas, entao nao entram no catalogo.

---

## PSD-008 — Plural degenerado aceito

Regras de plural degeneradas (`nplurals=1; plural=0;`, usadas por
ja/zh/ko/vi/th) sao **aceitas** e fazem round-trip por compile/evaluate como
uma expressao de inteiro literal. A gramatica aceita literais inteiros como
termos primarios validos, e a tabela CLDR codifica esses locales com forma
unica ([ver Plural-Forms & CLDR](/reference/plurals)).

---

## PSD-009 — Mismatch de `nplurals` rejeitado

O conjunto de indices `msgstr[N]` e validado contra o `nplurals` declarado no
header (quando conhecido): deve ser exatamente `[0, 1, ..., Nplurals-1]`. Um
mismatch e **rejeitado com erro estruturado**:

```erlang
{error, {plural_count_mismatch, Msgid, Expected :: non_neg_integer(), Got :: [non_neg_integer()]}}
```

Se o header esta ausente ou nao traz `nplurals`, qualquer conjunto de indices
e aceito. A validacao acontece no parse, antes de qualquer mutacao na ETS, de
modo que um `.po` inconsistente nunca instala um catalogo parcial.
