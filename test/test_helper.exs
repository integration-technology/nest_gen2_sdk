# Text tests need the host's textrender: `mix nest_gen2.host` builds it.
renderer = Path.join([System.user_home!(), ".nest_gen2_sdk", "bin", "textrender"])
ExUnit.start(exclude: if(File.exists?(renderer), do: [], else: [:host_renderer]))
