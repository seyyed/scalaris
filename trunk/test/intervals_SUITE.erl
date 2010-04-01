%%%-------------------------------------------------------------------
%%% File    : intervals_SUITE.erl
%%% Author  : Thorsten Schuett <schuett@zib.de>
%%% Description : Unit tests for src/intervals.erl
%%%
%%% Created :  21 Feb 2008 by Thorsten Schuett <schuett@zib.de>
%%%-------------------------------------------------------------------
-module(intervals_SUITE).

-author('schuett@zib.de').
-vsn('$Id$ ').

-compile(export_all).

-include_lib("unittest.hrl").

all() ->
    [new, is_empty, cut, tc1,
     tester_make, tester_in, tester_sanitize,
     tester_cut, tester_not_cut, tester_not_cut2].

suite() ->
    [
     {timetrap, {seconds, 10}}
    ].

init_per_suite(Config) ->
    crypto:start(),
    Config.

end_per_suite(_Config) ->
    ok.

new(_Config) ->
    intervals:new("a", "b"),
    ?assert(true).

is_empty(_Config) ->
    NotEmpty = intervals:new("a", "b"),
    Empty = intervals:empty(),
    ?assert(not intervals:is_empty(NotEmpty)),
    ?assert(intervals:is_empty(Empty)).
    
cut(_Config) ->
    NotEmpty = intervals:new("a", "b"),
    Empty = intervals:empty(),
    ?assert(intervals:is_empty(intervals:cut(NotEmpty, Empty))),
    ?assert(intervals:is_empty(intervals:cut(Empty, NotEmpty))),
    ?assert(intervals:is_empty(intervals:cut(NotEmpty, Empty))),
    ?assert(not intervals:is_empty(intervals:cut(NotEmpty, NotEmpty))),
    ?assert(intervals:cut(NotEmpty, NotEmpty) == NotEmpty),
    ok.
    
tc1(_Config) ->
    ?assert(intervals:is_covered([{interval,minus_infinity,42312921949186639748260586507533448975},
				  {interval,316058952221211684850834434588481137334,plus_infinity}], 
				 {interval,316058952221211684850834434588481137334,
				  127383513679421255614104238365475501839})),
    ?assert(intervals:is_covered([{element,187356034246551717222654062087646951235},
				  {element,36721483204272088954146455621100499974}],
				 {interval,36721483204272088954146455621100499974,
				  187356034246551717222654062087646951235})),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% intervals:make/1
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(prop_make/2 :: (intervals:key(), intervals:key()) -> boolean()).
prop_make(X, Y) ->
    intervals:make({X,Y}) == intervals:new(X, Y).

tester_make(_Config) ->
    tester:test(intervals_SUITE, prop_make, 2, 10).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% intervals:in/2
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(prop_in/2 :: (intervals:key(), intervals:key()) -> boolean()).
prop_in(X, Y) ->
    intervals:in(X, intervals:new(X, Y)) and
        intervals:in(Y, intervals:new(X, Y)).

tester_in(_Config) ->
    tester:test(intervals_SUITE, prop_in, 2, 10).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% intervals:sanitize/2
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(prop_sanitize/2 :: (list(intervals:interval()), intervals:key()) -> boolean()).
prop_sanitize(Is, X) ->
    intervals:in(X, Is) ==
        intervals:in(X, intervals:sanitize(Is)).

tester_sanitize(_Config) ->
    tester:test(intervals_SUITE, prop_sanitize, 2, 10).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% intervals:cut/2
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(prop_cut/3 :: (intervals:interval(), intervals:interval(), intervals:key()) -> boolean()).
prop_cut(A, B, X) ->
    ?implies(intervals:in(X, A) and intervals:in(X, B),
             intervals:in(X, intervals:cut(A, B))).

-spec(prop_not_cut/3 :: (intervals:interval(), intervals:interval(), intervals:key()) -> boolean()).
prop_not_cut(A, B, X) ->
    ?implies(intervals:in(X, A)
             xor intervals:in(X, B),
             not intervals:in(X, intervals:cut(A, B))).

-spec(prop_not_cut2/3 :: (intervals:interval(), intervals:interval(), intervals:key()) -> boolean()).
prop_not_cut2(A, B, X) ->
    ?implies(not intervals:in(X, A)
             and not intervals:in(X, B),
             not intervals:in(X, intervals:cut(A, B))).

tester_cut(_Config) ->
    tester:test(?MODULE, prop_cut, 3, 10).

tester_not_cut(_Config) ->
    tester:test(?MODULE, prop_not_cut, 3, 10).

tester_not_cut2(_Config) ->
    tester:test(?MODULE, prop_not_cut2, 3, 10).

