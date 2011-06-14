%% @copyright 2011 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Thorsten Schuett <schuett@zib.de>
%% @version $Id: api_tx_SUITE.erl 1697 2011-04-29 09:25:23Z schintke $
-module(rrd_SUITE).
-author('schuett@zib.de').
-vsn('$Id: api_tx_SUITE.erl 1697 2011-04-29 09:25:23Z schintke $').

-include("unittest.hrl").

-compile(export_all).

all()   -> [simple_create,
            create_gauge
           ].
suite() -> [ {timetrap, {seconds, 40}} ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

simple_create(_Config) ->
    Adds = [{20, 5}, {25, 6}],
    DB0 = rrd:create(10, 10, gauge, 0),
    DB1 = lists:foldl(fun apply/2, DB0, Adds),
    ?equals(rrd:dump(DB1), [{20, 6}]),
    ok.

create_gauge(_Config) ->
    Adds = [{20, 5}, {25, 6}, {30, 1}, {42, 2}],
    DB0 = rrd:create(10, 10, gauge, 0),
    DB1 = lists:foldl(fun apply/2, DB0, Adds),
    ?equals(rrd:dump(DB1), [{40, 2}, {30, 1}, {20, 6}]),
    ok.

apply({Time, Value}, DB) ->
    rrd:add(Time, Value, DB).
