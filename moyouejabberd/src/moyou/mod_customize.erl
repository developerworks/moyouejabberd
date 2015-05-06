%%%----------------------------------------------------------------------
%%% File    : mod_customize.erl
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_customize).
-author('chenkangmin').

-behavior(gen_mod).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(ACK_USER, "messageack").

%% gen_mod callbacks
-export([start/2, stop/1]).

%% Hook callbacks
-export([
    user_send_packet/3
]).

-export([
    query_local_group_member/1
]).

%% 组成员记录, 包含gid: 组ID, memebers: 组当中的成员两个元素.
-record(moyou_group_member, {gid, members = []}).

start(Host, _Opts) ->
    catch ets:new(ets_ack_task, [named_table, public, set]),
    moyou_util:create_or_copy_table(moyou_group_member_tab, [
        {record_name, moyou_group_member},
        {attributes, record_info(fields, moyou_group_member)},
        {ram_copies, [node()]}
    ], ram_copies),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 80).

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 80).

user_send_packet(From, To, {xmlelement, "message", Attrs, SubElements} = Packet) ->
    MessageType = xml:get_attr_s("msgtype", Attrs),
    Cid = xml:get_attr_s("id", Attrs),
    Time = moyou_util:now_str(),
    if
        MessageType =/= "msgStatus" ->
            ?INFO_MSG("user_send_packet From : ~p~n, To : ~p~n, Packet : ~p~n", [From, To, Packet]),
            Attrs1 = [{"msgTime", Time} | [{K, V} || {K, V} <- Attrs, K =/= "msgTime"]],
            Attrs2 =
                case MessageType of
                    "groupchat" ->
                        [{"g", "0"}, {"groupid", To#jid.user} | [{K, V} || {K, V} <- Attrs1, K =/= "groupid"]];
                    _ ->
                        Attrs1
                end,
            Packet1 = {xmlelement, "message", Attrs2, SubElements},
            SessionID = moyou_util:get_session_id(MessageType, From, To),
            case check_user_in_group(MessageType, From, To) of
                false ->
                    skip;
                {true, UserList} ->
                    case is_temp_message(MessageType) of
                        true ->
                            spawn(fun() -> route_message(moyou_util:get_id(), From, UserList, Packet1) end);
                        _ ->
                            case moyou_rpc_util:store_message(SessionID, From, Packet1) of
                                {repeat, Sid} ->
                                    spawn(fun() -> ack(From, MessageType, Cid, Time, Sid) end);
                                {Sid, Seq} ->
                                    spawn(fun() -> ack(From, MessageType, Cid, Time, Sid) end),
                                    moyou_rpc_util:update_session_all_seq(UserList, SessionID, Seq),
                                    Attrs3 = [{"id", Sid} | [{K, V} || {K, V} <- Attrs2, K =/= "id"]],
                                    Packet2 = {xmlelement, "message", Attrs3, SubElements},
                                    spawn(fun() -> route_message(Sid, From, UserList, Packet2) end)
                            end
                    end
            end;
        MessageType =:= "msgStatus" andalso To#jid.user =/= ?ACK_USER andalso From#jid.server =/= "push.gampro.com" ->
            cancel_loop(Cid, From),
            case re:split(Cid, "_", [{return, list}]) of
                [Prefix, SessionKey, Seq] ->
                    SessionID = lists:concat([Prefix, "_", SessionKey]),
                    moyou_rpc_util:update_session_read_seq(From#jid.user, SessionID, list_to_integer(Seq));
                _ ->
                    skip
            end;
        true ->
            skip
    end;
user_send_packet(_From, _To, _Packet) ->
    skip.

check_user_in_group(Mt, From, To) when Mt =:= "groupchat" ->
    Gid = To#jid.user,
    Members = get_group_members(Gid),
    case lists:member(From#jid.user, Members) of
        false ->
            false;
        _ ->
            {true, lists:delete(From#jid.user, Members)}
    end;
check_user_in_group(_Mt, _From, To) ->
    {true, [To#jid.user]}.

ack(#jid{server = Server} = From, MessageType, Cid, Time, Sid) ->
    if
        MessageType =:= "normalchat" orelse MessageType =:= "groupchat" ->
            Attr = ack_attr(From, Server, Time, Sid),
            Els = [{xmlelement, "body", [], [{xmlcdata, list_to_binary("{'src_id':'" ++ Cid ++ "','received':'true'}")}]}],
            Packet = {xmlelement, "message", Attr, Els},
            AckJid = #jid{user = ?ACK_USER, server = Server, resource = "", luser = ?ACK_USER, lserver = Server, lresource = ""},
            case catch ejabberd_router:route(AckJid, From, Packet) of
                ok ->
                    ?INFO_MSG("server_ack successed, Cid : ~p, Sid : ~p, From : ~p~n", [Cid, Sid, From]);
                ERROR ->
                    ?ERROR_MSG("server_ack failed, Cid : ~p, Sid : ~p, From : ~p, Error : ~p~n", [Cid, Sid, From, ERROR])
            end;
        true ->
            skip
    end.

ack_attr(From, Server, Time, Sid) ->
    [
        {"id", moyou_util:get_id()},
        {"to", jlib:jid_to_string(From)},
        {"from", lists:concat([?ACK_USER, "@", Server])},
        {"type", "normal"},
        {"msgtype", ""},
        {"msgTime", Time},
        {"action", "ack"},
        {"server_id", Sid}
    ].


route_message(_ID, _From, [], _Packet) ->
    skip;
route_message(ID, #jid{server = Server} = From, [Uid | Rest], Packet) ->
    To = #jid{user = Uid, server = Server, luser = Uid, lserver = Server, resource = [], lresource = []},
    LoopPid = spawn(fun() -> loop(ID, From, To, Packet) end),
    ets:insert(ets_ack_task, {{To, ID}, LoopPid}),
    case ejabberd_router:route(From, To, Packet) of
        ok ->
            skip;
        Err ->
            ?ERROR_MSG("route_message failed, ID: ~p~n From : ~p~n, To : ~p~n, Packet : ~p~n, err : ~p~n", [ID, From, To, Packet, Err])
    end,
    route_message(ID, #jid{server = Server} = From, Rest, Packet).


loop(ID, From, To, Packet) ->
    receive
        ack ->
            ets:delete(ets_ack_task, {To, ID})
    after 5000 ->
        ets:delete(ets_ack_task, {To, ID}),
        moyou_rpc_util:send_offline_message(From, To, Packet)
    end.


cancel_loop(ID, To) ->
    case ets:lookup(ets_ack_task, {moyou_util:format_jid(To), ID}) of
        [{_, LoopPid}] ->
            LoopPid ! ack;
        _ ->
            skip
    end.

%% 通过群组ID获取群组的成员列表
%% 首先从ETS表中读取成员列表
%% - 如果为空, 再从远程URL获取群组列表, 如果还为[]直接返回空列表[], 否则把从远程获取的成员列表写入到本地ETS群组成员表中(moyou_group_member_tab)
%% - 如果不空, 直接返回Members列表
get_group_members(Gid) ->
    case mnesia:dirty_read(moyou_group_member_tab, Gid) of
        [] ->
            case query_remote_group_member(Gid) of
                [] ->
                    [];
                Members ->
                    R = #moyou_group_member{gid = Gid, members = Members},
                    mnesia:dirty_write(moyou_group_member_tab, R),
                    Members
            end;
        [#moyou_group_member{members = Members}] ->
            Members
    end.

%% 从本地ETS表中获取一个群组的成员列表
%% - 如果为空, 返回空列表
%% - 如果不空, 返回成员列表
query_local_group_member(Gid) ->
    case mnesia:dirty_read(moyou_group_member_tab, Gid) of
        [] ->
            [];
        [#moyou_group_member{members = Members}] ->
            Members
    end.


%% 从一个HTTP接口获取群组成员列表, 如果有成员返回一个非空列表, 否则返回[](空列表)
query_remote_group_member(Gid) ->
    %% 从/etc/ejabberd/ejabberd.yml配置文件中获取服务器的URL地址
    Url = moyou_util:get_config(gamepro_server),
    %% 构造参数
    ParamObj = {obj, [
        {"sn", list_to_binary(moyou_util:get_id())},
        {"service", list_to_binary("service.groupchat")},
        {"method", list_to_binary("getUserList")},
        {"params", {obj, [{"groupId", list_to_binary(Gid)}]}}
    ]},
    %% 把参数编码为JSON
    Params = "body=" ++ rfc4627:encode(ParamObj),
    %% 提交请求
    case moyou_util:http_request(Url, Params) of
        [] ->
            [];
        Body ->
            case rfc4627:decode(Body) of %% 解析JSON响应
                {ok, Obj, _Re} ->
                    case rfc4627:get_field(Obj, "success") of
                        {ok, true} ->
                            {ok, Entity} = rfc4627:get_field(Obj, "entity"),
                            [binary_to_list(B) || B <- Entity];
                        _ ->
                            []
                    end;
                _ ->
                    []
            end
    end.

%% 判断是否为临时消息(事件类消息)
is_temp_message("eventMsg") ->
    true;
is_temp_message(_Mt) ->
    false.