%  @copyright 2014 Zuse Institute Berlin

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

%% @author Maximilian Michels <michels@zib.de>
%% @doc Active load balancing core module
%% @version $Id$
-module(lb_active).
-author('michels@zib.de').
-vsn('$Id$').

-behavior(gen_component).

-include("scalaris.hrl").
-include("record_helpers.hrl").

%%-define(TRACE(X,Y), ok).
-define(TRACE(X,Y), io:format("lb_active: " ++ X, Y)).

%% startup
-export([start_link/1, init/1, check_config/0, is_enabled/0]).
%% gen_component
-export([on_inactive/2, on/2]).
%% for calls from the dht node
-export([handle_dht_msg/2]).
%% for db monitoring
-export([init_db_rrd/2, update_db_rrd/2, update_db_monitor/2]).
%% Metrics
-export([get_load_metric/0, get_request_metric/0]).
% Load Balancing
-export([balance_nodes/3, balance_nodes/4, balance_noop/1]).

-ifdef(with_export_type_support).
-export_type([dht_message/0]).
-endif.

-record(lb_op, {id = ?required(id, lb_op)                           :: uid:global_uid(),
                type = ?required(type, lb_op)                       :: slide_pred | slide_succ | jump,
                %% receives load
                light_node = ?required(light, lb_op)                :: node:node_type(),
                light_node_succ = ?required(light_node_succ, lb_op) :: node:node_type(),
                %% sheds load
                heavy_node = ?required(heavy, lb_op)                :: node:node_type(),
                target = ?required(target, lb_op)                   :: ?RT:key(),
                %% time of the oldest data used for the decision for this lb_op
                data_time = ?required(data_time, lb_op)             :: erlang:timestamp(),
                time = os:timestamp()                               :: erlang:timestamp()
               }).

-type lb_op() :: #lb_op{}.

-type options() :: [tuple()].

-type dht_message() :: {lb_active, reset_db_monitors} |
                       {lb_active, balance,
                        HeavyNode::lb_info:lb_info(), LightNode::lb_info:lb_info(),
                        LightNodeSucc::lb_info:lb_info(), options()}.

-type module_state() :: tuple().

-type state() :: module_state().

-type load_metric() :: items | cpu | mem | tx_latency | net_throughput.
-type request_metric() :: db_reads | db_writes | db_requests.
-type balance_metric() :: items | requests | none.
-type metrics() :: [atom()]. %% TODO

%% available metrics
-define(LOAD_METRICS, [items, cpu, mem, db_reads, db_writes, db_requests, transactions, tx_latency, net_throughput]). 
-define(REQUEST_METRICS, [db_reads, db_writes, db_requests, net_throughput, net_latency]).

%% list of active load balancing modules available
-define(MODULES, [lb_active_karger, lb_active_directories]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Initialization %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Start this process as a gen component and register it in the dht node group
-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(DHTNodeGroup) ->
    gen_component:start_link(?MODULE, fun on_inactive/2, [],
                             [{pid_groups_join_as, DHTNodeGroup, lb_active}]).


%% @doc Initialization of monitoring values
-spec init([]) -> state().
init([]) ->
    set_time_last_balance(),
    set_last_db_monitor_init(),
    case collect_stats() of
        true ->
            _ = application:start(sasl),   %% required by os_mon.
            _ = application:start(os_mon), %% for monitoring cpu and memory usage.
            trigger(collect_stats);
        _ -> ok
    end,
    init_stats(),
    trigger(lb_trigger),
    %% keep the node id in state, currently needed to normalize histogram
    rm_loop:subscribe(
       self(), ?MODULE, fun rm_loop:subscribe_dneighbor_change_slide_filter/3,
       fun(Pid, _Tag, _Old, _New, _Reason) ->
           %% send reset message to dht node and lb_active process
           comm:send_local(self(), {lb_active, reset_db_monitors}),
           comm:send_local(Pid, {reset_monitors})
       end, inf),
    DhtNode = pid_groups:get_my(dht_node),
    comm:send_local(DhtNode, {lb_active, reset_db_monitors}),
    comm:send_local(self(), {reset_monitors}),
    {}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Startup message handler %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Handles all messages until enough monitor data has been collected.
-spec on_inactive(comm:message(), state()) -> state().
on_inactive({lb_trigger}, State) ->
    trigger(lb_trigger),
    case monitor_vals_appeared() of
        true ->
            InitState = call_module(init, []),
            ?TRACE("All monitor data appeared. Activating active load balancing~n", []),
            %% change handler and initialize module
            gen_component:change_handler(InitState, fun on/2);
        _    ->
            State
    end;

on_inactive({collect_stats} = Msg, State) ->
    on(Msg, State);

on_inactive({reset_monitors} = Msg, State) ->
    on(Msg, State);

on_inactive(Msg, State) ->
    %% at the moment, we simply ignore lb messages.
    ?TRACE("Unknown message ~p~n. Ignoring.", [Msg]),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Main message handler %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc On handler after initialization
-spec on(comm:message(), state()) -> state().
on({collect_stats}, State) ->
    trigger(collect_stats),
    CPU = cpu_sup:util(),
    MEM = case memsup:get_system_memory_data() of
              [{system_total_memory, _Total},
               {free_swap, _FreeSwap},
               {total_swap, _TotalSwap},
               {cached_memory, _CachedMemory},
               {buffered_memory, _BufferedMemory},
               {free_memory, FreeMemory},
               {total_memory, TotalMemory}] ->
                  FreeMemory / TotalMemory * 100
          end,
    monitor:client_monitor_set_value(lb_active, cpu, fun(Old) -> rrd:add_now(CPU, Old) end),
    %monitor:client_monitor_set_value(lb_active, cpu5min, fun(Old) -> rrd:add_now(CPU, Old) end),
    monitor:client_monitor_set_value(lb_active, mem, fun(Old) -> rrd:add_now(MEM, Old) end),
    %monitor:client_monitor_set_value(lb_active, mem5min, fun(Old) -> rrd:add_now(MEM, Old) end),
    State;

on({lb_trigger} = Msg, State) ->
    %% module can decide whether to trigger
    %% trigger(lb_trigger),
    call_module(handle_msg, [Msg, State]);

%% Gossip response before balancing takes place
on({gossip_reply, LightNode, HeavyNode, LightNodeSucc, Options,
    {gossip_get_values_best_response, LoadInfo}}, State) ->
    %% check the load balancing configuration by using
    %% the standard deviation from the gossip process.
    Size = gossip_load:load_info_get(size, LoadInfo),
    ItemsStdDev = gossip_load:load_info_get(stddev, LoadInfo),
    ItemsAvg = gossip_load:load_info_get(avgLoad, LoadInfo),
    Metrics =
        case config:read(lb_active_gossip_balance_metric) of %% TODO automatically enable gossip when laod metric other than items is active
            items ->
                [{avg, ItemsAvg},
                 {stddev, ItemsStdDev}];
            requests ->
                GossipModule = lb_active_gossip_request_metric,
                [{avg, gossip_load:load_info_other_get(avgLoad, GossipModule, LoadInfo)},
                 {stddev, gossip_load:load_info_other_get(stddev, GossipModule, LoadInfo)}]
        end,
    OptionsNew = [{dht_size, Size} | Metrics ++ Options],

    HeavyPid = node:pidX(lb_info:get_node(HeavyNode)),
    comm:send(HeavyPid, {lb_active, balance, HeavyNode, LightNode, LightNodeSucc, OptionsNew}),

    State;

%% lb_op received from dht_node and to be executed
on({balance_phase1, Op}, State) ->
    case op_pending() of
        true  -> ?TRACE("Pending op. Won't jump or slide. Discarding op ~p~n", [Op]);
        false ->
            case old_data(Op) of
                true -> ?TRACE("Old data. Discarding op ~p~n", [Op]);
                false ->
                    set_pending_op(Op),
                    case Op#lb_op.type of
                        jump ->
                            %% tell the succ of the light node in case of a jump
                            LightNodeSuccPid = node:pidX(Op#lb_op.light_node_succ),
                            comm:send(LightNodeSuccPid, {balance_phase2a, Op, comm:this()}, [{group_member, lb_active}]);
                        _ -> 
                            %% set pending op at other node
                            LightNodePid = node:pidX(Op#lb_op.light_node),
                            comm:send(LightNodePid, {balance_phase2b, Op, comm:this()}, [{group_member, lb_active}])
                    end
            end
    end,
    State;

%% Received by the succ of the light node which takes the light nodes' load
%% in case of a jump.
on({balance_phase2a, Op, ReplyPid}, State) ->
    case op_pending() of
        true -> ?TRACE("Pending op in phase2a. Discarding op ~p and replying~n", [Op]),
                comm:send(ReplyPid, {balance_failed, Op});
        false ->
            case old_data(Op) of
                true -> ?TRACE("Old data. Discarding op ~p~n", [Op]),
                        comm:send(ReplyPid, {balance_failed, Op});
                false ->
                    set_pending_op(Op),
                    LightNodePid = node:pidX(Op#lb_op.light_node),
                    comm:send(LightNodePid, {balance_phase2b, Op, ReplyPid}, [{group_member, lb_active}])
            end
    end,
    State;

%% The light node which receives load from the heavy node and initiates the lb op.
on({balance_phase2b, Op, ReplyPid}, State) ->
    case op_pending() of
        true -> ?TRACE("Pending op in phase2b. Discarding op ~p and replying~n", [Op]),
                comm:send(ReplyPid, {balance_failed, Op});
        false ->
            case old_data(Op) of
                true -> ?TRACE("Old data. Discarding op ~p~n", [Op]),
                        comm:send(ReplyPid, {balance_failed, Op#lb_op.id});
                false ->
                    set_pending_op(Op),
                    OpId = Op#lb_op.id,
                    Pid = node:pidX(Op#lb_op.light_node),
                    TargetKey = Op#lb_op.target,
                                set_pending_op(Op),
                    ?TRACE("Type: ~p Heavy: ~p Light: ~p Target: ~p~n", [Op#lb_op.type, Op#lb_op.heavy_node, Op#lb_op.light_node, TargetKey]),
                    case Op#lb_op.type of
                        jump ->
                            %% TODO could be replaced with send_local and comm:this() with self().
                            %% probably better to let the node slide/jump for itself.
                            %% revert changes in dht_node_move also...
                            comm:send(Pid, {move, start_jump, TargetKey, {jump, OpId}, comm:this()});
                        slide_pred ->
                            comm:send(Pid, {move, start_slide, pred, TargetKey, {slide_pred, OpId}, comm:this()});
                        slide_succ ->
                            comm:send(Pid, {move, start_slide, succ, TargetKey, {slide_succ, OpId}, comm:this()})
                    end
            end
    end,
    State;

on({balance_failed, OpId}, State) ->
    case get_pending_op() of
        undefined -> ?TRACE("Received balance_failed but OpId ~p was not pending~n", [OpId]);
        Op when Op#lb_op.id =:= OpId ->
            ?TRACE("Clearing pending op because of balance_failed ~p~n", [OpId]),
            set_pending_op(undefined);
        Op ->
            ?TRACE("Received balance_failed answer but OpId ~p didn't match pending id ~p~n", [OpId, Op#lb_op.id])
    end,
    State;

%% success does not imply the slide or jump was successfull. however,
%% slide or jump failures should very rarly occur because of the locking
%% and stale data detection.
on({balance_success, OpId}, State) ->
    case get_pending_op() of
        undefined -> ?TRACE("Received answer but OpId ~p was not pending~n", [OpId]);
        Op when Op#lb_op.id =:= OpId ->
            ?TRACE("Clearing pending op ~p~n", [OpId]),
            comm:send_local(self(), {reset_monitors}),
            set_pending_op(undefined),
            set_time_last_balance();
        Op ->
            ?TRACE("Received answer but OpId ~p didn't match pending id ~p~n", [OpId, Op#lb_op.id])
    end,
    State;

%% received reply at the sliding/jumping node
on({move, result, {_JumpOrSlide, OpId}, _Status}, State) ->
    ?TRACE("~p status with id ~p: ~p~n", [_JumpOrSlide, OpId, _Status]),
    case get_pending_op() of
        undefined -> ?TRACE("Received answer but OpId ~p was not pending~n", [OpId]);
        Op when Op#lb_op.id =:= OpId ->
            ?TRACE("Clearing pending op and replying to other node ~p~n", [OpId]),
            HeavyNodePid = node:pidX(Op#lb_op.heavy_node),
            comm:send(HeavyNodePid, {balance_success, OpId}, [{group_member, lb_active}]),
            comm:send_local(self(), {reset_monitors}),
            set_pending_op(undefined),
            set_time_last_balance(),
            case Op#lb_op.type of
                jump ->
                    %% also reply to light node succ in case of jump
                    LightNodeSucc = Op#lb_op.light_node_succ,
                    LightNodeSuccPid = node:pidX(LightNodeSucc),
                    comm:send(LightNodeSuccPid, {balance_success, OpId}, [{group_member, lb_active}]);
                _ ->
                    ok
            end;
        Op ->
            ?TRACE("Received answer but OpId ~p didn't match pending id ~p~n", [OpId, Op#lb_op.id])
    end,
    State;

on({reset_monitors}, State) ->
    init_stats(),
    erlang:erase(metric_available),
    ?TRACE("Reseting monitors ~n", []),
    gen_component:change_handler(State, fun on_inactive/2);

on({web_debug_info, Requestor}, State) ->
    KVList =
        [{"active module", webhelpers:safe_html_string("~p", [get_lb_module()])},
         {"load metric", webhelpers:safe_html_string("~p", [config:read(lb_active_load_metric)])},
         {"load metric value:", webhelpers:safe_html_string("~p", [get_load_metric()])},
         {"request metric", webhelpers:safe_html_string("~p", [config:read(lb_active_request_metric)])},
         {"request metric value", webhelpers:safe_html_string("~p", [get_request_metric()])},
         {"balance with", webhelpers:safe_html_string("~p", [config:read(lb_active_balance_metric)])},
         {"last balance:", webhelpers:safe_html_string("~p", [get_time_last_balance()])},
         {"pending op:",   webhelpers:safe_html_string("~p", [get_pending_op()])}
        ],
    Return = KVList ++ call_module(get_web_debug_kv, [State]),
    comm:send_local(Requestor, {web_debug_info_reply, Return}),
    State;

on(Msg, State) ->
    call_module(handle_msg, [Msg, State]).

%%%%%%%%%%%%%%%%%%%%%%% Load Balancing %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec balance_nodes(lb_info:lb_info(), lb_info:lb_info(), options()) -> ok.
balance_nodes(HeavyNode, LightNode, Options) ->
    balance_nodes(HeavyNode, LightNode, nil, Options).

-spec balance_nodes(lb_info:lb_info(), lb_info:lb_info(), lb_info:lb_info() | nil, options()) -> ok.
balance_nodes(HeavyNode, LightNode, LightNodeSucc, Options) ->
    case config:read(lb_active_use_gossip) of
        true -> %% Retrieve global info from gossip before balancing
            GossipPid = pid_groups:get_my(gossip),
            LBActivePid = pid_groups:get_my(lb_active),
            Envelope = {gossip_reply, LightNode, HeavyNode, LightNodeSucc, Options, '_'},
            ReplyPid = comm:reply_as(LBActivePid, 6, Envelope),
            comm:send_local(GossipPid, {get_values_best, {gossip_load, default}, ReplyPid});
        _ ->
            HeavyPid = node:pidX(lb_info:get_node(HeavyNode)),
            comm:send(HeavyPid, {lb_active, balance, HeavyNode, LightNode, LightNodeSucc, Options})
    end.

-spec balance_noop(options()) -> ok.
%% no op but we sent back simulation results
balance_noop(Options) ->
    case proplists:get_value(simulate, Options) of
        undefined -> ok;
        ReqId ->
            ReplyTo = proplists:get_value(reply_to, Options),
            Id = proplists:get_value(id, Options),
            comm:send(ReplyTo, {simulation_result, Id, ReqId, 0})
    end.

%%%%%%%%%%%%%%%%%%%%%%%% Calls from dht_node %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Process load balancing messages sent to the dht node
-spec handle_dht_msg(dht_message(), dht_node_state:state()) -> dht_node_state:state().

handle_dht_msg({lb_active, reset_db_monitors}, DhtState) ->
    case monitor_db() of
        true ->
            MyRange = dht_node_state:get(DhtState, my_range),
            MyId = dht_node_state:get(DhtState, node_id),
            DhtNodeMonitor = dht_node_state:get(DhtState, monitor_proc),
            comm:send_local(DhtNodeMonitor, {db_op_init, MyId, MyRange});
        false -> ok
    end,
    DhtState;

%% We received a jump or slide operation from a LightNode.
%% In either case, we'll compute the target id and send out
%% the jump or slide message to the LightNode.
handle_dht_msg({lb_active, balance, HeavyNode, LightNode, LightNodeSucc, Options}, DhtState) ->
    %% check if we are the correct node
    case lb_info:get_node(HeavyNode) =/= dht_node_state:get(DhtState, node) of
        true -> ?TRACE("I was mistaken for the HeavyNode. Doing nothing~n", []), ok;
        false ->
            %% get our load info again to have the newest data available
            MyNode = lb_info:new(dht_node_state:details(DhtState)),
            JumpOrSlide = %case lb_info:neighbors(MyNode, LightNode) of
                case LightNodeSucc =:= nil of
                    true  -> slide;
                    false -> jump
                end,

                ProposedTargetLoad = lb_info:get_target_load(JumpOrSlide, MyNode, LightNode),

                TargetLoad =
                    case gossip_available(Options) of
                        true -> Avg = proplists:get_value(avg, Options),
                                %% don't take away more items than the average
                                ?IIF(ProposedTargetLoad > Avg,
                                     trunc(Avg), ProposedTargetLoad);
                        false -> ProposedTargetLoad
                    end,

                {From, To, Direction} =
                    case JumpOrSlide =:= jump orelse lb_info:is_succ(MyNode, LightNode) of
                        true  -> %% Jump or heavy node is succ of light node
                            {dht_node_state:get(DhtState, pred_id), dht_node_state:get(DhtState, node_id), forward};
                        false -> %% Light node is succ of heavy node
                            {dht_node_state:get(DhtState, node_id), dht_node_state:get(DhtState, pred_id), backward}
                    end,

                {SplitKey, TakenLoad} =
                    case config:read(lb_active_balance_metric) of
                        items ->
                            dht_node_state:get_split_key(DhtState, From, To, TargetLoad, Direction);
                        none ->
                            dht_node_state:get_split_key(DhtState, From, To, TargetLoad, Direction);
                        requests ->
                            case get_request_histogram_split_key(TargetLoad, Direction, lb_info:get_time(HeavyNode)) of
                                %% TODO fall back in a more clever way / abort lb request
                                failed ->
                                    ?TRACE("get_request_histogram failed~n", []),
                                    dht_node_state:get_split_key(DhtState, From, To, 1, Direction);
                                Val -> Val
                            end
                    end,

                ?TRACE("SplitKey: ~p TargetLoad: ~p TakenLoad: ~p~n", [SplitKey, TargetLoad, TakenLoad]),

            case is_simulation(Options) of

                true -> %% compute result of simulation and reply
                    ReqId = proplists:get_value(simulate, Options),
                    LoadChange =
                        case JumpOrSlide of
                            slide -> lb_info:get_load_change_slide(TakenLoad, HeavyNode, LightNode);
                            jump  -> lb_info:get_load_change_jump(TakenLoad, HeavyNode, LightNode, LightNodeSucc)
                        end,
                    ReplyTo = proplists:get_value(reply_to, Options),
                    Id = proplists:get_value(id, Options),
                    comm:send(ReplyTo, {simulation_result, Id, ReqId, LoadChange});

                false -> %% perform balancing
                    StdDevTest =
                        case gossip_available(Options) of
                            %% gossip information available
                            true ->
                                S = config:read(lb_active_gossip_stddev_threshold),
                                DhtSize = proplists:get_value(dht_size, Options),
                                StdDev = proplists:get_value(stddev, Options),
                                Variance = StdDev * StdDev,
                                VarianceChange =
                                    case JumpOrSlide of
                                        slide -> lb_info:get_load_change_slide(TakenLoad, DhtSize, HeavyNode, LightNode);
                                        jump -> lb_info:get_load_change_jump(TakenLoad, DhtSize, HeavyNode, LightNode, LightNodeSucc)
                                    end,
                                VarianceNew = Variance + VarianceChange,
                                StdDevNew = ?IIF(VarianceNew >= 0, math:sqrt(VarianceNew), StdDev),
                                ?TRACE("New StdDev: ~p Old StdDev: ~p~n", [StdDevNew, StdDev]),
                                StdDevNew < StdDev * (1 - S / DhtSize);
                            %% gossip not available, skipping this test
                            false -> true
                        end,
                    case StdDevTest andalso TakenLoad > 0 of
                        false -> ?TRACE("No balancing: stddev was not reduced enough.~n", []);
                        true ->
                            ?TRACE("Sending out lb op.~n", []),
                            OpId = uid:get_global_uid(),
                            Type =  if  JumpOrSlide =:= jump -> jump;
                                        Direction =:= forward -> slide_succ;
                                        Direction =:= backward -> slide_pred
                                    end,
                            OldestDataTime = if Type =:= jump ->
                                                    lb_info:get_oldest_data_time([LightNode, HeavyNode, LightNodeSucc]);
                                                true ->
                                                    lb_info:get_oldest_data_time([LightNode, HeavyNode])
                                             end,
                            Op = #lb_op{id = OpId, type = Type,
                                        light_node = lb_info:get_node(LightNode),
                                        light_node_succ = lb_info:get_succ(LightNode),
                                        heavy_node = lb_info:get_node(HeavyNode),
                                        target = SplitKey,
                                        data_time = OldestDataTime},
                            LBModule = pid_groups:get_my(?MODULE),
                            comm:send_local(LBModule, {balance_phase1, Op})
                    end
            end

    end,
    DhtState;

handle_dht_msg(Msg, DhtState) ->
    call_module(handle_dht_msg, [Msg, DhtState]).

%%%%%%%%%%%%%%%%%%%%%%%% Monitoring values %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-compile({inline, [init_db_rrd/2]}).
%% @doc Called by dht node process to initialize the db monitors
-spec init_db_rrd(MyId::?RT:key(), MyRange::intervals:interval()) -> rrd:rrd().
init_db_rrd(MyId, MyRange) ->
    Type = config:read(lb_active_db_monitor),
    History = config:read(lb_active_monitor_history),
    HistogramSize = config:read(lb_active_histogram_size),
    HistogramType =
        case intervals:in(?MINUS_INFINITY, MyRange) andalso MyRange =/= intervals:all() of
            false ->
                {histogram, HistogramSize};
            true -> %% we need a normalized histogram because of the circular key space
                NormFun =
                    fun(Val) ->
                            case Val - MyId of
                                NormVal when NormVal =< ?MINUS_INFINITY ->
                                    ?PLUS_INFINITY + NormVal - 1;
                                NormVal ->
                                    NormVal - 1
                            end
                    end,
                InverseFun =
                    fun(NormVal) ->
                            (NormVal + MyId + 1) rem ?PLUS_INFINITY
                    end,
                {histogram, HistogramSize, NormFun, InverseFun}
        end,
    MonitorResSecs = config:read(lb_active_monitor_resolution) div 1000,
    {MegaSecs, Secs, _Microsecs} = os:timestamp(),
    %% synchronize the start time for all monitors to a divisible of the monitor interval
    StartTime = {MegaSecs, Secs - Secs rem MonitorResSecs + MonitorResSecs, 0},
    RRD  = rrd:create(MonitorResSecs*1000000, History + 1, HistogramType, StartTime),
    Monitor = pid_groups:get_my(monitor),
    monitor:clear_rrds(Monitor, [{lb_active, Type}]),
    monitor:monitor_set_value(lb_active, Type, RRD),
    RRD.

-compile({inline, [update_db_monitor/2]}).
%% @doc Updates the local rrd for reads or writes and checks for reporting
-spec update_db_monitor(Type::db_reads | db_writes, Value::?RT:key()) -> ok.
update_db_monitor(Type, Value) ->
    case monitor_db() andalso config:read(lb_active_db_monitor) =:= Type of
        true ->
            DhtNodeMonitor = pid_groups:get_my(dht_node_monitor),
            comm:send_local(DhtNodeMonitor, {db_op, Value});
        _ -> ok
    end.

-compile({inline, [update_db_rrd/2]}).
%% @doc Updates the local rrd for reads or writes and checks for reporting
-spec update_db_rrd(Value::?RT:key(), RRD::rrd:rrd()) -> rrd:rrd().
update_db_rrd(Key, OldRRD) ->
    Type = config:read(lb_active_db_monitor),
    NewRRD = rrd:add_now(Key, OldRRD),
    monitor:check_report(lb_active, Type, OldRRD, NewRRD),
    NewRRD.

-spec init_stats() -> ok.
init_stats() ->
    case collect_stats() of
        true ->
            Resolution = config:read(lb_active_monitor_resolution),
            %LongTerm  = rrd:create(60 * 5 * 1000000, 5, {timing, '%'}),
            %monitor:client_monitor_set_value(lb_active, cpu5min, LongTerm),
            %monitor:client_monitor_set_value(lb_active, mem5min, LongTerm),
            ShortTerm = rrd:create(Resolution * 1000, 5, gauge),
            monitor:client_monitor_set_value(lb_active, cpu, ShortTerm),
            monitor:client_monitor_set_value(lb_active, mem, ShortTerm);
        _ ->
            ok
    end.

%% @doc initially checks if enough metric data has been collected
-spec monitor_vals_appeared() -> boolean().
monitor_vals_appeared() ->
    Metric = config:read(lb_active_load_metric),
    case erlang:get(metric_available) of
        true -> true;
        _ ->
            case collect_phase() andalso get_load_metric(Metric, strict) =:= unknown of
                true ->
                    false;
                _ ->
                    erlang:put(metric_available, true),
                    true
            end
    end.

%% @doc checks if the load balancing is in the data collection phase
-spec collect_phase() -> boolean().
collect_phase() ->
    History = config:read(lb_active_monitor_history),
    Resolution = config:read(lb_active_monitor_resolution),
    CollectPhase = History * Resolution,
    LastInit = get_last_db_monitor_init(),
    timer:now_diff(os:timestamp(), LastInit) div 1000 =< CollectPhase.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%     Metrics       %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_load_metric() -> items | number().
get_load_metric() ->
    Metric = config:read(lb_active_load_metric),
    Value = case get_load_metric(Metric) of
                unknown -> 0.0;
                items -> items;
                Val -> util:round(Val, 2)
            end,
    ?TRACE("Load: ~p~n", [Value]),
    Value.

-spec get_load_metric(load_metric()) -> unknown | items | number(). %% TODO unknwon shouldn't happen here, in theory it can TODO
get_load_metric(Metric) ->
    get_load_metric(Metric, normal).

-spec get_load_metric(load_metric(), normal | strict) -> unknown | items | number().
get_load_metric(Metric, Mode) ->
    case Metric of
        cpu          -> get_vm_metric(cpu, Mode);
        mem          -> get_vm_metric(mem, Mode);
        %net_latency  ->
        %net_bandwith ->
        %tx_latency   -> get_dht_metric({api_tx, req_list}, avg, Mode);
        %transactions -> get_dht_metric({api_tx, req_list}, count, Mode);
        items        -> items;
        _            -> throw(metric_not_available)
    end.

-spec get_request_metric() -> number().
get_request_metric() ->
    Metric = config:read(lb_active_request_metric),
    Value = case get_request_metric(Metric) of
                unknown -> 0;
                Val -> erlang:round(Val)
            end,
    io:format("Requests: ~p~n", [Value]),
    Value.

-spec get_request_metric(request_metric()) -> unknown | number().
get_request_metric(Metric) ->
    get_request_metric(Metric, normal).

-spec get_request_metric(request_metric(), normal | strict) -> unknown | number().
get_request_metric(Metric, Mode) ->
    case Metric of
        db_reads -> get_dht_metric(db_reads, Mode);
        db_writes -> get_dht_metric(db_writes, Mode)
        %db_requests  -> get_request_metric(db_reads, Mode) +
        %                get_request_metric(db_writes, Mode); %% TODO
    end.

-spec get_vm_metric(load_metric(), normal | strict) -> unknown | number().
get_vm_metric(Metric, Mode) ->
    ClientMonitorPid = pid_groups:pid_of("clients_group", monitor),
    get_metric(ClientMonitorPid, Metric, Mode).

-spec get_dht_metric(load_metric() | request_metric(), normal | strict) -> unknown | number().
get_dht_metric(Metric, Mode) ->
    MonitorPid = pid_groups:get_my(monitor),
    get_metric(MonitorPid, Metric, Mode).

-spec get_metric(pid(), monitor:table_index(), normal | strict) -> unknown | number().
get_metric(MonitorPid, Metric, Mode) ->
    [{_Process, _Key, RRD}] = monitor:get_rrds(MonitorPid, [{lb_active, Metric}]),
    case RRD of
        undefined ->
            unknown;
        RRD ->
            History = config:read(lb_active_monitor_history),
            SlotLength = rrd:get_slot_length(RRD),
            {MegaSecs, Secs, MicroSecs} = os:timestamp(),
            Vals = [begin
                        %% get stable value off an old slot
                        Value = rrd:get_value(RRD, {MegaSecs, Secs, MicroSecs - Offset*SlotLength}),
                        %io:format("Value ~p~n", [Value]),
                        %case Value of undefined -> io:format("Undefined value considered.~n"); _->ok end,
                        get_value_type(Value, rrd:get_type(RRD))
                    end || Offset <- lists:seq(1, History)],
            io:format("~p Vals: ~p~n", [Metric, Vals]),
            case Mode of
                strict -> ?IIF(lists:member(unknown, Vals), unknown, avg_weighted(Vals));
                _ -> avg_weighted(Vals)
            end
    end.

-spec get_value_type(RRD::rrd:data_type(), Type::rrd:timeseries_type()) -> unknown | number().
get_value_type(undefined, _Type) ->
    unknown;
get_value_type(Value, _Type) when is_number(Value) ->
    Value;
get_value_type(Value, {histogram, _Size}) ->
    histogram:get_num_inserts(Value);
get_value_type(Value, {histogram, _Size, _NormFun, _InverseFun}) ->
    histogram_normalized:get_num_inserts(Value).

%% @doc returns the weighted average of a list using decreasing weight
-spec avg_weighted([number()]) -> number().
avg_weighted([]) ->
    0;
avg_weighted(List) ->
    avg_weighted(List, _Weight=length(List), _Normalize=0, _Sum=0).

%% @doc returns the weighted average of a list using decreasing weight
-spec avg_weighted([], Weight::0, Normalize::pos_integer(), Sum::number()) -> unknown | float();
                  ([number()| unknown,...], Weight::pos_integer(), Normalize::non_neg_integer(), Sum::number()) -> unknown | float().
avg_weighted([], 0, 0, _Sum) ->
    unknown;
avg_weighted([], 0, N, Sum) ->
    Sum/N;
avg_weighted([unknown | Other], Weight, N, Sum) ->
    avg_weighted(Other, Weight - 1, N + Weight, Sum);
avg_weighted([Element | Other], Weight, N, Sum) ->
    avg_weighted(Other, Weight - 1, N + Weight, Sum + Weight * Element).

-spec get_request_histogram_split_key(TargetLoad::pos_integer(),
                                      Direction::forward | backward,
                                      erlang:timestamp())
        -> {?RT:key(), TakenLoad::non_neg_integer()} | failed.
get_request_histogram_split_key(TargetLoad, Direction, {_, _, _} = Time) ->
    MonitorPid = pid_groups:get_my(monitor),
    RequestMetric = config:read(lb_active_request_metric),
    [{_Process, _Key, RRD}] = monitor:get_rrds(MonitorPid, [{lb_active, RequestMetric}]),
    case RRD of
        undefined ->
            log:log(warn, "No request histogram available because no rrd is available."),
            failed;
        RRD ->
            case rrd:get_value(RRD, Time) of
                undefined ->
                    log:log(warn, "No request histogram available. Time slot not found."),
                    failed;
                Histogram ->
                    ?TRACE("Got histogram to compute split key: ~p~n", [Histogram]),
                    {Status, Key, TakenLoad} =
                        case {histogram_normalized:is_normalized(Histogram), Direction} of
                            {true, forward} -> histogram_normalized:foldl_until(TargetLoad, Histogram);
                            {true, backward} -> histogram_normalized:foldr_until(TargetLoad, Histogram);
                            {false, forward} -> histogram:foldl_until(TargetLoad, Histogram);
                            {false, backward} -> histogram:foldr_until(TargetLoad, Histogram)
                        end,
                    case {Status, Direction} of
                        {fail, _} -> failed;
                        {ok, _} -> {Key, TakenLoad}
                    end
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%% Util %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec is_enabled() -> boolean().
is_enabled() ->
    config:read(lb_active).

-spec call_module(atom(), list()) -> term().
call_module(Fun, Args) ->
    apply(get_lb_module(), Fun, Args).

-spec get_lb_module() -> atom() | failed.
get_lb_module() ->
    config:read(lb_active_module).

-spec collect_stats() -> boolean().
collect_stats() ->
    Metrics = [cpu, mem], %% TODO
    lists:member(config:read(lb_active_load_metric), Metrics).

-compile({inline, [monitor_db/0]}).
-spec monitor_db() -> boolean().
monitor_db() ->
    is_enabled() andalso config:read(lb_active_db_monitor) =/= none.

-spec get_pending_op() -> undefined | lb_op().
get_pending_op() ->
    erlang:get(pending_op).

-spec set_pending_op(undefined | lb_op()) -> ok.
set_pending_op(Op) ->
    erlang:put(pending_op, Op),
    ok.

-spec op_pending() -> boolean().
op_pending() ->
    case erlang:get(pending_op) of
        undefined -> false;
        OtherOp ->
            case old_op(OtherOp) of
                false -> true;
                true -> %% remove old op
                    ?TRACE("Removing old op ~p~n", [OtherOp]),
                    erlang:erase(pending_op),
                    false
            end
    end.

-spec old_op(lb_op()) -> boolean().
old_op(Op) ->
    Threshold = config:read(lb_active_wait_for_pending_ops),
    timer:now_diff(os:timestamp(), Op#lb_op.time) div 1000 > Threshold.

-spec old_data(lb_op()) -> boolean().
old_data(Op) ->
    LastBalanceTime = erlang:get(time_last_balance),
    DataTime = Op#lb_op.data_time,
    timer:now_diff(LastBalanceTime, DataTime) > 0.

-spec get_time_last_balance() -> erlang:timestamp().
get_time_last_balance() ->
    erlang:get(time_last_balance).

-spec set_time_last_balance() -> ok.
set_time_last_balance() ->
    erlang:put(time_last_balance, os:timestamp()), ok.

-spec set_last_db_monitor_init() -> ok.
set_last_db_monitor_init() ->
    erlang:put(last_db_monitor_init, os:timestamp()), ok.

-spec get_last_db_monitor_init() -> erlang:timestamp().
get_last_db_monitor_init() ->
    erlang:get(last_db_monitor_init).

-spec gossip_available(options()) -> boolean().
gossip_available(Options) ->
    proplists:is_defined(dht_size, Options) andalso
        proplists:is_defined(avg, Options) andalso
        proplists:is_defined(stddev, Options).

-spec is_simulation(options()) -> boolean().
is_simulation(Options) ->
    proplists:is_defined(simulate, Options).

-spec trigger(atom()) -> ok.
trigger(Trigger) ->
    Interval =
        case Trigger of
            lb_trigger -> config:read(lb_active_interval);
            collect_stats -> config:read(lb_active_monitor_interval)
        end,
    msg_delay:send_trigger(Interval div 1000, {Trigger}).

%% @doc config check registered in config.erl
-spec check_config() -> boolean().
check_config() ->

    config:cfg_is_bool(lb_active) and
    config:cfg_is_in(lb_active_module, ?MODULES) and

    config:cfg_is_integer(lb_active_interval) and
    config:cfg_is_greater_than(lb_active_interval, 0) and

    config:cfg_is_in(lb_active_load_metric, ?LOAD_METRICS) and

    config:cfg_is_in(lb_active_request_metric, ?REQUEST_METRICS) and

    config:cfg_is_in(lb_active_balance_metric, [items, requests]) and

    config:cfg_is_bool(lb_active_use_gossip) and
    config:cfg_is_greater_than(lb_active_gossip_stddev_threshold, 0) and

    config:cfg_is_integer(lb_active_histogram_size) and
    config:cfg_is_greater_than(lb_active_histogram_size, 0) and

    config:cfg_is_integer(lb_active_monitor_resolution) and
    config:cfg_is_greater_than(lb_active_monitor_resolution, 0) and

    config:cfg_is_integer(lb_active_monitor_interval) and
    config:cfg_is_greater_than(lb_active_monitor_interval, 0) and

    config:cfg_is_less_than(lb_active_monitor_interval, config:read(lb_active_monitor_resolution)) and

    config:cfg_is_integer(lb_active_monitor_history) and
    config:cfg_is_greater_than(lb_active_monitor_history, 0) and

    config:cfg_is_in(lb_active_db_monitor, [none, db_reads, db_writes]) and

    config:cfg_is_integer(lb_active_wait_for_pending_ops) and
    config:cfg_is_greater_than(lb_active_wait_for_pending_ops, 0) and

    call_module(check_config, []).