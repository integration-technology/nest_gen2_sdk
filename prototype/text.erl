-module(text).
-export([start/0, render/5]).

%% Renders text with the textrender port helper from a font already on the
%% device, so no font data ships with the SDK.
%%
%%   text:render("22.1°C", 36, {255,255,255}, {16#43,16#5f,16#a6},
%%               "/nestlabs/share/fonts/AkkuratNest-Bold.ttf")
%%     -> {ok, Width, Height, BGRXPixels} | {error, Reason}

-define(TEXTRENDER, "/media/scratch/.nest_gen2_sdk/textrender").
-define(TIMEOUT_MS, 5000).

start() ->
    case whereis(nest_text) of
        undefined ->
            Pid = spawn(fun init/0),
            register(nest_text, Pid),
            Pid;
        Pid -> Pid
    end.

render(Text, SizePx, {FR, FG, FB}, {BR, BG, BB}, FontPath) ->
    Path = unicode:characters_to_binary(FontPath),
    Req = <<SizePx:16, FR, FG, FB, BR, BG, BB, (byte_size(Path)):16, Path/binary,
            (unicode:characters_to_binary(Text))/binary>>,
    Ref = make_ref(),
    nest_text ! {render, self(), Ref, Req},
    receive {Ref, Reply} -> Reply
    after ?TIMEOUT_MS -> {error, timeout}
    end.

init() ->
    loop(open()).

open() ->
    open_port({spawn_executable, ?TEXTRENDER}, [{packet, 4}, binary, exit_status]).

loop(Port) ->
    receive
        {render, From, Ref, Req} ->
            port_command(Port, Req),
            receive
                {Port, {data, <<0, W:16, H:16, Pixels/binary>>}} -> From ! {Ref, {ok, W, H, Pixels}}, loop(Port);
                {Port, {data, <<1, Msg/binary>>}} -> From ! {Ref, {error, Msg}}, loop(Port);
                {Port, {exit_status, _}} -> From ! {Ref, {error, renderer_exited}}, loop(open())
            end;
        {Port, {exit_status, _}} ->
            loop(open())
    end.
