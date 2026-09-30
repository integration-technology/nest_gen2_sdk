-module(backplate).
-export([start/1]).

%% Keeps the Nest backplate from power-cycling the head unit by repeating the
%% 30-second exchange the stock nlclient performs:  0x83, then 0xa2 and 0xa3.
%% Also forwards PIR motion to Owner as `motion` messages.
%% Serial I/O goes through the bplink C helper as a port.

-define(BPLINK, "/media/scratch/.nest_gen2_sdk/bplink").
-define(TTY, "/dev/ttyO2").
-define(CYCLE_MS, 30000).
-define(A2_DELAY_MS, 1900).
-define(A3_DELAY_MS, 150).
-define(LOG_EVERY_CYCLES, 10).
-define(LOG, "/media/scratch/.nest_gen2_sdk/backplate.log").
%% 0x0007 reads 0 when nothing moves and 1-10 with motion (far PIR level).
-define(PIR_LEVEL_THRESHOLD, 2).

start(Owner) ->
    spawn(fun() -> init(Owner) end).

init(Owner) ->
    log("starting backplate keep-alive"),
    Port = open(),
    self() ! cycle,
    loop(#{port => Port, owner => Owner, cycles => 0, rx => 0, battery_mv => undefined}).

open() ->
    open_port({spawn_executable, ?BPLINK},
              [{args, [?TTY]}, {line, 4096}, exit_status, use_stdio, binary]).

send(Port, Line) ->
    port_command(Port, [Line, $\n]).

loop(#{port := Port} = S) ->
    receive
        cycle ->
            send(Port, "tx 83"),
            erlang:send_after(?A2_DELAY_MS, self(), a2),
            erlang:send_after(?CYCLE_MS, self(), cycle),
            Cycles = maps:get(cycles, S) + 1,
            case Cycles rem ?LOG_EVERY_CYCLES of
                0 -> log(io_lib:format("cycle ~p, frames received ~p, battery ~p mV",
                                       [Cycles, maps:get(rx, S), maps:get(battery_mv, S)]));
                _ -> ok
            end,
            loop(S#{cycles := Cycles});
        a2 ->
            send(Port, "tx a2"),
            erlang:send_after(?A3_DELAY_MS, self(), a3),
            loop(S);
        a3 ->
            send(Port, "tx a3"),
            loop(S);
        {Port, {data, {eol, <<"rx ", Rest/binary>>}}} ->
            loop(note_frame(Rest, S#{rx := maps:get(rx, S) + 1}));
        {Port, {data, {eol, <<"ready", _/binary>> = Line}}} ->
            log(binary_to_list(Line)),
            loop(S);
        {Port, {data, {eol, <<"err", _/binary>> = Line}}} ->
            log(binary_to_list(Line)),
            loop(S);
        {Port, {data, _}} ->
            loop(S);
        {Port, {exit_status, Status}} ->
            log(io_lib:format("bplink exited with status ~p, reopening in 5s", [Status])),
            timer:sleep(5000),
            loop(S#{port := open()})
    end.

%% Frame 0x000b carries the battery voltage in mV at payload bytes 12-13 (LE),
%% matching nlscpm-shutdown-manager's batteryLevel log.
note_frame(<<"000b ", Hex/binary>>, S) ->
    case hex_to_bin(Hex) of
        <<_:12/binary, Mv:16/little, _/binary>> -> S#{battery_mv := Mv};
        _ -> S
    end;
%% 0x0002 (every ~30 s): temperature in 1/100 degC and relative humidity in
%% 1/10 %, both LE. Raw sensor values, uncorrected for the unit's self-heating.
note_frame(<<"0002 ", Hex/binary>>, #{owner := Owner} = S) ->
    case hex_to_bin(Hex) of
        <<CentiC:16/little-signed, DeciRH:16/little>> -> Owner ! {climate, CentiC / 100, DeciRH / 10};
        _ -> ok
    end,
    S;
%% 0x0023: three int16 LE in 1/100 degC, apparently other board temperatures
%% (drift with the unit's own heat); forwarded for calibration.
note_frame(<<"0023 ", Hex/binary>>, #{owner := Owner} = S) ->
    case hex_to_bin(Hex) of
        <<A:16/little-signed, B:16/little-signed, C:16/little-signed, _/binary>> ->
            Owner ! {board_temps, [A / 100, B / 100, C / 100]};
        _ -> ok
    end,
    S;
note_frame(<<"0007 ", Hex/binary>>, #{owner := Owner} = S) ->
    case hex_to_bin(Hex) of
        <<Level:16/little>> when Level >= ?PIR_LEVEL_THRESHOLD -> Owner ! motion;
        _ -> ok
    end,
    S;
%% 0x0005 is non-zero when a PIR event fires (near or far), zero when it clears.
note_frame(<<"0005 ", Hex/binary>>, #{owner := Owner} = S) ->
    case hex_to_bin(Hex) of
        <<0:32>> -> ok;
        _ -> Owner ! motion
    end,
    S;
note_frame(_, S) ->
    S.

hex_to_bin(Hex) ->
    << <<(list_to_integer([A, B], 16))>> || <<A, B>> <= Hex >>.

log(Msg) ->
    {{Y, Mo, D}, {H, Mi, Se}} = calendar:local_time(),
    Line = io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w ~s~n", [Y, Mo, D, H, Mi, Se, Msg]),
    file:write_file(?LOG, Line, [append]).
