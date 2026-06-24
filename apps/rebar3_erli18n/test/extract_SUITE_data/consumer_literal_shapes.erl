%% Extraction fixture covering the less-common literal SHAPES the extractor
%% accepts: a plain string literal `"..."` msgid, and a binary built from a
%% literal integer character segment. Also a non-literal context and a
%% non-literal plural that must each skip the call site cleanly.
-module(consumer_literal_shapes).

-include_lib("erli18n/include/erli18n.hrl").

-export([
    string_literal/0,
    integer_segment/0,
    surrogate_segment/0,
    nonliteral_context_skipped/1,
    nonliteral_plural_skipped/1,
    variable_binary_segment_skipped/1
]).

%% A plain charlist literal `"..."` as the msgid (not a binary).
string_literal() ->
    erli18n:gettext("Plain string msgid").

%% A binary literal whose segment is a literal integer character (`$A` = 65).
integer_segment() ->
    erli18n:gettext(<<65, 66, 67>>).

%% A binary literal whose integer segment is a UTF-16 surrogate code point
%% (`16#D800`). The segment is a literal integer node with default size — the
%% exact shape the extractor's integer-segment clause matches — but `16#D800`
%% is NOT a valid Unicode scalar value, so the extractor's own `<<Int/utf8>>`
%% encoding raises `badarg`. The msgid is written WITHOUT a `/utf8` specifier
%% (`<<16#D800>>`, not `<<16#D800/utf8>>`) so the source itself compiles
%% cleanly under `warnings_as_errors`; the surrogate validity check lives in
%% the EXTRACTOR. The extractor must treat this segment as non-resolvable and
%% SKIP the whole call site (per the dynamic-key-skip contract), never crashing
%% the extract/check/merge/report run on a stacktrace.
surrogate_segment() ->
    erli18n:gettext(<<16#D800>>).

%% Non-literal context in a p-family call -> skipped.
nonliteral_context_skipped(Ctx) ->
    erli18n:pgettext(Ctx, <<"Has dynamic context">>).

%% Non-literal plural in an n-family call -> skipped.
nonliteral_plural_skipped(Plural) ->
    erli18n:ngettext(<<"one thing">>, Plural, 2).

%% A binary msgid with a VARIABLE segment (`<<X/binary>>`) is not a
%% compile-time constant -> the whole call site is skipped.
variable_binary_segment_skipped(X) ->
    erli18n:gettext(<<X/binary, "suffix">>).
