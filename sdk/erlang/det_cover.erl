%% SPDX-License-Identifier: MIT
%% det_cover: line coverage of a BEAM node for determinismo, from the emulator's own counters
%% (OTP 27+: `+JPcover line_counters`, the JIT counting each line as it runs; no module
%% recompiled, unlike `cover`). Each line of a module under the node's coverage set reached for
%% the first time is a "coverage" event, as the Python and JVM agents report theirs, so the
%% explorer has behaviors to steer by: RabbitMQ's hunt run 1911 reported 171 behaviors over 357
%% timelines without it, none reached by one timeline alone.
%%
%% The node's emulator takes `+JPcover line_counters -pa <this module's directory> -s det_cover`
%% (RabbitMQ: RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS). The coverage set is DETERMINISMO_COVERAGE,
%% module name prefixes, those starting with "-" excluded (the Zig SDK's schema.Coverage); empty,
%% nothing is reported (every module of OTP and the system would be thousands of lines a second).
%% Outside determinismo (no /dev/determinismo) it does nothing; DET_COVER_DEVICE names another
%% file to write the events to (its tests).
%%
%% A line is reported once a timeline, whichever process or node reached it first, as libvoidstar's
%% edges are: each module's reported lines are kept in /opt/determinismo/coverage/beam-<module>
%% (the guest's tmpfs every node shares, kept across a node's restarts), read when this process
%% has lines it did not report yet. Reported once a process, a broker restarted under faults
%% reported its thousands of lines again (RabbitMQ's A/B arm 1923: 17,421 coverage events in its
%% one timeline, over the events cap).
-module(det_cover).
-export([start/0, init/0]).

%% How often the counters are read, in (virtual) milliseconds.
-define(PERIOD_MS, 1000).
%% One event is one write to the device (the SDKs' protocol).
-define(DEVICE, "/dev/determinismo").
%% Where the timeline's reported lines are shared (DET_COVER_SHARED for its tests).
-define(SHARED, "/opt/determinismo/coverage").

start() ->
    _ = spawn(?MODULE, init, []),
    ok.

init() ->
    {Included, Excluded} = coverage_set(os:getenv("DETERMINISMO_COVERAGE", "")),
    Supported = erlang:function_exported(code, coverage_support, 0) andalso code:coverage_support(),
    Path = os:getenv("DET_COVER_DEVICE", ?DEVICE),
    case {Included, Supported, file:open(Path, [write, raw, binary])} of
        {[], _, {ok, Device}} -> file:close(Device);
        {_, false, {ok, Device}} -> file:close(Device);
        {_, true, {ok, Device}} ->
            Reported = ets:new(det_cover_reported, [set, private]),
            Shared = os:getenv("DET_COVER_SHARED", ?SHARED),
            put(det_cover_shared, case filelib:is_dir(Shared) of true -> Shared; false -> none end),
            loop(Device, Reported, {Included, Excluded});
        {_, _, {error, _}} -> ok
    end.

loop(Device, Reported, Set) ->
    timer:sleep(?PERIOD_MS),
    [report(Device, Reported, Module) || {Module, _} <- code:all_loaded(), covered(Module, Set)],
    loop(Device, Reported, Set).

report(Device, Reported, Module) ->
    try code:get_coverage(line, Module) of
        Lines ->
            case [Line || {Line, Hits} <- Lines, hit(Hits), not ets:member(Reported, {Module, Line})] of
                [] -> ok;
                New -> report_new(Device, Reported, Module, New)
            end
    catch
        %% Not compiled with line_coverage (det_cover_recompile.escript at image build time),
        %% loaded before coverage was on, or purged meanwhile.
        error:badarg -> ok
    end.

hit(Hits) when is_integer(Hits) -> Hits > 0;
hit(Hits) -> Hits =:= true. % line_coverage mode: booleans.

%% Lines this process did not report: those another process or node reported this timeline
%% (the module's shared file) are known, the rest reported and added to it.
report_new(Device, Reported, Module, New) ->
    Path = case get(det_cover_shared) of
               none -> none;
               Dir -> filename:join(Dir, "beam-" ++ atom_to_list(Module))
           end,
    shared_read(Path, Reported, Module),
    Fresh = [Line || Line <- New, ets:insert_new(Reported, {{Module, Line}})],
    [begin
         Event = io_lib:format("{\"event\":\"coverage\",\"details\":{\"name\":\"line ~s.erl:~b\"}}",
                               [Module, Line]),
         _ = file:write(Device, iolist_to_binary(Event))
     end || Line <- Fresh],
    case {Path, Fresh} of
        {none, _} -> ok;
        {_, []} -> ok;
        _ -> _ = file:write_file(Path, [[integer_to_list(Line), $\n] || Line <- Fresh], [append]), ok
    end.

shared_read(none, _Reported, _Module) ->
    ok;
shared_read(Path, Reported, Module) ->
    case file:read_file(Path) of
        {ok, Text} ->
            [ets:insert(Reported, {{Module, binary_to_integer(Line)}})
             || Line <- binary:split(Text, <<"\n">>, [global, trim_all])],
            ok;
        {error, _} ->
            ok
    end.

covered(Module, {Included, Excluded}) ->
    Name = atom_to_list(Module),
    lists:any(fun(Prefix) -> lists:prefix(Prefix, Name) end, Included)
        andalso not lists:any(fun(Prefix) -> lists:prefix(Prefix, Name) end, Excluded).

coverage_set("!") ->
    {[], []}; % Off (a run's `"coverage": "off"`, an A/B's other arm): nothing read or reported.
coverage_set(Text) ->
    Entries = [Entry || Entry <- string:split(Text, ",", all), Entry =/= "", Entry =/= "-"],
    {[Entry || Entry <- Entries, hd(Entry) =/= $-],
     [tl(Entry) || Entry <- Entries, hd(Entry) =:= $-]}.
