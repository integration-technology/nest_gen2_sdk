-module(nest_hello).
-export([run/0]).

run() ->
    io:format("Hello from the Nest thermostat! OTP ~s~n", [erlang:system_info(otp_release)]),
    show_logo(),
    halt().

show_logo() ->
    {ok, Data} = file:read_file("/media/scratch/.nest_gen2_sdk/test.raw"),
    {ok, Fb} = file:open("/dev/fb0", [write, binary, raw]),
    write_chunks(Fb, Data),
    file:close(Fb),
    io:format("logo written to framebuffer, ~p bytes~n", [byte_size(Data)]).

%% Same 4KB chunk constraint discovered earlier this session — a single
%% large write() corrupts the first ~9KB of the frame on this omapfb driver.
write_chunks(_Fb, <<>>) ->
    ok;
write_chunks(Fb, Data) ->
    ChunkSize = 4096,
    Size = byte_size(Data),
    Take = min(ChunkSize, Size),
    <<Chunk:Take/binary, Rest/binary>> = Data,
    ok = file:write(Fb, Chunk),
    write_chunks(Fb, Rest).
