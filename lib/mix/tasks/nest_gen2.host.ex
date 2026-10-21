defmodule Mix.Tasks.NestGen2.Host do
  @shortdoc "Sets up this computer to run a nest_gen2 app (target: :host)"
  @moduledoc """
  Builds the text renderer for this computer and checks the fonts, so an app
  can run here with `config :nest_gen2, target: :host` (see `docs/host.md`).

      mix nest_gen2.host

  Needs a C compiler (`cc`). The renderer goes to `~/.nest_gen2_sdk/bin`. The
  fonts are Nest's own and aren't shipped with the SDK: copy them from your
  Nest to `~/.nest_gen2_sdk/fonts` as `docs/host.md` shows.
  """
  use Mix.Task

  @fonts ~w(AkkuratNest-Bold.ttf AkkuratNest-Regular.ttf)

  @impl true
  def run(_args) do
    Mix.Task.run("compile")
    source = Path.join(sdk_dir(), "c_src")
    bin = NestGen2.Config.host_dir("bin")
    File.mkdir_p!(bin)
    out = Path.join(bin, "textrender")

    args = ["-O2", "-std=gnu17", "-o", out, Path.join(source, "textrender.c"), "-lm"]

    case System.cmd(System.get_env("CC", "cc"), args, stderr_to_stdout: true) do
      {_, 0} -> Mix.shell().info("built #{out}")
      {output, _} -> Mix.raise("building textrender failed:\n#{output}")
    end

    fonts = NestGen2.Config.host_dir("fonts")

    case Enum.reject(@fonts, &File.exists?(Path.join(fonts, &1))) do
      [] ->
        Mix.shell().info("fonts found in #{fonts}")

      missing ->
        Mix.shell().info("""
        missing fonts in #{fonts}: #{Enum.join(missing, ", ")}
        Copy them from your Nest (see docs/host.md), e.g.:
            mkdir -p #{fonts}
            for f in #{Enum.join(@fonts, " ")}; do
              ssh root@<nest-address> "cat /nestlabs/share/fonts/$f" > #{fonts}/$f
            done
        """)
    end
  end

  # The SDK's own checkout, or its copy under deps/ in an app.
  defp sdk_dir do
    case Mix.Project.deps_paths()[:nest_gen2] do
      nil -> File.cwd!()
      path -> path
    end
  end
end
