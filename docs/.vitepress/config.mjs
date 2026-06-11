import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: 'erli18n',
  description: 'GNU gettext-compatible internationalization (i18n) for Erlang/OTP.',
  base: '/erli18n/',
  lang: 'en-US',
  cleanUrls: true,
  lastUpdated: true,

  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Guia', link: '/guide/catalogs', activeMatch: '/guide/' },
      { text: 'Referencia', link: '/reference/plurals', activeMatch: '/reference/' },
      { text: 'GitHub', link: 'https://github.com/eagle-head/erli18n' }
    ],

    sidebar: [
      {
        text: 'Getting Started',
        collapsed: false,
        items: [
          { text: 'Introducao', link: '/' },
          { text: 'Getting Started', link: '/getting-started' }
        ]
      },
      {
        text: 'Guia',
        collapsed: false,
        items: [
          { text: 'Catalogos (.po / .pot)', link: '/guide/catalogs' },
          { text: 'API de Lookup', link: '/guide/lookup-api' },
          { text: 'Pluralizacao', link: '/guide/pluralization' },
          { text: 'Telemetry', link: '/guide/telemetry' },
          { text: 'Paridade (gettexter / msgfmt)', link: '/guide/parity' }
        ]
      },
      {
        text: 'Referencia',
        collapsed: false,
        items: [
          { text: 'Plural-Forms & CLDR', link: '/reference/plurals' },
          { text: 'PSDs (PO-Semantics Decisions)', link: '/reference/psds' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/eagle-head/erli18n' }
    ],

    footer: {
      message: 'Released under the Apache License 2.0 (SPDX: Apache-2.0).',
      copyright: 'Copyright © 2025-present erli18n contributors'
    },

    search: {
      provider: 'local'
    },

    editLink: {
      pattern: 'https://github.com/eagle-head/erli18n/edit/main/docs/:path',
      text: 'Editar esta pagina no GitHub'
    },

    docFooter: {
      prev: 'Anterior',
      next: 'Proximo'
    }
  }
})
