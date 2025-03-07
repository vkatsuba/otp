%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2013-2021. All Rights Reserved.
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
%%
%% %CopyrightEnd%
%%

%%
%% Test example code under ../examples/code.
%%

-module(diameter_examples_SUITE).

-export([suite/0,
         all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2]).

%% testcases
-export([dict/1,
         code/1,
         start/1,
         traffic/1]).

-export([install/1,
         call/1]).

-include("diameter.hrl").

-include_lib("common_test/include/ct.hrl").

%% ===========================================================================

%% @inherits dependencies between example dictionaries. This is needed
%% in order compile them in the right order. Can't compile to erl to
%% find out since @inherits is a beam dependency.
-define(INHERITS, [{rfc4006_cc,  [rfc4005_nas]},
                   {rfc4072_eap, [rfc4005_nas]},
                   {rfc4740_sip, [rfc4590_digest]}]).

%% Common dictionaries to inherit from examples.
-define(DICT0, [rfc3588_base, rfc6733_base]).

%% Transport protocols over which the example Diameter nodes are run.
-define(PROTS, [tcp, sctp]).

%% ===========================================================================

suite() ->
    [{timetrap, {minutes, 2}}].

all() ->
    [dict,
     code,
     {group, all}].

groups() ->
    Tc = tc(),
    [{all, [parallel], [{group, P} || P <- ?PROTS]}
     | [{P, [], Tc} || P <- ?PROTS]].

%% Not used, but a convenient place to enable trace.
init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(all, Config) ->
    Config;

init_per_group(tcp = N, Config) ->
    [{group, N} | Config];

init_per_group(sctp = N, Config) ->
    case diameter_util:have_sctp() of
        true ->
            [{group, N} | Config];
        false->
            {skip, no_sctp}
    end.

end_per_group(_, _) ->
    ok.

tc() ->
    [traffic].

%% ===========================================================================
%% dict/1
%%
%% Compile example dictionaries in examples/dict.

dict(_Config) ->
    Dirs = [filename:join(H ++ ["examples", "dict"])
            || H <- [[code:lib_dir(diameter)], [here(), ".."]]],
    [] = [{F,D,RC} || {_,F} <- sort(find_files(Dirs, ".*\\.dia$")),
                      D <- ?DICT0,
                      RC <- [make(F,D)],
                      RC /= ok].

sort([{_,_} | _] = Files) ->
    lists:sort(fun({A,_},{B,_}) ->
                       sort([filename:rootname(F) || F <- [A,B]])
               end,
               Files);

sort([A,B] = L) ->
    [DA,DB] = [dep([D],[]) || D <- L],
    case {[A] -- DB, [B] -- DA} of
        {[], [_]} ->  %% B depends on A
            true;
        {[_], []} ->  %% A depends on B
            false;
        {[_],[_]} ->  %% or not
            length(DA) < length(DB)
    end.

%% Recursively accumulate inherited dictionaries.
dep([D|Rest], Acc) ->
    dep(dep(D), Rest, Acc);
dep([], Acc) ->
    Acc.

dep([{Dict, _} | T], Rest, Acc) ->
    dep(T, [Dict | Rest], [Dict | Acc]);
dep([], Rest, Acc) ->
    dep(Rest, Acc).

make(Path, Dict0)
  when is_atom(Dict0) ->
    make(Path, atom_to_list(Dict0));

make(Path, Dict0) ->
    Dict = filename:rootname(filename:basename(Path)),
    {Mod, Pre} = make_name(Dict),
    {"diameter_gen_base" ++ Suf = Mod0, _} = make_name(Dict0),
    Name = Mod ++ Suf,
    try
        ok = to_erl(Path, [{name, Name},
                           {prefix, Pre},
                           {inherits, "common/" ++ Mod0}
                           | [{inherits, D ++ "/" ++ M ++ Suf}
                              || {D,M} <- dep(Dict)]]),
        ok = to_beam(Name)
    catch
        throw: {_,_} = E ->
            E
    end.

to_erl(File, Opts) ->
    case diameter_make:codec(File, Opts) of
        ok ->
            ok;
        No ->
            throw({make, No})
    end.

to_beam(Name) ->
    case compile:file(Name ++ ".erl", [return]) of
        {ok, _, _} ->
            ok;
        No ->
            throw({compile, No})
    end.

dep(Dict) ->
    case lists:keyfind(list_to_atom(Dict), 1, ?INHERITS) of
        {_, Is} ->
            lists:map(fun inherits/1, Is);
        false ->
            []
    end.

inherits(Dict)
  when is_atom(Dict) ->
    inherits(atom_to_list(Dict));

inherits(Dict) ->
    {Name, _} = make_name(Dict),
    {Dict, Name}.

make_name(Dict) ->
    {R, [$_|N]} = lists:splitwith(fun(C) -> C /= $_ end, Dict),
    {string:join(["diameter_gen", N, R], "_"), "diameter_" ++ N}.

%% ===========================================================================
%% code/1
%%
%% Compile example code under examples/code.

code(Config) ->
    {ok, Peer, Node} = ?CT_PEER(),
    [] = rpc:call(Node,
                  ?MODULE,
                  install,
                  [proplists:get_value(priv_dir, Config)]),
    peer:stop(Peer).

%% Compile on another node since the code path may be modified.
install(PrivDir) ->
    Top = install(here(), PrivDir),
    Src = filename:join([Top, "examples", "code"]),
    Files = find_files([Src], ".*\\.erl$"),
    [] = [{F,E} || {_,F} <- Files,
                   {error, _, _} = E <- [compile:file(F, [warnings_as_errors,
                                                          return_errors])]].

%% Copy include files into a temporary directory and adjust the code
%% path in order for example code to be able to include them with
%% include_lib. This is really only required when running in the reop
%% since generated includes, that the example code wants to
%% include_lib, are under src/gen and there's no way to get get the
%% preprocessor to find these otherwise. Generated hrls are only be
%% under include in an installation. ("Installing" them locally is
%% anathema.)
install(Dir, PrivDir) ->
    %% Remove the path added to the peer (needed for the rpc:call/4 in
    %% compile/1 to find ?MODULE) so the call to code:lib_dir/2 below
    %% returns the installed path.
    [Ebin | _] = code:get_path(),
    true = code:del_path(Ebin),
    Top = top(Dir, code:lib_dir(diameter)),

    %% Create a new diameter/include in priv_dir. Copy all includes
    %% there, from below ../include and ../src/gen if they exist (in
    %% the repo).
    Tmp = filename:join([PrivDir, "diameter"]),
    TmpInc = filename:join([PrivDir, "diameter", "include"]),
    TmpEbin = filename:join([PrivDir, "diameter", "ebin"]),
    [] = [{T,E} || T <- [Tmp, TmpInc, TmpEbin],
                   {error, E} <- [file:make_dir(T)]],

    Inc = filename:join([Top, "include"]),
    Gen = filename:join([Top, "src", "gen"]),
    Files = find_files([Inc, Gen], ".*\\.hrl$"),
    [] = [{F,E} || {_,F} <- Files,
                   B <- [filename:basename(F)],
                   D <- [filename:join([TmpInc, B])],
                   {error, E} <- [file:copy(F,D)]],

    %% Prepend the created directory just so that code:lib_dir/1 finds
    %% it when compile:file/2 tries to resolve include_lib.
    true = code:add_patha(TmpEbin),
    Tmp = code:lib_dir(diameter),  %% assert
    %% Return the top directory containing examples/code.
    Top.

find_files(Dirs, RE) ->
    lists:foldl(fun(D,A) -> fold_files(D, RE, A) end,
                orddict:new(),
                Dirs).

fold_files(Dir, RE, Acc) ->
    filelib:fold_files(Dir, RE, false, fun store/2, Acc).

store(Path, Dict) ->
    orddict:store(filename:basename(Path), Path, Dict).

%% ===========================================================================

here() ->
    filename:dirname(code:which(?MODULE)).

top(Dir, LibDir) ->
    File = filename:join([Dir, "depend.sed"]),  %% only in the repo
    case filelib:is_regular(File) of
        true  -> filename:join([Dir, ".."]);
        false -> LibDir
    end.

%% start/1

start({server, Prot}) ->
    ok = diameter:start(),
    ok = server:start(),
    {ok, Ref} = server:listen({Prot, any, 3868}),
    [_] = diameter_util:lport(Prot, Ref),
    ok;

start({client = Svc, Prot}) ->
    ok = diameter:start(),
    true = diameter:subscribe(Svc),
    ok = client:start(),
    {ok, Ref} = client:connect({Prot, loopback, loopback, 3868}),
    receive #diameter_event{info = {up, Ref, _, _, _}} -> ok end.

%% traffic/1
%%
%% Send successful messages from client to server.

traffic(server) ->
    ok;

traffic(client) ->
    {_, MRef} = spawn_monitor(fun() -> call(100) end),
    receive {'DOWN', MRef, process, _, Reason} -> Reason end;

traffic(Config) ->
    Prot = proplists:get_value(group, Config),
    {ok, ServerPeer, ServerNode} = ?CT_PEER(),
    ok = rpc:call(ServerNode, ?MODULE, start, [{server, Prot}]),
    {ok, ClientPeer, ClientNode} = ?CT_PEER(),
    ok = rpc:call(ClientNode, ?MODULE, start, [{client, Prot}]),
    ok = rpc:call(ClientNode, ?MODULE, traffic, [client]),
    peer:stop(ClientPeer),
    peer:stop(ServerPeer).

call(0) ->
    exit(ok);

call(N) ->
    {ok, _} = client:call(),
    call(N-1).
