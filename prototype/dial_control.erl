-module(dial_control).
-export([main/0]).

-define(BACKLIGHT, "/sys/class/backlight/3-0036/brightness").
-define(IDLE_TIMEOUT_MS, 30000).
-define(TICK_MS, 1000).
-define(EVWATCH, "/media/scratch/.nest_gen2_sdk/evwatch").
%% Rotation sensor counts per full turn of the ring. The ADBS-A350 is fixed at
%% 750 cpi (speed switching off), so ~pi x 3.3in x 750 = ~7800; measured 7887.
-define(UNITS_PER_REV, 7800).
%% One click each time the angle crosses a multiple of this many degrees.
-define(CLICK_STEP_DEG, 10).
%% Interim self-heating correction: raw backplate temperature read 4.1 degC above
%% a TEMPer2 probe beside it (2026-09-30). To be replaced by a fitted model.
-define(TEMP_OFFSET_C, -4.1).

log(Msg) ->
    {{Y,Mo,D},{H,Mi,S}} = calendar:local_time(),
    Line = io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w ~s~n", [Y,Mo,D,H,Mi,S,Msg]),
    file:write_file("/media/scratch/.nest_gen2_sdk/dial_control.log", Line, [append]).

set_backlight(Val) ->
    file:write_file(?BACKLIGHT, integer_to_list(Val) ++ "\n").

wake() ->
    set_backlight(2), timer:sleep(16),
    set_backlight(5), timer:sleep(16),
    set_backlight(113).

sleep_screen() ->
    set_backlight(5), timer:sleep(16),
    set_backlight(2), timer:sleep(16),
    set_backlight(0).

now_ms() ->
    erlang:monotonic_time(millisecond).

%% evwatch prints "ev <type> <code> <value>" per input event; running it as a
%% port avoids Erlang's own unreliable blocking file:read on evdev nodes.
open_watch_port(Device) ->
    open_port({spawn_executable, ?EVWATCH}, [{args, [Device]}, {line, 256}, exit_status]).

%% EV_REL (2) / REL_X (0) comes only from the ring's rotation sensor.
%% The sensor counts negative for clockwise, so the sign is flipped.
handle_input_line("ev 2 0 " ++ Value) ->
    Old = get(angle),
    Angle = Old - list_to_integer(Value) * 360 / ?UNITS_PER_REV,
    put(angle, Angle),
    get(spinner) ! {angle, Angle},
    case floor(Angle / ?CLICK_STEP_DEG) =/= floor(Old / ?CLICK_STEP_DEG) of
        true -> get(clicker) ! click;
        false -> ok
    end;
handle_input_line(_) ->
    ok.

%% Latest raw readings for calibration, on tmpfs so it costs no flash writes:
%% "<temp_c> <rh_pct> <board1> <board2> <board3>".
write_climate() ->
    case {get(climate), get(board_temps)} of
        {{T, RH}, [A, B, C]} ->
            file:write_file("/tmp/nest_climate",
                            io_lib:format("~.2f ~.1f ~.2f ~.2f ~.2f~n", [T, RH, A, B, C]));
        _ -> ok
    end.

activity(Awake, Why) ->
    case Awake of
        false -> wake(), log("woke on " ++ Why);
        true -> ok
    end.

controller(Awake, LastActivity, Tick) ->
    receive
        {_Port, {data, {_, Line}}} ->
            handle_input_line(Line),
            activity(Awake, "input"),
            controller(true, now_ms(), Tick);
        motion ->
            activity(Awake, "motion"),
            controller(true, now_ms(), Tick);
        {climate, TempC, RH} ->
            Shown = TempC + ?TEMP_OFFSET_C,
            get(spinner) ! {text, lists:flatten(io_lib:format("~.1f", [Shown])) ++ [$\x{b0}, $C]},
            put(climate, {TempC, RH}),
            write_climate(),
            controller(Awake, LastActivity, Tick);
        {board_temps, Temps} ->
            put(board_temps, Temps),
            write_climate(),
            controller(Awake, LastActivity, Tick);
        {Port, {exit_status, Status}} ->
            log(io_lib:format("evwatch port ~p exited with status ~p", [Port, Status])),
            controller(Awake, LastActivity, Tick);
        %% Timer-driven so a steady stream of input or motion can't starve it.
        tick ->
            erlang:send_after(?TICK_MS, self(), tick),
            Idle = now_ms() - LastActivity,
            NewAwake = case Awake andalso Idle > ?IDLE_TIMEOUT_MS of
                true ->
                    sleep_screen(),
                    log("sleeping after idle timeout"),
                    false;
                false -> Awake
            end,
            %% Re-assert every second, as nlclient does: the panel goes dark after
            %% ~60s without backlight writes, and this also corrects any stale value.
            set_backlight(case NewAwake of true -> 113; false -> 0 end),
            NewTick = case NewAwake of
                true ->
                    case Tick rem 10 of
                        0 -> get(spinner) ! redraw;
                        _ -> ok
                    end,
                    Tick + 1;
                false -> Tick
            end,
            controller(NewAwake, LastActivity, NewTick)
    end.

main() ->
    log("starting dial_control (port-based input watch)"),
    put(angle, 0),
    put(spinner, spinner:start()),
    put(clicker, clicker:start()),
    open_watch_port("/dev/input/event1"),
    open_watch_port("/dev/input/event2"),
    backplate:start(self()),
    get(spinner) ! redraw,
    wake(),
    erlang:send_after(?TICK_MS, self(), tick),
    controller(true, now_ms(), 1).
