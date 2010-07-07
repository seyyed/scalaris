% @copyright 2009, 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin,
%                 onScale solutions GmbH

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

%% @author Florian Schintke <schintke@onscale.de>
%% @doc Part of a generic implementation of transactions using Paxos Commit -
%%      the roles of the (replicated) transaction manager TM and RTM.
%% @end
-module(tx_tm_rtm).
-author('schintke@onscale.de').
-vsn('$Id$').

%%-define(TRACE_RTM_MGMT(X,Y), io:format(X,Y)).
-define(TRACE_RTM_MGMT(X,Y), ok).
%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(_X,_Y), ok).
-behaviour(gen_component).
-include("scalaris.hrl").

%% public interface for transaction validation using Paxos-Commit.
-export([commit/4]).
-export([msg_commit_reply/3]).

%% functions for gen_component module, supervisor callbacks and config
-export([start_link/2]).
-export([on/2, init/1]).
-export([on_init/2]).
-export([check_config/0]).

%% messages a client has to expect when using this module
msg_commit_reply(Client, ClientsID, Result) ->
    comm:send(Client, {tx_tm_rtm_commit_reply, ClientsID, Result}).

%% public interface for transaction validation using Paxos-Commit.
%% ClientsID may be nil, its not used by tx_tm. It will be repeated in
%% replies to allow to map replies to the right requests in the
%% client.
commit(TM, Client, ClientsID, TLog) ->
    Msg = {tx_tm_rtm_commit, Client, ClientsID, TLog},
    comm:send_local(TM, Msg).

%% be startable via supervisor, use gen_component
-spec start_link(instanceid(), any()) -> {ok, pid()}.
start_link(InstanceId, Name) ->
    gen_component:start_link(?MODULE,
                             [InstanceId, Name],
                             [{register, InstanceId, Name}]).

%% initialize: return initial state.
-spec init([instanceid() | any()]) -> any().
init([InstanceID, Name]) ->
    ?TRACE("tx_tm_rtm:init for instance: ~p ~p~n", [InstanceID, Name]),
    %% For easier debugging, use a named table (generates an atom)
    TableName =
        list_to_atom(lists:flatten(
                       io_lib:format("~p_tx_tm_rtm_~p", [InstanceID, Name]))),
    pdb:new(TableName, [set, protected, named_table]),
    %% use random table name provided by ets to *not* generate an atom
    %% TableName = pdb:new(?MODULE, [set, private]),
    LAcceptor = process_dictionary:get_group_member(paxos_acceptor),
    LLearner = process_dictionary:get_group_member(paxos_learner),
    State = {_RTMs = [], TableName, _Role = Name, LAcceptor, LLearner},

    %% start getting rtms and maintain them.
    case Name of
        tx_tm ->
            idholder:get_id(),
            gen_component:change_handler(State, on_init);
        _ -> State
    end.

%% forward to local acceptor but add my role to the paxos id
on({proposer_accept, Proposer, PaxosID, Round, Value} = _Msg,
   {_RTMs, _TableName, Role, LAcceptor, _LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on(~p)~n", [_Msg]),
    comm:send_local(LAcceptor, {proposer_accept, Proposer, {PaxosID, Role}, Round, Value}),
    State;

%% forward from acceptor to local learner (take 'Role' away from PaxosId)
on({acceptor_accepted, {PaxosID, _InRole}, Round, Value} = _Msg,
   {_RTMs, _TableName, _MyRole, _LAcceptor, LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on(~p)~n", [_Msg]),
    comm:send_local(LLearner, {acceptor_accepted, PaxosID, Round, Value}),
    State;

%% a paxos consensus is decided (msg generated by learner.erl)
on({learner_decide, ItemId, _PaxosID, Value} = Msg,
   {_,_, _Role, _,_} = State) ->
    ?TRACE("tx_tm_rtm:on(~p)~n", [_Msg]),
    {ErrItem, ItemState} = my_get_item_entry(ItemId, State),
    case ok =/= ErrItem of
        true -> %% new / uninitialized
            %% hold back and handle when corresponding tx_state is
            %% created in init_RTM
            %% io:format("Holding back a learner decide for ~p~n", [_Role]),
            TmpItemState = tx_item_state:hold_back(Msg, ItemState),
            NewItemState = tx_item_state:set_status(TmpItemState, uninitialized),
            msg_delay:send_local(config:read(tx_timeout) * 3 / 1000, self(),
                                 {tx_tm_rtm_delete_itemid, ItemId}),
            my_set_entry(NewItemState, State);
        false -> %% ok
            TxId = tx_item_state:get_txid(ItemState),
            {ok, OldTxState} = my_get_tx_entry(TxId, State),
            TxState = tx_state:inc_numpaxdecided(OldTxState),
            TmpItemState =
                case Value of
                    prepared -> tx_item_state:inc_numprepared(ItemState);
                    abort ->    tx_item_state:inc_numabort(ItemState)
                end,
            {NewItemState, NewTxState} =
                case tx_item_state:newly_decided(TmpItemState) of
                    false -> {TmpItemState, TxState};
                    Decision -> %% prepared / abort
                        DecidedItemState =
                            tx_item_state:set_decided(TmpItemState, Decision),
                        %% record in tx_state
                        TmpTxState = case Decision of
                                         prepared -> tx_state:inc_numprepared(TxState);
                                         abort -> tx_state:inc_numabort(TxState)
                                     end,
                        Tmp2TxState =
                            case tx_state:newly_decided(TmpTxState) of
                                undecided -> TmpTxState;
                                false -> TmpTxState;
                                Result -> %% commit or abort
                                    T1TxState = my_inform_tps(TmpTxState, State, Result),
                                    %% to inform, we do not need to know the new state
                                    my_inform_client(TxId, State, Result),
                                    my_inform_rtms(TxId, State, Result),
                                    %%%my_trigger_delete_if_done(T1TxState),
                                    tx_state:set_decided(T1TxState, Result)
                            end,
                        {DecidedItemState, Tmp2TxState}
                end,
            my_set_entry(NewTxState, State),
            my_trigger_delete_if_done(NewTxState),
            my_set_entry(NewItemState, State)
    end,
    State;

on({tx_tm_rtm_commit, Client, ClientsID, TransLog},
   {RTMs, _TableName, _Role, _LAcceptor, LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on({commit, ...}) for TLog ~p~n", [TransLog]),
    NewTid = {tx_id, util:get_global_uid()},
    NewTxItemIds = [ {tx_item_id, util:get_global_uid()} || _ <- TransLog ],
    TLogTxItemIds = lists:zip(TransLog, NewTxItemIds),
    Learner = comm:this(), %% be a proxy for the local learner
    TmpTxState = tx_state:new(NewTid, Client, ClientsID, RTMs,
                              TLogTxItemIds, [Learner]),
    TxState = tx_state:set_status(TmpTxState, ok),
    my_set_entry(TxState, State),

    ItemStates = [ begin
                       TItemState = tx_item_state:new(ItemId, NewTid, TLogEntry),
                       ItemState = tx_item_state:set_status(TItemState, ok),
                       my_set_entry(ItemState, State),
                       ItemState
                   end || {TLogEntry, ItemId} <- TLogTxItemIds ],

    %% initialize local learner
    GLLearner = comm:make_global(LLearner),
    Maj = config:read(quorum_factor),
    MySelf = comm:this(),
    [ begin
          ItemId = tx_item_state:get_itemid(ItemState),
          [ learner:start_paxosid(GLLearner, PaxId, Maj, MySelf, ItemId)
            || {PaxId, _RTLog, _TP}
                   <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
      end || ItemState <- ItemStates ],
    my_start_fds_for_tid(NewTid, TxState),
    my_init_RTMs(TxState, ItemStates),
    my_init_TPs(TxState, ItemStates),
    State;

%% this tx is finished and enough TPs were informed, delete the state
on({tx_tm_rtm_delete, TxId, Decision} = Msg,
   {_RTMs, TableName, Role, LAcceptor, LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on({delete, ...}) ~n", []),
    %% TODO: use ok as error code?!
    %% {ok, TxState} = my_get_tx_entry(TxId, State),
    {ErrCode, TxState} = my_get_tx_entry(TxId, State),
    %% inform RTMs on delete
    case {ErrCode, Role} of
        {ok, tx_tm} ->
            RTMS = tx_state:get_rtms(TxState),
            [ comm:send(RTM, Msg) || {_Key, RTM, _Nth} <- RTMS ],
            %% inform used learner to delete paxosids.
            AllPaxIds =
                [ begin
                      {ok, ItemState} = my_get_item_entry(ItemId, State),
                      [ PaxId || {PaxId, _RTLog, _TP}
                        <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
                  end || {_TLogEntry, ItemId} <- tx_state:get_tlog_txitemids(TxState) ],
            %% We could delete immediately, but we still miss the
            %% minority of learner_decides, which would re-create the
            %% id in the learner, which then would have to be deleted
            %% separately, so we give the minority a second to arrive
            %% and then send the delete request.
            %% learner:stop_paxosids(LLearner, lists:flatten(AllPaxIds)),
            msg_delay:send_local(1, LLearner,
                                 {learner_deleteids, lists:flatten(AllPaxIds)}),
            DeleteIt = true;
        {ok, _} ->
            %% the test my_trigger_delete was passed, at least by the TM
            %% RTMs only wait for all tp register messages, to not miss them
            %% record, that every TP was informed and all paxids decided
            TmpTxState = tx_state:set_numinformed(
                           TxState, tx_state:get_numids(TxState) *
                               config:read(replication_factor)),
            Tmp2TxState = tx_state:set_numpaxdecided(
                           TmpTxState, tx_state:get_numids(TxState) *
                                config:read(replication_factor)),
            Tmp3TxState = tx_state:set_decided(Tmp2TxState, Decision),
            my_set_entry(Tmp3TxState, State),
            DeleteIt = tx_state:all_tps_registered(TxState),
            %% inform used acceptors to delete paxosids.
            AllPaxIds =
                [ begin
                  {ok, ItemState} = my_get_item_entry(ItemId, State),
                  [ {PaxId, Role} || {PaxId, _RTlog, _TP}
                    <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
              end || {_TLogEntry, ItemId} <- tx_state:get_tlog_txitemids(TxState) ],
%%            msg_delay:send_local(config:read(tx_timeout) * 2 / 1000, LAcceptor,
%%                                 {acceptor_deleteids, lists:flatten(AllPaxIds)});
            comm:send_local(LAcceptor,
                               {acceptor_deleteids, lists:flatten(AllPaxIds)});
         {new, _} ->
            %% already deleted
            DeleteIt = false;
        {uninitialized, _} ->
            DeleteIt = false %% will be deleted when msg_delay triggers it
    end,
    case DeleteIt of
        false ->
            %% @TODO if we are a rtm, we still wait for register TPs
            %% trigger same delete later on, as we do not get a new
            %% request to delete from the tm
            ok;
        true ->
            %% unsubscribe RTMs from FD
            my_stop_fds_for_tid(TxId, TxState),
            %% delete locally
            [ pdb:delete(ItemId, TableName)
              || {_, ItemId} <- tx_state:get_tlog_txitemids(TxState)],
            pdb:delete(TxId, TableName)
            %% @TODO failure cases are not handled yet. If some
            %% participants do not respond, the state is not deleted.
            %% In the future, we will handle this using msg_delay for
            %% outstanding txids to trigger a delete of the items.
    end,
    State;

%% generated by on(register_TP) via msg_delay to not increase memory
%% footprint
on({tx_tm_rtm_delete_txid, TxId},
   {_RTMs, TableName, _Role, _LAcceptor, _LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on({delete_txid, ...}) ~n", []),
    %% Debug diagnostics and output:
    %%     {Status, Entry} = my_get_tx_entry(TxId, State),
    %%     case Status of
    %%         new -> ok; %% already deleted
    %%         uninitialized ->
    %%             %% @TODO inform delayed tps that they missed something?
    %%             %% See info in hold back queue.
    %%             io:format("Deleting an txid with hold back messages.~n~p~n",
    %%                       [tx_state:get_hold_back(Entry)]);
    %%         ok ->
    %%             io:format("Oops, this should have been cleaned normally.~n")
    %%     end,
    pdb:delete(TxId, TableName),
    State;

%% generated by on(learner_decide) via msg_delay to not increase memory
%% footprint
on({tx_tm_rtm_delete_itemid, TxItemId},
   {_RTMs, TableName, _Role, _LAcceptor, _LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on({delete_itemid, ...}) ~n", []),
    %% Debug diagnostics and output:
    %% {Status, Entry} = my_get_item_entry(TxItemId, State),
    %% case Status of
    %%     new -> ok; %% already deleted
    %%     uninitialized ->
    %% %%             %% @TODO inform delayed learners that they missed something?
    %%             %% See info in hold back queue.
    %%         io:format("Deleting an item with hold back massages.~n~p~n",
    %%                   [tx_item_state:get_hold_back(Entry)]);
    %%     ok ->
    %%         io:format("Oops, this should have been cleaned normally.~n")
    %% end,
    pdb:delete(TxItemId, TableName),
    State;

%% send by my_init_RTMs
on({tx_tm_rtm_init_RTM, TxState, ItemStates, _InRole} = _Msg,
   {_RTMs, _TableName, Role, LAcceptor, _LLearner} = State) ->
   ?TRACE("tx_tm_rtm:on({init_RTM, ...}) ~n", []),

    %% lookup transaction id locally and merge with given TxState
    Tid = tx_state:get_tid(TxState),
    {LocalTxStatus, LocalTxEntry} = my_get_tx_entry(Tid, State),
    TmpEntry = case LocalTxStatus of
                   new -> TxState; %% nothing known locally
                   uninitialized ->
                       %% take over hold back from existing entry
                       %%io:format("initRTM takes over hold back queue for id ~p in ~p~n", [Tid, Role]),
                       HoldBackQ = tx_state:get_hold_back(LocalTxEntry),
                       tx_state:set_hold_back(TxState, HoldBackQ);
                   ok -> io:format(standard_error, "Duplicate init_RTM~n", [])
               end,
    NewEntry = tx_state:set_status(TmpEntry, ok),
    my_set_entry(NewEntry, State),

    %% lookup items locally and merge with given ItemStates
    NewItemStates =
        [ begin
              EntryId = tx_item_state:get_itemid(Entry),
              {LocalItemStatus, LocalItem} = my_get_item_entry(EntryId, State),
              TmpItem = case LocalItemStatus of
                            new -> Entry; %% nothing known locally
                            uninitialized ->
                                %% take over hold back from existing entry
                                IHoldBQ = tx_item_state:get_hold_back(LocalItem),
                                tx_item_state:set_hold_back(Entry, IHoldBQ);
                            ok -> io:format(standard_error, "Duplicate init_RTM for an item~n", [])
                        end,
              NewItem = tx_item_state:set_status(TmpItem, ok),
              my_set_entry(NewItem, State),
              NewItem
          end || Entry <- ItemStates],
%%    io:format("New Item States: ~p~n", [NewItemStates]),

    %% initiate local paxos acceptors (with received paxos_ids)
    Learners = tx_state:get_learners(TxState),
    [ [ acceptor:start_paxosid_local(LAcceptor, {PaxId, Role}, Learners)
        || {PaxId, _RTlog, _TP}
               <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
      || ItemState <- NewItemStates ],

    %% process hold back messages for tx_state
    %% @TODO better use a foldl
    %% io:format("Starting hold back queue processing~n"),
    [ on(OldMsg, State) || OldMsg <- lists:reverse(tx_state:get_hold_back(NewEntry)) ],
    %% process hold back messages for tx_items
    [ [ on(OldMsg, State)
        || OldMsg <- lists:reverse(tx_item_state:get_hold_back(Item)) ]
      || Item <- NewItemStates],
    %% io:format("Stopping hold back queue processing~n"),

    %% @TODO set timeout and remember timerid to cancel, if finished earlier?
    %% @TODO after timeout take over and initiate new paxos round as proposer

    State;

on({register_TP, {Tid, ItemId, PaxosID, TP}} = Msg,
   {_RTMs, _TableName, Role, _LAcceptor, _LLearner} = State) ->
    %% TODO merge register_TP and accept messages to a single message
    ?TRACE("tx_tm_rtm:on(~p)~n", [_Msg]),
    {ErrCodeTx, TmpTxState} = my_get_tx_entry(Tid, State),
    case ok =/= ErrCodeTx of
        true -> %% new / uninitialized
            %% hold back and handle when corresponding tx_state is
            %% created in init_RTM
            %% io:format("Holding back a registerTP for id ~p in ~p~n", [Tid, Role]),
            T2TxState = tx_state:hold_back(Msg, TmpTxState),
            NewTxState = tx_state:set_status(T2TxState, uninitialized),
            msg_delay:send_local(config:read(tx_timeout) * 3 / 1000, self(),
                                 {tx_tm_rtm_delete_txid, Tid}),
            my_set_entry(NewTxState, State);
        false -> %% ok
            TxState = tx_state:inc_numtpsregistered(TmpTxState),
            my_set_entry(TxState, State),
            {ok, ItemState} = my_get_item_entry(ItemId, State),

            case {tx_state:is_decided(TxState), Role} of
                {undecided, _} ->
                    %% store TP info to corresponding PaxosId
                    NewEntry =
                        tx_item_state:set_tp_for_paxosid(ItemState, TP, PaxosID),
                    my_trigger_delete_if_done(TxState),
                    my_set_entry(NewEntry, State);
                {Decision, tx_tm} ->
                    %% if register_TP arrives after tx decision, inform the
                    %% slowly client directly
                    %% find matching RTLogEntry and send commit_reply
                    {PaxosID, RTLogEntry, _TP} =
                        lists:keyfind(PaxosID, 1,
                          tx_item_state:get_paxosids_rtlogs_tps(ItemState)),
                    msg_commit_reply(TP, {PaxosID, RTLogEntry}, Decision),
                    %% @TODO record in txstate and try to delete entry?
                    NewTxState = tx_state:inc_numinformed(TxState),
                    my_trigger_delete_if_done(NewTxState),
                    my_set_entry(NewTxState, State);
                _ ->
                    %% RTMs check whether everything is done
                    my_trigger_delete_if_done(TxState)
            end
    end,
    State;

%% failure detector events
on({crash, Pid},
   {RTMs, _TableName, _Role, _LAcceptor, _LLearner} = State) ->
    ?TRACE_RTM_MGMT("tx_tm_rtm:on({crash,...}) of Pid ~p~n", [Pid]),
    [ lookup:unreliable_lookup(
        Key, {get_process_in_group, comm:this(), Key, ?MODULE})
      || {Key, RTM} <- RTMs, RTM =:= Pid ],
    State;

on({crash, _Pid, _Cookie},
   {_RTMs, _TableName, _Role, _LAcceptor, _LLearner} = State) ->
    ?TRACE("tx_tm_rtm:on:crash of ~p in Transaction ~p~n", [_Pid, binary_to_term(_Cookie)]),
    %% @todo should we take over, if the TM failed?
    State;

%% periodic RTM update
on({update_RTMs},
   {RTMs, _TableName, _Role, _LAcceptor, _LLearner} = State) ->
    ?TRACE_RTM_MGMT("tx_tm_rtm:on:update_RTMs in Pid ~p ~n", [self()]),
    my_RTM_update(RTMs),
    State;

%% accept RTM updates
on({get_rtm_reply, InKey, InPid},
   {RTMs, TableName, Role, LAcceptor, LLearner} = _State) ->
    ?TRACE_RTM_MGMT("tx_tm_rtm:on:get_rtm_reply in Pid ~p for Pid ~p and State ~p~n", [self(), InPid, _State]),
    NewRTMs = my_update_rtm_entry(RTMs, InKey, InPid),
    {NewRTMs, TableName, Role, LAcceptor, LLearner};

on(_, _State) ->
    unknown_event.

%% While initializing
on_init({idholder_get_id_response, IdSelf, _IdSelfVersion},
   {_RTMs, TableName, Role, LAcceptor, LLearner} = _State) ->
    ?TRACE("tx_tm_rtm:on_init:idholder_get_id_response State; ~p~n", [_State]),
    RTM_ids = my_get_RTM_ids(IdSelf),
    NewRTMs = lists:zip3(RTM_ids,
                         [ unknown || _X <- lists:seq(1, length(RTM_ids))],
                         lists:seq(0, length(RTM_ids) - 1)),
    my_RTM_update(NewRTMs),
    {NewRTMs, TableName, Role, LAcceptor, LLearner};

on_init({update_RTMs}, State) ->
    ?TRACE_RTM_MGMT("tx_tm_rtm:on_init:update_RTMs in Pid ~p ~n", [self()]),
    on({update_RTMs}, State);

on_init({get_rtm_reply, InKey, InPid},
        {RTMs, TableName, Role, LAcceptor, LLearner} = _State) ->
    ?TRACE_RTM_MGMT("tx_tm_rtm:on_init:get_rtm_reply in Pid ~p for Pid ~p State ~p~n", [self(), InPid, State]),
    NewRTMs = my_update_rtm_entry(RTMs, InKey, InPid),
    case lists:keyfind(unknown, 2, NewRTMs) of %% filled all entries?
        false ->
            gen_component:change_handler(
              {NewRTMs, TableName, Role, LAcceptor, LLearner}, on);
        _ -> {NewRTMs, TableName, Role, LAcceptor, LLearner}
    end;

on_init({tx_tm_rtm_commit, _Client, _ClientsID, _TransLog} = Msg,
   State) ->
    comm:send_local_after(1000, self(), Msg),
    State;

on_init(_, _State) ->
    unknown_event.

%% functions for periodic RTM updates

%% @doc provide ids for RTMs (sorted by increasing latency to them).
%% first entry is the locally hosted replica of IdSelf
my_get_RTM_ids(IdSelf) ->
    %% @todo sort Ids by latency or do the sorting after RTMs are determined
    ?RT:get_keys_for_replicas(IdSelf).

my_RTM_update(RTMs) ->
    [ begin
          Name = list_to_atom(lists:flatten(io_lib:format("tx_rtm~p", [Nth]))),
          lookup:unreliable_lookup(
            Key, {get_rtm, comm:this(), Key, Name})
      end
      || {Key, _Pid, Nth} <- RTMs],
    comm:send_local_after(config:read(tx_rtm_update_interval),
                             self(), {update_RTMs}),
    ok.

my_update_rtm_entry(RTMs, InKey, InPid) ->
    [ case InKey =:= Key of
          true -> case InPid =/= RTM of
                      true -> case RTM of
                                  unknown -> ok;
                                  _ -> fd:unsubscribe(RTM)
                              end,
                              fd:subscribe(InPid);
                      false -> ok
                  end,
                  {Key, InPid, Nth};
          false -> Entry
      end || {Key, RTM, Nth} = Entry <- RTMs ].

%% functions for tx processing
my_start_fds_for_tid(Tid, TxEntry) ->
    ?TRACE("tx_tm_rtm:my_start_fds_for_tid~n", []),
    RTMs = tx_state:get_rtms(TxEntry),
    RTMGPids = [ X || {_Key, X, _Nth} <- RTMs ],
    fd:subscribe(RTMGPids, Tid).

my_stop_fds_for_tid(Tid, TxEntry) ->
    ?TRACE("tx_tm_rtm:my_stop_fds_for_tid~n", []),
    RTMs = tx_state:get_rtms(TxEntry),
    RTMGPids = [ X || {_Key, X, _Nth} <- RTMs ],
    fd:unsubscribe(RTMGPids, Tid).

my_init_RTMs(TxState, ItemStates) ->
    ?TRACE("tx_tm_rtm:my_init_RTMs~n", []),
    RTMs = tx_state:get_rtms(TxState),
    [ comm:send(X, {tx_tm_rtm_init_RTM, TxState, ItemStates, Nth})
      || {_, X, Nth} <- RTMs ],
    ok.

my_init_TPs(TxState, ItemStates) ->
    ?TRACE("tx_tm_rtm:my_init_TPs~n", []),
    %% send to each TP its own record / request including the RTMs to
    %% be used
    Tid = tx_state:get_tid(TxState),
    RTMs = tx_state:get_rtms(TxState),
    CleanRTMs = [Address || {_Key, Address, _Nth} <- RTMs],
    TM = comm:this(),
    [ begin
          %% ItemState = lists:keyfind(ItemId, 1, ItemStates),
          ItemId = tx_item_state:get_itemid(ItemState),
          [ begin
                Key = element(2, RTLog),
                Msg1 = {init_TP, {Tid, CleanRTMs, TM, RTLog, ItemId, PaxId}},
                %% delivers message to a dht_node process, which has
                %% also the role of a TP
                lookup:unreliable_lookup(Key, Msg1)
            end
            || {PaxId, RTLog, _TP} <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
              %%      end || {_TLogEntry, ItemId} <- tx_state:get_tlog_txitemids(TxState) ],
      end || ItemState <- ItemStates ],
    ok.

my_get_tx_entry(Id,
                {_RTMS, TableName, _Role, _LAcceptor, _LLearner} = _State) ->
    case pdb:get(Id, TableName) of
        undefined -> {new, tx_state:new(Id)};
        Entry -> {tx_state:get_status(Entry), Entry}
    end.

my_get_item_entry(Id, {_RTMS, TableName, _Role, _LAcceptor, _LLearner} = _State) ->
    case pdb:get(Id, TableName) of
        undefined -> {new, tx_item_state:new(Id)};
        Entry -> {tx_item_state:get_status(Entry), Entry}
    end.

my_set_entry(NewEntry, {_RTMS, TableName, _Role, _LAcceptor, _LLearner} = State) ->
    pdb:set(NewEntry, TableName),
    State.

my_inform_client(TxId, State, Result) ->
    ?TRACE("tx_tm_rtm:inform client~n", []),
    {ok, TxState} = my_get_tx_entry(TxId, State),
    Client = tx_state:get_client(TxState),
    ClientsId = tx_state:get_clientsid(TxState),
    case Client of
        unknown -> ok;
        _ -> msg_commit_reply(Client, ClientsId, Result)
    end,
    ok.

my_inform_tps(TxState, State, Result) ->
    ?TRACE("tx_tm_rtm:inform tps~n", []),
    %% inform TPs
    X = [ begin
              {ok, ItemState} = my_get_item_entry(ItemId, State),
              [ case TP of
                    unknown -> unknown;
                    _ -> msg_commit_reply(TP, {PaxId, RTLogEntry}, Result), ok
                end
                || {PaxId, RTLogEntry, TP}
                       <- tx_item_state:get_paxosids_rtlogs_tps(ItemState) ]
          end || {_TLogEntry, ItemId} <- tx_state:get_tlog_txitemids(TxState) ],
    Y = [ Z || Z <- lists:flatten(X), Z =:= ok ],
    NewTxState = tx_state:set_numinformed(TxState, length(Y)),
%%    my_trigger_delete_if_done(NewTxState),
    NewTxState.

my_inform_rtms(_TxId, _State, _Result) ->
    ?TRACE("tx_tm_rtm:inform rtms~n", []),
    %%{ok, TxState} = my_get_tx_entry(_TxId, _State),
    %% @TODO inform RTMs?
    %% msg_commit_reply(Client, ClientsId, Result)
    ok.

my_trigger_delete_if_done(TxState) ->
    ?TRACE("tx_tm_rtm:trigger delete?~n", []),
    case (tx_state:is_decided(TxState)) of
        undecided -> ok;
        false -> ok;
        Decision -> %% commit / abort
            %% @TODO majority informed is sufficient?!
            case tx_state:all_tps_informed(TxState)
                %%        andalso tx_state:all_pax_decided(TxState)
                %%    andalso tx_state:all_tps_registered(TxState)
            of
                true ->
                    TxId = tx_state:get_tid(TxState),
                    comm:send_local(self(), {tx_tm_rtm_delete, TxId, Decision});
                false -> ok
            end
    end, ok.

%% @doc Checks whether config parameters for tx_tm_rtm exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:is_integer(quorum_factor) and
    config:is_greater_than(quorum_factor, 0) and
    config:is_integer(replication_factor) and
    config:is_greater_than(replication_factor, 0) and

    config:is_integer(tx_timeout) and
    config:is_greater_than(tx_timeout, 0) and
    config:is_integer(tx_rtm_update_interval) and
    config:is_greater_than(tx_rtm_update_interval, 0).

