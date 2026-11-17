%% SPDX-License-Identifier: MIT
%% det_cover_recompile:main([Prefixes, EbinDirectory...]): each module whose name starts with one
%% of the comma-separated prefixes, recompiled in place from its own abstract code (its
%% debug_info chunk) with `line_coverage`, so that the emulator's line counters (`+JPcover
%% line_counters`, det_cover) count its lines: release beams carry no executable_line
%% instructions, and code:get_coverage(line, M) answers badarg for them. Run at image build
%% time, with the image's own emulator (a release's erl needs its boot file: CouchDB's), e.g.
%%   erl -noshell -pa /opt/det -eval 'det_cover_recompile:main(["rabbit_fifo,ra_", "/x/ebin"]), halt().'
%% A module without abstract code (stripped) is left as it is, and said.
-module(det_cover_recompile).
-export([main/1]).

main([Prefixes | Directories]) ->
    Wanted = string:split(Prefixes, ",", all),
    Results = [recompile(Beam) || Directory <- Directories,
                                  Beam <- filelib:wildcard(filename:join(Directory, "*.beam")),
                                  wanted(filename:basename(Beam, ".beam"), Wanted)],
    io:format("det_cover_recompile: ~b recompiled, ~b left as they were~n",
              [length([ok || ok <- Results]), length([x || {skipped, _} <- Results])]);
main(_) ->
    io:format(standard_error, "usage: det_cover_recompile:main([Prefixes, Ebin...])~n", []),
    halt(2).

wanted(Name, Prefixes) ->
    lists:any(fun(Prefix) -> Prefix =/= "" andalso lists:prefix(Prefix, Name) end, Prefixes).

recompile(Beam) ->
    case beam_lib:chunks(Beam, [abstract_code, compile_info]) of
        {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}, {compile_info, Info}]}} ->
            Options = [line_coverage, binary, return_errors | proplists:get_value(options, Info, [])],
            case compile:forms(Forms, [Option || Option <- Options, keep(Option)]) of
                {ok, Module, Binary} ->
                    ok = file:write_file(Beam, Binary),
                    ok;
                {ok, Module, Binary, _Warnings} ->
                    ok = file:write_file(Beam, Binary),
                    ok;
                Error ->
                    io:format("det_cover_recompile: ~s not recompiled: ~P~n", [Module, Error, 6]),
                    {skipped, Module}
            end;
        Other ->
            io:format("det_cover_recompile: ~s has no abstract code: ~P~n", [Beam, Other, 4]),
            {skipped, Beam}
    end.

%% The module's own compile options, less those about files and outputs (the forms are already
%% preprocessed: includes and parse transforms ran when it was built).
keep({i, _}) -> false;
keep({outdir, _}) -> false;
keep({parse_transform, _}) -> false;
keep({d, _}) -> false;
keep({d, _, _}) -> false;
keep(Option) when is_atom(Option) -> not lists:member(Option, [report_errors, report_warnings, warnings_as_errors, debug_info]);
keep(_) -> true.
