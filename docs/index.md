---
layout: home

hero:
  name: erli18n
  text: i18n gettext para Erlang/OTP
  tagline: Internacionalizacao moderna, totalmente compativel com GNU gettext. Drop-in para arquivos .po / .pot do Poedit, Crowdin, Transifex, Weblate e do toolchain xgettext.
  actions:
    - theme: brand
      text: Getting Started
      link: /getting-started
    - theme: alt
      text: Ver no GitHub
      link: https://github.com/eagle-head/erli18n

features:
  - icon: 🔌
    title: Compativel com gettext
    details: Parser recursive-descent escrito a mao, honrando as 9 PO-Semantics Decisions (PSD-001..009). Funciona com Poedit, Crowdin, Transifex, Weblate e msgfmt sem adaptacoes. API espelha as macros C do GNU gettext (gettext / ngettext / pgettext / npgettext e variantes d / dc).
  - icon: 🔢
    title: Pluralizacao CLDR
    details: Avaliador recursive-descent da expressao C do header Plural-Forms. Regras de plural do CLDR inline para 49 locales. O header do .po e sempre a fonte de verdade em runtime; o CLDR e consultado apenas para emitir aviso de divergencia no load.
  - icon: 🏢
    title: Multi-tenant em runtime
    details: Carregue catalogos por (dominio, locale) em runtime com ensure_loaded / reload / unload. Layout de filesystem por convencao priv/locale/<locale>/LC_MESSAGES/<dominio>.po. Locale por processo via process dictionary, defaults app-wide via application env.
  - icon: 📈
    title: Telemetry de primeira classe
    details: 7 eventos :telemetry (spans de load / reload / unload de catalogo, lookup miss e fuzzy_skip opt-in, divergencia de plural, aviso de memoria rate-limited). telemetry e declarado via optional_applications (OTP 24+) — eventos so sao emitidos quando o consumidor envia a dependencia.
  - icon: ⚡
    title: Leitura lock-free em ETS
    details: Os reads de lookup rodam lock-free direto do processo chamador via ETS; as escritas sao serializadas pelo gen_server dono da tabela. Nao ha gargalo de processo no caminho de lookup — o hot path e anti-bottleneck por design.
  - icon: 🔒
    title: Hardening de seguranca
    details: Narrowing nos limites de configuracao e de process dictionary (config invalida vira crash explicito, nao surpresa silenciosa). Chaves de plural validadas contra o CLDR, parser defensivo e guard contra traducao vazia chegando a UI (PSD-003).
---
