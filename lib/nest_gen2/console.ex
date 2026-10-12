defmodule NestGen2.Console do
  @moduledoc false
  # The kernel's text console is bound to the framebuffer, and like any Linux
  # console it blanks the screen after 10 minutes without *keyboard* input
  # (consoleblank=600). On the Nest only the button counts as a keyboard: the
  # dial and the motion sensor don't. So after 10 minutes the screen went dark
  # whatever the SDK's power policy said, even with an idle timeout of
  # :infinity, and only a press brought it back (the kernel logs
  # "display ID: ..." as it re-initialises the panel).
  #
  # The console's own escape sequences turn that off: ESC[9;0] sets the blank
  # interval to never, ESC[14;0] the powerdown interval to never, and ESC[13]
  # un-blanks the screen now.

  @tty "/dev/tty1"

  @doc "Stops the console blanking the screen, and un-blanks it if it already has."
  def never_blank, do: write("\e[9;0]\e[14;0]\e[13]")

  @doc "Un-blanks the screen if the console has blanked it."
  def unblank, do: write("\e[13]")

  defp write(seq) do
    case File.write(@tty, seq) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end
end
