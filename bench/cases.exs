# Struct literals cannot name modules defined in the same script.
session =
  struct!(Bench.Session,
    user_id: 42,
    roles: [:admin, :editor],
    expires_at: 1_790_000_000,
    meta: %{"ip" => "203.0.113.7", "agent" => "Mozilla/5.0", "locale" => "en-GB"}
  )

commands =
  for i <- 1..100 do
    case rem(i, 4) do
      0 -> :ping
      1 -> {:put, "key:#{i}", :binary.copy("v", 64)}
      2 -> {:delete, "key:#{i}"}
      3 -> {:incr, "counter:#{i}", rem(i, 100)}
    end
  end

users = for i <- 1..100, do: struct!(Bench.User, id: i, name: "User #{i}", email: "user#{i}@example.com")

cases = [
  {"session struct", Bench.Session.codec(), session},
  {"1,000 integers", Bench.Codecs.ints(), Enum.map(1..1_000, &(&1 * 7_919))},
  {"16 x 1 KiB binaries", Bench.Codecs.blobs(), Map.new(1..16, &{"k#{&1}", :binary.copy("x", 1024)})},
  {"16 x 1 KiB UTF-8 text", Bench.Codecs.texts(), Map.new(1..16, &{"k#{&1}", :binary.copy("plain ascii text ", 64)})},
  {"4,000 integers in 0..100 (STRING_EXT)", Bench.Codecs.percents(), Enum.map(1..4_000, &rem(&1, 101))},
  {"100 union commands", Bench.Codecs.commands(), commands},
  {"100 derived structs", Bench.Codecs.users(), users}
]

cases
