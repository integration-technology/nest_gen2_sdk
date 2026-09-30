-module(spinner).
-export([start/0]).

%% Owns /dev/fb0 and draws the screen double-buffered, like the stock UI: fb0 is
%% made 320x640 (two pages); every change is drawn on the hidden page, which is
%% then shown by writing the pan offset. Each page keeps a list of regions it is
%% missing (fox, text or all), so only those are written before its next flip.
%%
%% The fox uses 360 pre-rendered 140x140 frames (1 degree each); the text is
%% Akkurat Bold glyphs pre-rendered on the disc blue.

-define(BACKGROUND, "/media/scratch/.nest_gen2_sdk/test.raw").
-define(FRAMES, "/media/scratch/.nest_gen2_sdk/fox_frames.raw").
-define(GLYPHS, "/media/scratch/.nest_gen2_sdk/glyphs.raw").
-define(FB_SYSFS, "/sys/class/graphics/fb0").
-define(WIDTH, 320).
-define(PAGE_BYTES, (?WIDTH * ?WIDTH * 4)).
-define(BOX, 140).
-define(ORIGIN, 90).
-define(FRAME_BYTES, (?BOX * ?BOX * 4)).
-define(BAND_X, 60).
-define(BAND_Y, 240).
-define(BAND_W, 200).
-define(BLUE, <<16#a6, 16#5f, 16#43, 0>>).

start() ->
    spawn(fun init/0).

init() ->
    ok = file:write_file(?FB_SYSFS ++ "/virtual_size", "320,640"),
    {ok, Frames} = file:open(?FRAMES, [read, raw, binary]),
    {ok, Fb} = file:open("/dev/fb0", [read, write, raw, binary]),
    {ok, Background} = file:read_file(?BACKGROUND),
    S = #{fb => Fb, frames => Frames, background => Background, glyphs => load_glyphs(),
          angle => 0, text => "", visible => visible_page(),
          damage => #{0 => [all], 1 => [all]}},
    loop(present(S)).

loop(S) ->
    receive
        {angle, A} ->
            Latest = latest_angle(A),
            case frame_index(Latest) =:= frame_index(maps:get(angle, S)) of
                true -> loop(S#{angle := Latest});
                false -> loop(present(damage(fox, S#{angle := Latest})))
            end;
        {text, Text} ->
            case Text =:= maps:get(text, S) of
                true -> loop(S);
                false -> loop(present(damage(text, S#{text := Text})))
            end;
        redraw ->
            loop(present(damage(all, S)))
    end.

%% Both pages are now missing this region.
damage(Region, #{damage := D} = S) ->
    Add = fun(L) -> lists:usort([Region | L]) end,
    S#{damage := #{0 => Add(maps:get(0, D)), 1 => Add(maps:get(1, D))}}.

%% Bring the hidden page up to date, then show it.
present(#{fb := Fb, visible := V, damage := D} = S) ->
    Hidden = 1 - V,
    Base = Hidden * ?PAGE_BYTES,
    case maps:get(Hidden, D) of
        [] -> ok;
        Regions ->
            case lists:member(all, Regions) of
                true -> write_chunks(Fb, Base, compose(maps:get(background, S),
                                                       fox_rows(S) ++ text_rows(S)));
                false -> ok = file:pwrite(Fb, shift(Base, lists:append([rows(R, S) || R <- Regions])))
            end
    end,
    ok = file:write_file(?FB_SYSFS ++ "/pan", ["0,", integer_to_list(Hidden * ?WIDTH)]),
    S#{visible := Hidden, damage := D#{Hidden := []}}.

rows(fox, S) -> fox_rows(S);
rows(text, S) -> text_rows(S).

shift(Base, Rows) -> [{Off + Base, Bin} || {Off, Bin} <- Rows].

visible_page() ->
    {ok, Pan} = file:read_file(?FB_SYSFS ++ "/pan"),
    [_, Y] = string:split(string:trim(binary_to_list(Pan)), ","),
    list_to_integer(Y) div ?WIDTH.

latest_angle(A) ->
    receive {angle, Newer} -> latest_angle(Newer)
    after 0 -> A
    end.

frame_index(Angle) ->
    ((round(Angle) rem 360) + 360) rem 360.

%% Page-relative rows of the fox box at the current angle.
fox_rows(#{frames := Frames, angle := Angle}) ->
    {ok, Bin} = file:pread(Frames, frame_index(Angle) * ?FRAME_BYTES, ?FRAME_BYTES),
    [{((?ORIGIN + R) * ?WIDTH + ?ORIGIN) * 4, binary:part(Bin, R * ?BOX * 4, ?BOX * 4)}
     || R <- lists:seq(0, ?BOX - 1)].

%% Page-relative rows of the text band, text centred; unknown characters skipped.
text_rows(#{glyphs := Glyphs, text := Text}) ->
    {_, H, _} = maps:get($0, Glyphs),
    Gs = [maps:get(C, Glyphs) || C <- Text, maps:is_key(C, Glyphs)],
    TextW = lists:sum([W || {W, _, _} <- Gs]),
    Left = max(0, (?BAND_W - TextW) div 2),
    Right = max(0, ?BAND_W - TextW - Left),
    [{((?BAND_Y + R) * ?WIDTH + ?BAND_X) * 4,
      binary:part(iolist_to_binary([blue(Left),
                                    [binary:part(P, R * W * 4, W * 4) || {W, _, P} <- Gs],
                                    blue(Right)]), 0, ?BAND_W * 4)}
     || R <- lists:seq(0, H - 1)].

blue(N) -> binary:copy(?BLUE, N).

%% glyphs.raw: repeated <<Char:8, Width:16/little, Height:16/little, BGRX pixels>>.
load_glyphs() ->
    {ok, Bin} = file:read_file(?GLYPHS),
    parse_glyphs(Bin, #{}).

parse_glyphs(<<>>, Acc) -> Acc;
parse_glyphs(<<Char, W:16/little, H:16/little, Rest/binary>>, Acc) ->
    Size = W * H * 4,
    <<Pixels:Size/binary, More/binary>> = Rest,
    parse_glyphs(More, Acc#{Char => {W, H, Pixels}}).

%% Overlays page-relative {Offset, Bin} patches onto the background.
compose(Background, Patches) ->
    {Parts, Pos} = lists:foldl(
        fun({Off, Bin}, {Acc, P}) ->
            {[Bin, binary:part(Background, P, Off - P) | Acc], Off + byte_size(Bin)}
        end, {[], 0}, lists:keysort(1, Patches)),
    Tail = binary:part(Background, Pos, byte_size(Background) - Pos),
    iolist_to_binary(lists:reverse([Tail | Parts])).

%% Full-page writes must be chunked to <=4KB on this omapfb driver.
write_chunks(_Fb, _Off, <<>>) -> ok;
write_chunks(Fb, Off, Data) ->
    Take = min(4096, byte_size(Data)),
    <<Chunk:Take/binary, Rest/binary>> = Data,
    ok = file:pwrite(Fb, Off, Chunk),
    write_chunks(Fb, Off + Take, Rest).
