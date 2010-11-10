% @copyright 2007-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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
%% @doc This is a small server for running benchmarks
%% @end
-module(bench_server).
-author('schuett@zib.de').
-vsn('$Id$').

-export([start_link/0, start/0]).
-export([run_increment/2, run_increment_v2/2, run_increment/3, run_increment_locally/2]).
-export([run_read/2, run_read_v2/2, run_read/3, bench_runner/3]).

-include("scalaris.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% public interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc run an increment benchmark (i++) on all nodes
-spec run_increment(ThreadsPerVM::pos_integer(), Iterations::pos_integer()) -> ok.
run_increment(ThreadsPerVM, Iterations) ->
    Msg = {bench_increment, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, [verbose], Msg).

-spec run_increment_v2(ThreadsPerVM::pos_integer(), Iterations::pos_integer()) -> ok.
run_increment_v2(ThreadsPerVM, Iterations) ->
    Msg = {bench_increment_v2, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, [verbose], Msg).

-spec run_increment_locally(ThreadsPerVM::pos_integer(), Iterations::pos_integer()) -> ok.
run_increment_locally(ThreadsPerVM, Iterations) ->
    Msg = {bench_increment, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, [locally, verbose], Msg).

%% @doc run an increment benchmark (i++) on all nodes
%% profile : enable profiling
%% {copies, Copies}: run in the benchmark in Copies nodes
-spec run_increment(ThreadsPerVM::pos_integer(), Iterations::pos_integer(), Options::[locally | verbose | profile | {copies, non_neg_integer()}]) -> ok.
run_increment(ThreadsPerVM, Iterations, Options) ->
    Msg = {bench_increment, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, Options, Msg).

%% @doc run an read benchmark on all nodes
-spec run_read(ThreadsPerVM::pos_integer(), Iterations::pos_integer()) -> ok.
run_read(ThreadsPerVM, Iterations) ->
    Msg = {bench_read, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, [verbose], Msg).

-spec run_read_v2(ThreadsPerVM::pos_integer(), Iterations::pos_integer()) -> ok.
run_read_v2(ThreadsPerVM, Iterations) ->
    Msg = {bench_read_v2, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, [verbose], Msg).

-spec run_read(ThreadsPerVM::pos_integer(), Iterations::pos_integer(), Options::[locally | verbose | profile | {copies, non_neg_integer()}]) -> ok.
run_read(ThreadsPerVM, Iterations, Options) ->
    Msg = {bench_read, ThreadsPerVM, Iterations, comm:this()},
    runner(ThreadsPerVM, Iterations, Options, Msg).

-spec runner(ThreadsPerVM::pos_integer(), Iterations::pos_integer(), Options::[locally | verbose | profile | {copies, non_neg_integer()}], Message::comm:message()) -> ok.
runner(ThreadsPerVM, Iterations, Options, Message) ->
    ServerList = case lists:member(locally, Options) of
                     true ->
                         [comm:make_global(bench_server)];
                     false ->
                         case lists:keyfind(copies, 1, Options) of
                             {copies, Copies} ->
                                 lists:sublist(util:get_nodes(), Copies);
                             false ->
                                 util:get_nodes()
                         end
                 end,
    %io:format("~p~n", [ServerList]),
    {BeforeDump, _} = admin:get_dump(),
    Before = erlang:now(),
    Times = case lists:member(profile, Options) of
                false ->
                    [comm:send(Server, Message) || Server <- ServerList],
                    io:format("Collecting results... ~n"),
                    [receive {done, X, Time} -> io:format("BS: ~p @ ~p~n",[Time, X]),Time end || _Server <- ServerList];
                true ->
                    Result = fprof:apply(fun () ->
                                                 [comm:send(Server, Message) || Server <- ServerList],
                                                 [receive {done, _X, Time} -> Time end || _Server <- ServerList]
                                         end,
                                         [], [{procs, pid_groups:processes()}]),
                    fprof:profile(),
                    %fprof:analyse(),
                    fprof:analyse([{cols, 140}, details, callers, totals, {dest, []}]),
                    Result
            end,
    After = erlang:now(),
    case lists:member(verbose, Options) of
        true ->
            {AfterDump, _} = admin:get_dump(),
            RunTime = timer:now_diff(After, Before),
            DiffDump = admin:diff_dump(BeforeDump, AfterDump, RunTime),
            io:format("servers: ~p threads/vm: ~p iterations: ~p~n",
                      [length(ServerList), ThreadsPerVM, Iterations]),
            io:format("total time: ~p~n", [RunTime / 1000000.0]),
            io:format("1/s: ~p~n",
                      [length(ServerList) * ThreadsPerVM * Iterations / RunTime * 1000000.0]),
            Throughput = [ThreadsPerVM * Iterations / Time * 1000000.0 || Time <- Times],
            io:format("~p~n", [Throughput]),
            io:format("High load avg. latency: ~p ms~n", [ RunTime / 1000.0 / Iterations ]),
            io:format("Message statistics (message name, bytes, how often): ~p~n", [DiffDump]);
        false ->
            ok
    end,
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% benchmarks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc run the increment bench locally
-spec bench_increment(Threads::pos_integer(), Iterations::pos_integer(), Owner::comm:mypid()) -> ok.
bench_increment(Threads, Iterations, Owner) ->
    Bench = fun (Parent) ->
                    Key = get_and_init_key(),
                    bench_increment:process(Parent,
                                            Key,
                                            Iterations)
            end,
    {Time, _} = util:tc(?MODULE, bench_runner, [Threads, Iterations, Bench]),
    comm:send(Owner, {done, comm_server:get_local_address_port(), Time}),
    ok.

-spec bench_increment_v2(Threads::pos_integer(), Iterations::pos_integer(), Owner::comm:mypid()) -> ok.
bench_increment_v2(Threads, Iterations, Owner) ->
    Bench = fun (Parent) ->
                    Key = get_and_init_key(),
                    bench_increment:process_v2(Parent, Key, Iterations)
            end,
    {Time, _} = util:tc(?MODULE, bench_runner, [Threads, Iterations, Bench]),
    comm:send(Owner, {done, comm_server:get_local_address_port(), Time}),
    ok.

%% @doc run the read bench locally
-spec bench_read(Threads::pos_integer(), Iterations::pos_integer(), Owner::comm:mypid()) -> ok.
bench_read(Threads, Iterations, Owner) ->
    Bench = fun (Parent) ->
                    Key = get_and_init_key(),
                    run_bench_read(Parent, Key, Iterations)
            end,
    {Time, _} = util:tc(?MODULE, bench_runner, [Threads, Iterations, Bench]),
    comm:send(Owner, {done, comm_server:get_local_address_port(), Time}),
    ok.

-spec bench_read_v2(Threads::pos_integer(), Iterations::pos_integer(), Owner::comm:mypid()) -> ok.
bench_read_v2(Threads, Iterations, Owner) ->
    Bench = fun (Parent) ->
                    Key = get_and_init_key(),
                    run_bench_read_v2(Parent, Key, Iterations, 0)
            end,
    {Time, _} = util:tc(?MODULE, bench_runner, [Threads, Iterations, Bench]),
    comm:send(Owner, {done, comm_server:get_local_address_port(), Time}),
    ok.

-spec bench_runner(Threads::non_neg_integer(), Iterations::pos_integer(), Bench::fun((Parent::comm:erl_local_pid()) -> any())) -> ok.
bench_runner(0, _Iterations, _Bench) ->
    ok;
bench_runner(Threads, Iterations, Bench) ->
    Self = self(),
    spawn(fun () -> Bench(Self) end),
    bench_runner(Threads - 1, Iterations, Bench),
    receive
        {done, _} -> ok
    end.

-spec run_bench_read(Parent::comm:erl_local_pid(), Key::string(), Iterations::non_neg_integer()) -> ok.
run_bench_read(Owner, _Key, 0) ->
    comm:send_local(Owner, {done, ok});
run_bench_read(Owner, Key, Iterations) ->
    case transaction_api:quorum_read(Key) of
        {fail, _Reason} ->
            run_bench_read(Owner, Key, Iterations);
        {_Value, _Version} ->
            run_bench_read(Owner, Key, Iterations - 1)
    end.

-spec run_bench_read_v2(Parent::comm:erl_local_pid(), Key::string(), Iterations::non_neg_integer(), FailedReads::non_neg_integer()) -> ok.
run_bench_read_v2(Owner, _Key, 0, Fail) ->
    io:format("repeated requests: ~p~n", [Fail]),
    comm:send_local(Owner , {done, ok});
run_bench_read_v2(Owner, Key, Iterations, Fail) ->
    case cs_api_v2:read(Key) of
        {fail, _Reason} ->
            run_bench_read_v2(Owner, Key, Iterations, Fail + 1);
        _Value ->
            run_bench_read_v2(Owner, Key, Iterations - 1, Fail)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% main loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec loop() -> no_return().
loop() ->
    receive
        {bench_increment, Threads, Iterations, Owner} ->
            spawn(fun () -> bench_increment(Threads, Iterations, Owner) end);
        {bench_increment_v2, Threads, Iterations, Owner} ->
            spawn(fun () -> bench_increment_v2(Threads, Iterations, Owner) end);
        {bench_read, Threads, Iterations, Owner} ->
            spawn(fun () -> bench_read(Threads, Iterations, Owner) end);
        {bench_read_v2, Threads, Iterations, Owner} ->
            spawn(fun () -> bench_read_v2(Threads, Iterations, Owner) end)
    end,
    loop().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% startup functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec start() -> no_return().
start() ->
    register(bench_server, self()),
    loop().

%% @doc spawns a bench_server
-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, spawn_link(?MODULE, start, [])}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec get_and_init_key() -> string().
get_and_init_key() ->
    Key = randoms:getRandomId(),
    case get_and_init_key(Key, _Retries = 10) of
        fail ->
            io:format("geT_and_init_key choosing new key and retrying~n"),
            get_and_init_key();
        Key -> Key
    end.

get_and_init_key(_Key, 0) ->
    fail;
get_and_init_key(Key, Count) ->
    case cs_api_v2:write(Key, 0) of
        ok ->
            Key;
        {fail, abort} ->
            io:format("geT_and_init_key 1 failed, retrying~n", []),
            get_and_init_key(Key, Count - 1);
        {fail, failed} ->
            io:format("geT_and_init_key 1 failed, retrying~n", []),
            get_and_init_key(Key, Count - 1);
        {fail, timeout} ->
            io:format("geT_and_init_key 2 timeout, retrying~n", []),
            get_and_init_key(Key, Count - 1)
    end.
