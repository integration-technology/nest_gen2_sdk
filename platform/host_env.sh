# Source this before building anything for the Nest:   . platform/host_env.sh
#
# The Nest runs OTP 26 / Elixir 1.17, so .beam files must be built with that
# toolchain: OTP 27 or later produces code OTP 26 can't load.
#
# Where the toolchain comes from, in order:
#   1. NEST_OTP_BIN / NEST_ELIXIR_BIN, if set (folders holding erl / elixir)
#   2. a native build under NEST_BUILD (how the SDK itself is developed)
#   3. whatever `erl` and `elixir` are on PATH, e.g. from mise or asdf:
#        mise use erlang@26.2.5 elixir@1.17.3-otp-26
#
# Hex gets its own MIX_HOME *and* MIX_ARCHIVES: tools like mise set
# MIX_ARCHIVES to the default Elixir's folder, which would otherwise let this
# toolchain overwrite (or trip over) the everyday hex archive.
NEST_BUILD=${NEST_BUILD:-$HOME/build/nest-repurpose}
if [ -n "$NEST_OTP_BIN" ]; then
  PATH="$NEST_OTP_BIN:$NEST_ELIXIR_BIN:$PATH"
elif [ -x "$NEST_BUILD/otp-native/otp_src_26.2.5.13/bin/erl" ]; then
  PATH="$NEST_BUILD/otp-native/otp_src_26.2.5.13/bin:$NEST_BUILD/elixir-build/elixir/bin:$PATH"
fi
# Only needed to rebuild the SDK's native helpers (c_src/); apps never need it.
if [ -d "$HOME/x-tools/arm-nest-linux-musleabi/bin" ]; then
  PATH="$HOME/x-tools/arm-nest-linux-musleabi/bin:$PATH"
fi
export PATH
export MIX_HOME="$HOME/.mix-otp26"
export MIX_ARCHIVES="$HOME/.mix-otp26/archives"
export HEX_HOME="$HOME/.hex-otp26"

# Succeeds when erl is OTP 26 and elixir is 1.17; otherwise says what to install.
nest_toolchain_ok() {
  otp=$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' 2>/dev/null)
  ex=$(elixir -e 'IO.write(System.version())' 2>/dev/null)
  case "$otp/$ex" in
    26/1.17.*) return 0 ;;
  esac
  echo "Building for the Nest needs OTP 26 and Elixir 1.17 on this computer; found OTP '${otp:-none}', Elixir '${ex:-none}'." >&2
  echo "Install them, for example:  mise use erlang@26.2.5 elixir@1.17.3-otp-26" >&2
  return 1
}
