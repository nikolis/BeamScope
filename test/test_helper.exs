# The :distributed integration test spins up a real peer node (epmd + distribution) and
# is slower/environment-sensitive, so it is opt-in: run with `mix test --only distributed`.
ExUnit.start(exclude: [:distributed])
