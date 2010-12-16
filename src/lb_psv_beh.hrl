% @copyright 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%% @author Nico Kruber <kruber@zib.de>
%% @doc    Common types and function specs for passive load balancing algorithm
%%         implementations.
%% @end
%% @version $Id$

-include("scalaris.hrl").

-export([create_join/2, sort_candidates/1,
         check_config/0]).

-spec get_number_of_samples(ContactNodes::[comm:mypid()]) -> ok.
-spec create_join(DhtNodeState::dht_node_state:state(), SelectedKey::?RT:key()) -> lb_op:lb_op().
-spec sort_candidates(Ops::[lb_op:lb_op()]) -> [lb_op:lb_op()].

-spec check_config() -> boolean().
