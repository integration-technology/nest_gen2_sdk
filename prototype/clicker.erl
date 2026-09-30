-module(clicker).
-export([start/0]).

%% Plays the stock Nest dial click on the piezo (pwm-beeper, /dev/input/event0).
%% Tone and length come from Nest's product.config: clickfrequency 2000,
%% clickduration 3 (ms). Clicks closer together than MIN_GAP_MS are dropped.

-define(DEVICE, "/dev/input/event0").
-define(FREQ_HZ, 2000).
-define(DURATION_MS, 3).
-define(MIN_GAP_MS, 15).
-define(EV_SYN, 16#00).
-define(EV_SND, 16#12).
-define(SND_TONE, 16#02).

start() ->
    spawn(fun init/0).

init() ->
    {ok, Dev} = file:open(?DEVICE, [write, raw, binary]),
    loop(Dev, 0).

loop(Dev, LastClick) ->
    receive
        click ->
            Now = erlang:monotonic_time(millisecond),
            case Now - LastClick >= ?MIN_GAP_MS of
                true ->
                    tone(Dev, ?FREQ_HZ),
                    timer:sleep(?DURATION_MS),
                    tone(Dev, 0),
                    loop(Dev, Now);
                false ->
                    loop(Dev, LastClick)
            end
    end.

%% 16-byte input_event for this 32-bit kernel: zero timeval, type, code, value.
tone(Dev, Hz) ->
    ok = file:write(Dev, [event(?EV_SND, ?SND_TONE, Hz), event(?EV_SYN, 0, 0)]).

event(Type, Code, Value) ->
    <<0:64, Type:16/little, Code:16/little, Value:32/little-signed>>.
