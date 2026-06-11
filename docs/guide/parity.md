# Paridade (gettexter / msgfmt)

`erli18n` e projetado para ser **drop-in compativel com o GNU gettext**:
arquivos `.po` / `.pot` produzidos por Poedit, Crowdin, Transifex, Weblate e
pelo `xgettext` padrao carregam direto. O parser e um recursivo-descendente
escrito a mao que honra as 9 PO-Semantics Decisions
([PSD-001..009](/reference/psds)).

A paridade e validada contra dois oraculos de ground-truth: o legado
`gettexter` (paridade de API e semantica de runtime) e o GNU `msgfmt`
(semantica de formato de arquivo).

## O que e suportado

| Recurso | Suporte |
| --- | --- |
| `msgid` / `msgstr` singular | Sim |
| `msgid` / `msgid_plural` / `msgstr[N]` plural | Sim (header `Plural-Forms` e a fonte de verdade) |
| `msgctxt` (contexto) | Sim — campo separado, nunca byte-glued com `msgid` (PSD-006) |
| Strings multi-linha (concatenacao adjacente) | Sim |
| Comentarios (`#`, `#.`, `#:`, `#,`) | Reconhecidos |
| Flag `#, fuzzy` | Descartada por default; opt-in via `include_fuzzy` (PSD-001) |
| Entradas obsoletas (`#~`) | Puladas (PSD-007) |
| BOM UTF-8 | Removido silenciosamente (PSD-005) |
| Finais de linha LF / CRLF / lone-CR | Aceitos |
| Plural degenerado (`nplurals=1; plural=0;`) | Aceito (PSD-008) |
| Charsets UTF-8 / Latin-1 / US-ASCII | Aceitos (PSD-002) |
| Escapes C (`\n \t \r \" \\ \b \f \v \a ...`) | Decodificados |
| Escapes `\xHH` / `\OOO` | Decodificados e transcodificados pelo charset declarado |
| Round-trip `parse(dump(C))` | Preservado (re-escape em `dump/1`) |

## Escapes

O decode de escapes segue a [GNU gettext PO-Files spec](https://www.gnu.org/software/gettext/manual/gettext.html#PO-Files):

| Escape | Resultado |
| --- | --- |
| `\n` `\t` `\r` `\"` `\\` | newline, tab, CR, aspas, backslash |
| `\b` `\f` `\v` `\a` | backspace, form-feed, vertical-tab, bell (`0x07`) |
| `\/` `\?` `\'` | barra, interrogacao, apostrofe |
| `\xHH` | byte hexadecimal (1-2 digitos) no charset declarado |
| `\OOO` | byte octal (1-3 digitos), valor `<= 0xFF` |

Escapes `\xHH` / `\OOO` produzem **um byte no espaco de codigo do charset
declarado** e sao transcodificados para UTF-8 antes do gate UTF-8 — bytes
consecutivos sao agrupados, de modo que um codepoint multibyte escrito como
escapes consecutivos (ex.: `\xC3\xBF` = U+00FF num catalogo UTF-8) e validado
como uma unidade. `dump/1` faz o caminho inverso, re-escapando
`\\`, `\"`, `\n`, `\t`, `\r` para que `parse(dump(C))` faca round-trip fiel.

Escapes mal-formados viram `parse_error()` estruturado (dentro do envelope
`{syntax_error, Line, Reason}`), nunca crash silencioso:

- `{invalid_escape_charset, Charset, Byte}`
- `{escape_invalid_utf8, Rest}` / `{escape_incomplete_utf8, Rest}`
- `{octal_escape_out_of_range, Value}` (octal > `0xFF`)

## Charset: utf8 / latin1 / ascii

Por [PSD-002](/reference/psds), o charset e detectado no `Content-Type` do
header e normalizado para um de tres valores. Os nomes sao aceitos
case-insensitive (RFC 2978):

| Charset normalizado | Aliases aceitos |
| --- | --- |
| `utf8` | `utf-8`, `utf8` |
| `latin1` | `iso-8859-1`, `iso8859-1`, `latin-1`, `latin1` |
| `us_ascii` | `us-ascii`, `ascii` |

O charset do header determina o code space em que os bytes de escape
`\xHH` / `\OOO` sao interpretados antes da transcodificacao para UTF-8. Sem
header explicito, o parser sintetiza um header vazio com charset `utf8`.

Qualquer outro charset vira `{error, {unsupported_charset, Bin}}` e aborta o
parse — fail-closed, com erro estruturado e sem crash; o catalogo ETS
pre-existente fica intacto.

## BOM

Por [PSD-005](/reference/psds), o BOM UTF-8 e a **primeira** coisa que o
parser remove, silenciosamente, antes de qualquer outro processamento.

## Fuzzy e obsoleto

- **Fuzzy (`#, fuzzy`)** — descartadas por default (paridade com `msgfmt`,
  [PSD-001](/reference/psds)). Opt-in via `#{include_fuzzy => true}` no load
  ([ver Catalogos](/guide/catalogs)). Quando descartadas, a contagem
  alimenta o evento `[erli18n, lookup, fuzzy_skip]`
  ([ver Telemetry](/guide/telemetry)).
- **Obsoleto (`#~`)** — qualquer linha iniciando com `#~` faz parte de uma
  entrada obsoleta e e pulada por completo ([PSD-007](/reference/psds)).

## Limitacoes documentadas

A paridade e quase total, com algumas restricoes deliberadas e documentadas:

::: warning Encodings legados sao rejeitados
`erli18n` aceita apenas UTF-8, Latin-1 e US-ASCII (os nativos do
`unicode:characters_to_binary/3`). Charsets legados comuns que o `msgfmt -c`
aceita — `windows-1252`/`cp1252`, `iso-8859-15`, `koi8-r`, `euc-jp` — sao
**rejeitados com erro duro** (`{unsupported_charset, _}`).

E um estreitamento **deliberado** ([PSD-002](/reference/psds)), fail-closed:
erro estruturado, sem crash, catalogo pre-existente intacto. A direcao
futura (se a compatibilidade drop-in com catalogos legados virar objetivo) e
transcodificar codepages legados via tabela embutida ou dep opcional, mantendo
o fail-closed para charsets genuinamente desconhecidos.
:::

Outras limitacoes intencionais:

- **Sem validacao de chaves em compile-time.** A extracao de chaves a partir
  do fonte usa o CLI `xgettext` padrao — a mesma abordagem do Spring Boot
  MessageSource, Django, Rails I18n, Symfony Translation. Validacao de chaves
  em compile-time esta fora de escopo; o padrao mainstream e runtime + testes.
- **Plural-Forms tem caps de seguranca.** Expressoes de plural patologicas
  (muito longas, muito profundas, ou com contagem de nos do AST excessiva)
  sao rejeitadas fail-closed no compile ([ver Pluralizacao](/guide/pluralization)).
  Regras reais ficam folgadamente dentro dos limites.

## Divergencia de plural informativa

Quando o header `Plural-Forms` de um `.po` diverge da regra CLDR canonica do
locale, `erli18n` **nao** rejeita nem reescreve — o header do `.po` sempre
vence em runtime ([PSD-004](/reference/psds)). A divergencia e apenas
sinalizada via log e telemetria. Detalhes em
[Pluralizacao](/guide/pluralization).
