%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_event_topic).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ enable/0
        , disable/0
        ]).

-export([ on_client_connected/2
        , on_client_disconnected/3
        , on_session_subscribed/3
        , on_session_unsubscribed/3
        , on_message_dropped/3
        , on_message_delivered/2
        , on_message_acked/2
        ]).

-ifdef(TEST).
-export([reason/1]).
-endif.

enable() ->
    emqx_hooks:put('client.connected', {?MODULE, on_client_connected, []}),
    emqx_hooks:put('client.disconnected', {?MODULE, on_client_disconnected, []}),
    emqx_hooks:put('session.subscribed', {?MODULE, on_session_subscribed, []}),
    emqx_hooks:put('session.unsubscribed', {?MODULE, on_session_unsubscribed, []}),
    emqx_hooks:put('message.delivered', {?MODULE, on_message_delivered, []}),
    emqx_hooks:put('message.acked', {?MODULE, on_message_acked, []}),
    emqx_hooks:put('message.dropped', {?MODULE, on_message_dropped, []}).

disable() ->
    emqx_hooks:del('client.connected', {?MODULE, on_client_connected}),
    emqx_hooks:del('client.disconnected', {?MODULE, on_client_disconnected}),
    emqx_hooks:del('session.subscribed', {?MODULE, on_session_subscribed}),
    emqx_hooks:del('session.unsubscribed', {?MODULE, session_unsubscribed}),
    emqx_hooks:del('message.delivered', {?MODULE, on_message_delivered}),
    emqx_hooks:del('message.acked', {?MODULE, on_message_acked}),
    emqx_hooks:del('message.dropped', {?MODULE, on_message_dropped}).

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------

on_client_connected(ClientInfo, ConnInfo) ->
    Payload0 = connected_payload(ClientInfo, ConnInfo),
    emqx_broker:safe_publish(
              make_msg(<<"$event/client_connected">>,
                       emqx_json:encode(Payload0))).

on_client_disconnected(_ClientInfo = #{clientid := ClientId, username := Username},
                       Reason, _ConnInfo = #{disconnected_at := DisconnectedAt}) ->
    Payload0 = #{clientid => ClientId,
                 username => Username,
                 reason => reason(Reason),
                 disconnected_at => DisconnectedAt,
                 ts => erlang:system_time(millisecond)
                },
    emqx_broker:safe_publish(
              make_msg(<<"$event/client_connected">>,
                       emqx_json:encode(Payload0))).

on_session_subscribed(_ClientInfo = #{clientid := ClientId,
                                      username := Username},
                      Topic, SubOpts) ->
    Payload0 = #{clientid => ClientId,
                 username => Username,
                 topic => Topic,
                 subopts => SubOpts,
                 ts => erlang:system_time(millisecond)
                },
    emqx_broker:safe_publish(
              make_msg(<<"$event/session_subscribed">>,
                       emqx_json:encode(Payload0))).

on_session_unsubscribed(_ClientInfo = #{clientid := ClientId,
                                        username := Username},
                      Topic, _SubOpts) ->
    Payload0 = #{clientid => ClientId,
                 username => Username,
                 topic => Topic,
                 ts => erlang:system_time(millisecond)
                },
    emqx_broker:safe_publish(
              make_msg(<<"$event/session_unsubscribed">>,
                       emqx_json:encode(Payload0))).

on_message_dropped(Message = #message{from = ClientId}, _, Reason) ->
    case ignore_sys_message(Message) of
        true -> ok;
        false ->
            Payload0 = base_message(Message),
            Payload1 = Payload0#{
                reason => Reason,
                clientid => ClientId,
                username => emqx_message:get_header(username, Message, undefined),
                peerhost => ntoa(emqx_message:get_header(peerhost, Message, undefined))
            },
            emqx_broker:safe_publish(
                make_msg(<<"$event/message_dropped">>, emqx_json:encode(Payload1)))
    end,
    {ok, Message}.

on_message_delivered(_ClientInfo = #{
                         peerhost := PeerHost,
                         clientid := ReceiverCId,
                         username := ReceiverUsername},
                     #message{from = ClientId} = Message) ->
    case ignore_sys_message(Message) of
        true -> ok;
        false ->
            Payload0 = base_message(Message),
            Payload1 = Payload0#{
                from_clientid => ClientId,
                from_username => emqx_message:get_header(username, Message, undefined),
                clientid => ReceiverCId,
                username => ReceiverUsername,
                peerhost => ntoa(PeerHost)
            },
            emqx_broker:safe_publish(
                make_msg(<<"$event/message_delivered">>, emqx_json:encode(Payload1)))
    end,
    {ok, Message}.

on_message_acked(_ClientInfo = #{
                    peerhost := PeerHost,
                    clientid := ReceiverCId,
                    username := ReceiverUsername},
                 #message{from = ClientId} = Message) ->
    case ignore_sys_message(Message) of
        true -> ok;
        false ->
            Payload0 = base_message(Message),
            Payload1 = Payload0#{
                from_clientid => ClientId,
                from_username => emqx_message:get_header(username, Message, undefined),
                clientid => ReceiverCId,
                username => ReceiverUsername,
                peerhost => ntoa(PeerHost)
            },
            emqx_broker:safe_publish(
                make_msg(<<"$event/message_acked">>, emqx_json:encode(Payload1)))
    end,
    {ok, Message}.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

connected_payload(#{peerhost := PeerHost,
                    sockport := SockPort,
                    clientid := ClientId,
                    username := Username
                   },
                  #{clean_start := CleanStart,
                    proto_name := ProtoName,
                    proto_ver := ProtoVer,
                    keepalive := Keepalive,
                    connected_at := ConnectedAt,
                    expiry_interval := ExpiryInterval
                   }) ->
    #{clientid => ClientId,
      username => Username,
      ipaddress => ntoa(PeerHost),
      sockport => SockPort,
      proto_name => ProtoName,
      proto_ver => ProtoVer,
      keepalive => Keepalive,
      connack => 0, %% Deprecated?
      clean_start => CleanStart,
      expiry_interval => ExpiryInterval div 1000,
      connected_at => ConnectedAt,
      ts => erlang:system_time(millisecond)
     }.

make_msg(Topic, Payload) ->
    emqx_message:set_flag(
      sys, emqx_message:make(
             ?MODULE, 0, Topic, iolist_to_binary(Payload))).

-compile({inline, [reason/1]}).
reason(Reason) when is_atom(Reason) -> Reason;
reason({shutdown, Reason}) when is_atom(Reason) -> Reason;
reason({Error, _}) when is_atom(Error) -> Error;
reason(_) -> internal_error.

ntoa(undefined) -> undefined;
ntoa({IpAddr, Port}) ->
    iolist_to_binary([inet:ntoa(IpAddr), ":", integer_to_list(Port)]);
ntoa(IpAddr) ->
    iolist_to_binary(inet:ntoa(IpAddr)).

printable_maps(undefined) -> #{};
printable_maps(Headers) ->
    maps:fold(
        fun (K, V0, AccIn) when K =:= peerhost; K =:= peername; K =:= sockname ->
                AccIn#{K => ntoa(V0)};
            ('User-Property', V0, AccIn) when is_list(V0) ->
                AccIn#{
                    'User-Property' => maps:from_list(V0),
                    'User-Property-Pairs' => [#{
                        key => Key,
                        value => Value
                     } || {Key, Value} <- V0]
                };
            (K, V0, AccIn) -> AccIn#{K => V0}
        end, #{}, Headers).

base_message(Message) ->
    #message{
        id = Id,
        qos = QoS,
        flags = Flags,
        topic = Topic,
        headers = Headers,
        payload = Payload,
        timestamp = Timestamp} = Message,
    #{
        id => emqx_guid:to_hexstr(Id),
        payload => Payload,
        topic => Topic,
        qos => QoS,
        flags => Flags,
        headers => printable_maps(Headers),
        pub_props => printable_maps(emqx_message:get_header(properties, Message, #{})),
        publish_received_at => Timestamp
    }.

ignore_sys_message(#message{flags = Flags}) ->
    maps:get(sys, Flags, false).