defmodule NestGen2.Host.Viewer do
  @moduledoc """
  The Nest's screen in a browser, when running on a computer (`target: :host`).

  Serves `http://localhost:4000` with OTP's own web server (`:inets`), so it
  adds no dependencies. The page shows the screen as it is drawn and turns the
  ring with the mouse wheel or the arrow keys; click or press Space/Enter to
  press it. Buttons give a double click, a long press and someone walking past.

  Config: `host_viewer` (default true), `host_viewer_port` (4000),
  `host_viewer_ip` (`{127, 0, 0, 1}`: only this computer; from another one, use
  an SSH tunnel, see `docs/host.md`) and `host_viewer_controls` (true; false
  makes it watch-only, for showing the app publicly: no buttons, every POST
  refused, and replies a cache in front may keep for a second).

  Endpoints, for scripts and tests too:

    * `GET /screen.png` — the screen
    * `GET /state` — `awake` or `asleep`
    * `POST /turn?deg=N`, `/step?dir=cw|ccw`, `/click`, `/double_click`,
      `/long_press`, `/motion`, `/climate?t=21.5&h=45`
  """
  require Record

  # httpd's request record (inets/include/httpd.hrl, not always installed).
  Record.defrecordp(:mod, [
    :init_data,
    :data,
    :socket_type,
    :socket,
    :config_db,
    :method,
    :absolute_uri,
    :request_uri,
    :http_version,
    :request_line,
    :parsed_header,
    :entity_body,
    :connection
  ])

  @doc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc false
  def start_link do
    {:ok, _} = Application.ensure_all_started(:inets)
    root = Path.join(System.tmp_dir!(), "nest_gen2_viewer") |> tap(&File.mkdir_p!/1)
    port = NestGen2.Config.get(:host_viewer_port)
    ip = NestGen2.Config.get(:host_viewer_ip)

    result =
      :inets.start(
        :httpd,
        [
          port: port,
          bind_address: ip,
          server_name: ~c"nest_gen2",
          server_root: String.to_charlist(root),
          document_root: String.to_charlist(root),
          modules: [__MODULE__]
        ],
        :stand_alone
      )

    with {:ok, _pid} <- result do
      require Logger
      Logger.info("nest_gen2: the screen is at http://#{:inet.ntoa(ip)}:#{port}")
    end

    result
  end

  # httpd's callback: one request, one reply.
  @doc false
  def unquote(:do)(request) do
    method = mod(request, :method)
    uri = request |> mod(:request_uri) |> to_string() |> URI.parse()
    params = URI.decode_query(uri.query || "")

    {status, type, body} =
      try do
        respond(to_string(method), uri.path, params)
      rescue
        error in ArgumentError -> {400, "text/plain", Exception.message(error)}
        error -> {500, "text/plain", Exception.message(error)}
      end

    body = IO.iodata_to_binary(body)

    # Watch-only, every viewer sees the same screen, so a cache in front (a CDN)
    # can answer them all for a second.
    cache = if controls?() or status != 200, do: ~c"no-store", else: ~c"public, max-age=1"

    head = [
      code: status,
      content_type: String.to_charlist(type),
      content_length: Integer.to_charlist(byte_size(body)),
      cache_control: cache
    ]

    {:proceed, [response: {:response, head, body}]}
  end

  @doc false
  def respond(method, path, params) do
    if method == "POST" and not controls?(),
      do: {403, "text/plain", "this viewer is watch-only"},
      else: route(method, path, params)
  end

  defp controls?, do: NestGen2.Config.get(:host_viewer_controls)

  @doc false
  def route("GET", "/", _), do: {200, "text/html; charset=utf-8", page(controls?())}
  def route("GET", "/screen.png", _), do: {200, "image/png", screen_png()}

  def route("GET", "/state", _),
    do: {200, "text/plain", if(NestGen2.Power.awake?(), do: "awake", else: "asleep")}

  def route("POST", "/turn", %{"deg" => deg}), do: act(fn -> NestGen2.Host.turn(number(deg)) end)

  def route("POST", "/step", %{"dir" => dir}) when dir in ["cw", "ccw"],
    do: act(fn -> NestGen2.Host.step(String.to_existing_atom(dir)) end)

  def route("POST", "/click", _), do: act(&NestGen2.Host.click/0)
  def route("POST", "/double_click", _), do: act(&NestGen2.Host.double_click/0)
  def route("POST", "/long_press", _), do: act(&NestGen2.Host.long_press/0)
  def route("POST", "/motion", _), do: act(fn -> NestGen2.Host.motion() end)

  def route("POST", "/climate", %{"t" => t, "h" => h}),
    do: act(fn -> NestGen2.Host.climate(number(t), number(h)) end)

  def route(_method, _path, _params), do: {404, "text/plain", "not found"}

  defp act(fun) do
    fun.()
    {204, "text/plain", ""}
  end

  defp number(text) do
    case Float.parse(text) do
      {n, ""} -> n
      _ -> raise ArgumentError, "not a number: #{inspect(text)}"
    end
  end

  # Every open page fetches the screen about once a second, so it's encoded
  # only when it changes. shortcut: :persistent_term makes each update cost a
  # scan of all processes; fine at a screen change every few seconds, move it to
  # ETS if an app redraws many times a second.
  defp screen_png do
    image = NestGen2.Display.snapshot()

    case :persistent_term.get(__MODULE__, nil) do
      {data, png} when data == image.data ->
        png

      _ ->
        png = NestGen2.Image.to_png(image)
        :persistent_term.put(__MODULE__, {image.data, png})
        png
    end
  end

  @controls_html """
  <div class="controls">
    <button data-post="/step?dir=ccw">⟲ Step</button>
    <button data-post="/click">Press</button>
    <button data-post="/step?dir=cw">Step ⟳</button>
    <button data-post="/double_click">Double click</button>
    <button data-post="/long_press">Long press</button>
    <button data-post="/motion">Walk past</button>
  </div>
  <div class="hint">Scroll on the ring, drag it round, or use ← → to turn it; click it or press Space to press.</div>
  """

  @controls_js """
  dial.title = "Scroll or drag to turn; click to press";
  dial.style.cursor = "grab";
  const post = (path) => fetch(path, { method: "POST" }).then(refresh);
  document.querySelectorAll("[data-post]").forEach(b => b.onclick = () => post(b.dataset.post));

  let wheel = 0;
  dial.addEventListener("wheel", (e) => {
    e.preventDefault();
    wheel += e.deltaY;
    if (Math.abs(wheel) >= 40) { post("/step?dir=" + (wheel > 0 ? "cw" : "ccw")); wheel = 0; }
  }, { passive: false });
  // Dragging round the ring turns it by the angle swept; a click without
  // turning presses it.
  let last = null, swept = 0, pending = 0, sending = false;
  const angleAt = (e) => {
    const r = dial.getBoundingClientRect();
    return Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2)) * 180 / Math.PI;
  };
  const flush = () => {
    if (sending || Math.abs(pending) < 1) return;
    const deg = pending; pending = 0; sending = true;
    fetch("/turn?deg=" + deg.toFixed(1), { method: "POST" }).finally(() => { sending = false; flush(); refresh(); });
  };
  dial.addEventListener("pointerdown", (e) => { last = angleAt(e); swept = 0; dial.setPointerCapture(e.pointerId); });
  dial.addEventListener("pointermove", (e) => {
    if (last === null) return;
    const a = angleAt(e);
    let d = a - last;
    if (d > 180) d -= 360; else if (d < -180) d += 360;
    last = a; swept += Math.abs(d); pending += d; flush();
  });
  dial.addEventListener("pointerup", () => { last = null; if (swept < 3) post("/click"); });
  document.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") post("/step?dir=cw");
    else if (e.key === "ArrowLeft") post("/step?dir=ccw");
    else if (e.key === " " || e.key === "Enter") { e.preventDefault(); post("/click"); }
  });
  """

  defp page(controls?) do
    {controls_html, controls_js, refresh_ms, stamp, asleep_text} =
      if controls?,
        do:
          {@controls_html, @controls_js, 400, "Date.now()",
           "Screen asleep (as on the Nest): press or walk past to wake"},
        else: {"", "", 1000, "Math.floor(Date.now() / 1000)", "Screen asleep (as on the Nest)"}

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Nest screen</title>
    <style>
      :root { color-scheme: light dark; --bg: #f2f2f2; --fg: #222; --muted: #777; --btn: #fff; --line: #ccc; }
      @media (prefers-color-scheme: dark) { :root { --bg: #161616; --fg: #eee; --muted: #999; --btn: #262626; --line: #3a3a3a; } }
      body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.4 system-ui, sans-serif;
             display: flex; flex-direction: column; align-items: center; gap: 20px; padding: 32px 16px; }
      /* Explicit width and height (not aspect-ratio) so it stays round in a flex column in
         every browser: the screen inside is exactly 320 px, as on the Nest. */
      .bezel { --d: min(380px, 90vw); width: var(--d); height: var(--d); flex: none;
               border-radius: 50%; padding: calc(var(--d) * 30 / 380); box-sizing: border-box;
               background: radial-gradient(circle at 30% 25%, #e8e8e8, #8a8a8a 60%, #5a5a5a);
               box-shadow: 0 10px 30px rgba(0,0,0,.35); touch-action: none; }
      .glass { width: 100%; height: 100%; border-radius: 50%; background: #000; overflow: hidden; }
      .glass img { width: 100%; height: 100%; display: block; object-fit: contain; transition: opacity .4s; }
      .asleep img { opacity: .08; }
      .controls { display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; max-width: 420px; }
      button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid var(--line);
               background: var(--btn); color: var(--fg); cursor: pointer; }
      button:active { transform: translateY(1px); }
      .hint, .state { color: var(--muted); font-size: 13px; text-align: center; }
    </style>
    </head>
    <body>
      <div class="bezel" id="dial">
        <div class="glass" id="glass"><img id="screen" src="/screen.png" alt="The Nest's screen"></div>
      </div>
      <div class="state" id="state">&nbsp;</div>
    #{controls_html}
    <script>
      const dial = document.getElementById("dial");
    #{controls_js}
      const img = document.getElementById("screen");
      const glass = document.getElementById("glass");
      const state = document.getElementById("state");
      let busy = false;
      function refresh() {
        if (busy) return;
        busy = true;
        const next = new Image();
        next.onload = () => { img.src = next.src; busy = false; };
        next.onerror = () => { busy = false; };
        // Watch-only, the same URL for every viewer within a second, so a cache can share it.
        const t = #{stamp};
        next.src = "/screen.png?t=" + t;
        fetch("/state?t=" + t).then(r => r.text()).then(s => {
          glass.classList.toggle("asleep", s === "asleep");
          state.textContent = s === "asleep" ? "#{asleep_text}" : "Screen awake";
        }).catch(() => { state.textContent = "Not connected"; });
      }
      setInterval(refresh, #{refresh_ms});
      refresh();
    </script>
    </body>
    </html>
    """
  end
end
