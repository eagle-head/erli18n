-module(erli18n_app).

-moduledoc """
Callback de `application` da biblioteca erli18n. Sobe a árvore de
supervisão raiz (`erli18n_sup`) ao iniciar a aplicação e não mantém
estado próprio no shutdown.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc """
Callback de start da aplicação. Inicia a árvore de supervisão raiz via
`erli18n_sup:start_link/0`, retornando `{ok, Pid}` do supervisor. Os
argumentos `Type` e `Args` do OTP são ignorados.
""".
start(_Type, _Args) ->
    erli18n_sup:start_link().

-doc """
Callback de stop da aplicação. Sem estado a desfazer (a supervisão cuida
do encerramento dos filhos), apenas retorna `ok`.
""".
stop(_State) ->
    ok.
