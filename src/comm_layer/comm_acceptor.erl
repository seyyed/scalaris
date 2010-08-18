% @copyright 2008-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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
%% @doc Acceptor.
%%
%%      This module accepts new connections and starts corresponding 
%%      comm_connection processes.
%% @version $Id$
-module(comm_acceptor).
-author('schuett@zib.de').
-vsn('$Id$').

-export([start_link/1, init/1]).

-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(_GroupName) ->
    Pid = spawn_link(comm_acceptor, init, [self()]),
    receive
        {started} ->
            {ok, Pid}
    end.

-spec init(pid()) -> any().
init(Supervisor) ->
    erlang:register(comm_layer_acceptor, self()),
    log:log(info,"[ CC ] listening on ~p:~p", [config:read(listen_ip), preconfig:cs_port()]),
    LS = case config:read(listen_ip) of
             undefined ->
                 open_listen_port(preconfig:cs_port(), first_ip());
             _ ->
                 open_listen_port(preconfig:cs_port(), config:read(listen_ip))
         end,
    {ok, {_LocalAddress, LocalPort}} = inet:sockname(LS),
    comm_server:set_local_address(undefined, LocalPort),
    %io:format("this() == ~w~n", [{LocalAddress, LocalPort}]),
    Supervisor ! {started},
    server(LS).

server(LS) ->
    case gen_tcp:accept(LS) of
        {ok, S} ->
            case comm_server:get_local_address_port() of
                {undefined, LocalPort} ->
                    {ok, {MyIP, _LocalPort}} = inet:sockname(S),
                    comm_server:set_local_address(MyIP, LocalPort);
                _ ->
                    ok
            end,
            receive
                {tcp, S, Msg} ->
                    {endpoint, Address, Port} = binary_to_term(Msg),
                    % auto determine remote address, when not sent correctly
                    NewAddress = if Address =:= {0,0,0,0} orelse Address =:= {127,0,0,1} ->
                                        case inet:peername(S) of
                                            {ok, {PeerAddress, _Port}} ->
                                                % io:format("Sent Address ~p\n",[Address]),
                                                % io:format("Peername is ~p\n",[PeerAddress]),
                                                PeerAddress;
                                            {error, _Why} ->
                                                % io:format("Peername error ~p\n",[Why]).
                                                Address
                                        end;
                                    true ->
                                        % io:format("Address is ~p\n",[Address]),
                                        Address
                                 end,
                    NewPid = comm_connection:new(NewAddress, Port, S),
                    gen_tcp:controlling_process(S, NewPid),
                    inet:setopts(S, comm_connection:tcp_options()),
                    comm_server:register_connection(NewAddress, Port, NewPid, S)
            end,
            server(LS);
        Other ->
            log:log(warn,"[ CC ] unknown message ~p", [Other])
    end.

open_listen_port({From, To}, IP) ->
    open_listen_port(lists:seq(From, To), IP);
open_listen_port([Port | Rest], IP) ->
    case gen_tcp:listen(Port, [binary, {packet, 4}, {ip, IP}]
                        ++ comm_connection:tcp_options()) of
        {ok, Socket} ->
            log:log(info,"[ CC ] listening on ~p:~p~n", [IP, Port]),
            Socket;
        {error, Reason} ->
            log:log(error,"[ CC ] can't listen on ~p: ~p~n", [Port, Reason]),
            open_listen_port(Rest, IP)
    end;
open_listen_port([], _) ->
    abort;
open_listen_port(Port, IP) ->
    open_listen_port([Port], IP).

-include_lib("kernel/include/inet.hrl").

first_ip() ->
    {ok, Hostname} = inet:gethostname(),
    {ok, HostEntry} = inet:gethostbyname(Hostname),
    erlang:hd(HostEntry#hostent.h_addr_list).

