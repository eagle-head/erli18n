%% erli18n public include — compile-time domain macro.
%%
%% `?GETTEXT_DOMAIN` expands to a COMPILE-TIME LITERAL atom naming the
%% gettext domain a module's calls belong to. It deliberately does NOT
%% mirror the runtime `erli18n:textdomain/0` (an `application:get_env`
%% lookup): the rebar3 extractor (`rebar3 erli18n extract`) resolves a
%% call's domain by reading the abstract form AFTER `epp` macro expansion,
%% and can only key an entry under a literal atom. A macro that expanded to
%% a runtime call would yield a non-literal node, and the extractor would
%% (correctly) skip the d/dc-family Domain slot rather than mis-domain it.
%%
%% Default is the atom `default` — the same name `erli18n`'s private
%% `?DEFAULT_DOMAIN` uses at runtime, so an un-customized project's
%% extracted `.pot` lands under `default.pot`, matching the runtime lookup.
%%
%% To partition a module (or a whole project) into another domain, define
%% `GETTEXT_DOMAIN` to ANOTHER LITERAL ATOM before this include, e.g.:
%%
%%     -define(GETTEXT_DOMAIN, errors).
%%     -include_lib("erli18n/include/erli18n.hrl").
%%
%% The override MUST be a literal atom (`-define(GETTEXT_DOMAIN, errors).`),
%% never an expression that expands to a runtime call — otherwise the
%% extractor cannot resolve it at build time and the entry is skipped.
-ifndef(GETTEXT_DOMAIN).
-define(GETTEXT_DOMAIN, default).
-endif.
