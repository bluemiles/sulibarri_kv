-module(sulibarri_dht_node).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
		put/3,
		get/2,
		delete/2,
		new_cluster/0,
		join_cluster/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(ETS, vnode_map).
-define(DEFAULT_PARTITIONS, 64).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% Do Active Checks here

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

put(Key, Value, Origin) ->
	gen_server:cast(?SERVER, {put, Key, Value, Origin}).

get(Key, Origin) ->
	gen_server:cast(?SERVER, {get, Key, Origin}).
	
delete(Key, Origin) ->
	gen_server:cast(?SERVER, {delete, Key, Origin}).

new_cluster() ->
	gen_server:cast(?SERVER, new_cluster).

join_cluster(Node) ->
	gen_server:cast(?SERVER, {join_cluster, Node}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
	ets:new(?ETS, [named_table, protected]),
	lists:foreach(
		fun(P_Id) ->
			{ok, Pid} = sulibarri_dht_storage:create(P_Id),
			ets:insert(?ETS, {P_Id, Pid})
		end,
		lists:seq(1, ?DEFAULT_PARTITIONS)
	),
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(new_cluster, State) ->
	sulibarri_dht_ring_manager:new_cluster(),
	{noreply, State};

handle_cast({join_cluster, Node}, State) ->
	sulibarri_dht_ring_manager:join_cluster(Node),
	{noreply, State};

handle_cast({init_transfers, Transfers}, State) ->
	lists:foreach(
		fun({P_Id, _, Destination}) ->
			case ets:lookup(?ETS, P_Id) of
				[{_, Pid}] ->
					sulibarri_dht_storage:init_transfer(Pid, {Destination});
				[] -> nop
			end
		end,
		Transfers
	),
	{noreply, State};

handle_cast({revieve_transfer, P_Id, Data, Sender}, State) ->
	[{_, Pid}] = ets:lookup(?ETS, P_Id),
	sulibarri_dht_storage:receive_transfer(Pid, Data, Sender),
	{noreply, State};

handle_cast({put, Key, Value, Origin}, State) ->
	Hash = sulibarri_dht_ring:hash(Key),
	Table = sulibarri_dht_ring_manager:partition_table(),
	{P_Id, {Node, _}} = sulibarri_dht_ring:lookup(Hash, Table),

	case Node =:= node() of
		true ->
			lager:info("Recieved Put(~p,~p); Node is primary, coordinating...",
						[Key, Value]),
			[{_, Pid}] = ets:lookup(?ETS, P_Id),
			sulibarri_dht_storage:put(Pid, Hash, {Key, Value}, Origin);
		false ->
			lager:info("Recieved Put(~p,~p); Node is not primary, forwarding to ~p",
						[Key, Value, Node]),
			gen_server:cast({?SERVER, Node},
						{forward_put, P_Id, Hash, Key, Value, Origin})
	end,
	{noreply, State};

handle_cast({get, Key, Origin}, State) ->
	Hash = sulibarri_dht_ring:hash(Key),
	Table = sulibarri_dht_ring_manager:partition_table(),
	{P_Id, {Node, _}} = sulibarri_dht_ring:lookup(Hash, Table),

	case Node =:= node() of
		true ->
			lager:info("Recieved Get(~p); Node is primary, coordinating...", [Key]),
			[{_, Pid}] = ets:lookup(?ETS, P_Id),
			sulibarri_dht_storage:get(Pid, Hash, Origin);
		false ->
			lager:info("Recieved Get(~p); Node is not primary, forwarding to ~p",
						[Key,Node]),
			gen_server:cast({?SERVER, Node},
						{forward_get, P_Id, Hash, Key, Origin})
	end,
	{noreply, State};

handle_cast({delete, Key, Origin}, State) ->
	Hash = sulibarri_dht_ring:hash(Key),
	Table = sulibarri_dht_ring_manager:partition_table(),
	{P_Id, {Node, _}} = sulibarri_dht_ring:lookup(Hash, Table),

	case Node =:= node() of
		true ->
			lager:info("Recieved Delete(~p); Node is primary, coordinating...", [Key]),
			[{_, Pid}] = ets:lookup(?ETS, P_Id),
			sulibarri_dht_storage:delete(Pid, Hash, Origin);
		false ->
			lager:info("Recieved Delete(~p); Node is not primary, forwarding to ~p",
						[Key,Node]),
			gen_server:cast({?SERVER, Node},
						{forward_delete, P_Id, Hash, Key, Origin})
	end,
	{noreply, State};

handle_cast({forward_put, P_Id, Hash, Key, Value, Origin}, State) ->
	lager:info("Recieved forwarded Put(~p,~p); Node is primary, coordinating...",
						[Key,Value]),
	[{_, Pid}] = ets:lookup(?ETS, P_Id),
	sulibarri_dht_storage:put(Pid, Hash, {Key, Value}, Origin),
	{noreply, State};

handle_cast({forward_get, P_Id, Hash, Key, Origin}, State) ->
	lager:info("Recieved forwarded get(~p); Node is primary, coordinating...",
				[Key]),
	[{_, Pid}] = ets:lookup(?ETS, P_Id),
	sulibarri_dht_storage:get(Pid, Hash, Origin),
	{noreply, State};

handle_cast({forward_delete, P_Id, Hash, Key, Origin}, State) ->
	lager:info("Recieved forwarded delete(~p); Node is primary, coordinating...",
				[Key]),
	[{_, Pid}] = ets:lookup(?ETS, P_Id),
	sulibarri_dht_storage:delete(Pid, Hash, Origin),
	{noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

% erl -pa ebin deps/*/ebin -s lager -s sulibarri_dht_app -sname
% erl -pa ebin deps/*/ebin -s lager -s sulibarri_dht_app -name someName@(IP) -setcookie (someText)