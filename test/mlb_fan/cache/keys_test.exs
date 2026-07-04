defmodule MlbFan.Cache.KeysTest do
  use ExUnit.Case, async: true

  alias MlbFan.Cache.Keys

  test "params hash is stable regardless of key order or key type" do
    a = Keys.params_hash(%{"date" => "2026-07-02", "sportId" => 1})
    b = Keys.params_hash(%{sportId: 1, date: "2026-07-02"})
    assert a == b
  end

  test "different params produce different hashes" do
    refute Keys.params_hash(%{"date" => "2026-07-02"}) ==
             Keys.params_hash(%{"date" => "2026-07-03"})
  end

  test "value type coercion: 1 and \"1\" hash identically" do
    assert Keys.params_hash(%{"game_pk" => 1}) == Keys.params_hash(%{"game_pk" => "1"})
  end
end
