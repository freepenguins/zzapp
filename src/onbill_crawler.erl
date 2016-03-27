-module(onbill_crawler).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,terminate/2
         ,code_change/3
        ]).

-include("onbill.hrl").

-include_lib("whistle/include/wh_databases.hrl").

-define(MOD_CONFIG_CAT, <<(?APP_NAME)/binary, ".account_crawler">>).


-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! 'crawl_accounts',
    {'ok', #state{}}.

handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

handle_cast(_Msg, State) ->
    {'noreply', State}.

handle_info('next_account', []) ->
    NextDay = calendar:datetime_to_gregorian_seconds({erlang:date(),{0,15,0}}) + ?SECONDS_IN_DAY,
    Cycle = NextDay - calendar:datetime_to_gregorian_seconds(erlang:localtime()),
    erlang:send_after(Cycle, self(), 'crawl_accounts'),
    {'noreply', [], 'hibernate'};
handle_info('next_account', [Account|Accounts]) ->
    _ = case wh_doc:id(Account) of
            <<"_design", _/binary>> -> 'ok';
            AccountId ->
                OpenResult = couch_mgr:open_doc(?WH_ACCOUNTS_DB, AccountId),
                check_then_process_account(AccountId, OpenResult)
        end,
    Cycle = whapps_config:get_integer(?MOD_CONFIG_CAT, <<"interaccount_delay">>, 10 * ?MILLISECONDS_IN_SECOND),
    erlang:send_after(Cycle, self(), 'next_account'),
    {'noreply', Accounts, 'hibernate'};
handle_info('crawl_accounts', _) ->
    _ = case couch_mgr:all_docs(?WH_ACCOUNTS_DB) of
            {'ok', JObjs} ->
                self() ! 'next_account',
                {'noreply', wh_util:shuffle_list(JObjs)};
            {'error', _R} ->
                lager:warning("unable to list all docs in ~s: ~p", [?WH_ACCOUNTS_DB, _R]),
                self() ! 'next_account',
                {'noreply', []}
        end;
handle_info(_Info, State) ->
    lager:debug("unhandled msg: ~p", [_Info]),
    {'noreply', State}.

terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec check_then_process_account(ne_binary(), {'ok', kz_account:doc()} | {'error',any()}) -> 'ok'.
check_then_process_account(AccountId, {'ok', AccountJObj}) ->
    case wh_doc:is_soft_deleted(AccountJObj) of
        'true' -> 'ok'; 
        'false' ->
            process_account(AccountId)
    end;
check_then_process_account(AccountId, {'error', _R}) ->
    lager:warning("unable to open account definition for ~s: ~p", [AccountId, _R]).

-spec process_account (ne_binary()) -> 'ok'.
process_account(AccountId) ->
    lager:debug("onbill crawler processing account ~s", [AccountId]),
    wh_service_sync:sync(AccountId),
    'ok'.