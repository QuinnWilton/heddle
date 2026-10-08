#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
%% Encodes Heddle's producer corpus with this node's term_to_binary/2.
%%
%%     escript test/fixtures/generate.escript test/fixtures/producers
%%
%% Run it on every OTP release whose output Heddle must read (24 to 29);
%% each run writes otp<release>/<case>-<variant>.etf. The expected values
%% live in test/heddle/fixtures_test.exs.

main([Dir]) ->
    Out = filename:join(Dir, "otp" ++ erlang:system_info(otp_release)),
    ok = filelib:ensure_dir(filename:join(Out, "x")),
    Variants = [{"default", []}, {"minor1", [{minor_version, 1}]}, {"deterministic", [deterministic]}],
    [ok = file:write_file(filename:join(Out, Name ++ "-" ++ Variant ++ ".etf"), term_to_binary(Term, Opts))
     || {Name, Term} <- corpus(), {Variant, Opts} <- Variants],
    io:format("wrote ~s~n", [Out]).

corpus() ->
    [{"session",
      #{'__struct__' => 'Elixir.Heddle.Test.Session',
        user_id => 42,
        roles => [admin, editor],
        expires_at => 1790000000,
        meta => #{<<"ip">> => <<"203.0.113.7">>, <<"agent">> => <<"curl/8">>}}},
     {"commands", [ping, {put, <<"k">>, <<"v">>}, {delete, <<"k">>}]},
     {"integers", [0, 255, 256, -1, 2147483647, -2147483648, 2147483648, 1 bsl 64, -(1 bsl 100)]},
     {"floats", [1.5, -0.0, 1.0e300, 5.0e-324]},
     {"atoms", ['é', ok, 'ünïcode', '日本']},
     {"charlists", ["hello", [1, 2, 3], [300, 400], [], "héllo"]},
     {"binaries", [<<>>, <<"plain">>, <<"héllo"/utf8>>, binary:copy(<<"x">>, 300)]},
     {"nested", {tag, [{a, 1}, {b, <<"two">>}], #{}, {}}},
     {"bigmap", maps:from_list([{I, I * I} || I <- lists:seq(1, 40)])},
     {"unknown", [http, https, gopher]}].
