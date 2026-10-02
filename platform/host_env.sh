# Source this before building anything for the Nest:   . platform/host_env.sh
#
# The Nest runs OTP 26 / Elixir 1.17, so .beam files must be built with that
# toolchain. Hex gets its own MIX_HOME *and* MIX_ARCHIVES: tools like mise set
# MIX_ARCHIVES to the default Elixir's folder, which would otherwise let this
# toolchain overwrite (or trip over) the everyday hex archive.
NEST_BUILD=${NEST_BUILD:-$HOME/build/nest-repurpose}
export PATH="$NEST_BUILD/otp-native/otp_src_26.2.5.13/bin:$NEST_BUILD/elixir-build/elixir/bin:$HOME/x-tools/arm-nest-linux-musleabi/bin:$PATH"
export MIX_HOME="$HOME/.mix-otp26"
export MIX_ARCHIVES="$HOME/.mix-otp26/archives"
export HEX_HOME="$HOME/.hex-otp26"
