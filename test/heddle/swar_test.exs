defmodule Heddle.SWARTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Heddle.SWAR

  property "utf8?/1 agrees with String.valid?/1" do
    check all prefix <- StreamData.string(:ascii, max_length: 40),
              middle <-
                StreamData.one_of([
                  StreamData.string(:utf8, max_length: 20),
                  StreamData.binary(max_length: 20)
                ]),
              suffix <- StreamData.string(:ascii, max_length: 40),
              max_runs: 1_000 do
      bin = prefix <> middle <> suffix
      assert SWAR.utf8?(bin) == String.valid?(bin)
    end
  end

  test "utf8?/1 rejects surrogates and overlong forms after an ASCII prefix" do
    refute SWAR.utf8?("abcdefghijklmn" <> <<0xED, 0xA0, 0x80>>)
    refute SWAR.utf8?("abcdefghijklmn" <> <<0xC0, 0x80>>)
    assert SWAR.utf8?("abcdefghijklmn" <> "é")
  end

  property "bytes_in?/3 agrees with a byte-by-byte check" do
    check all bin <- StreamData.binary(max_length: 64),
              lo <- StreamData.integer(0..255),
              hi <- StreamData.integer(lo..255),
              max_runs: 2_000 do
      assert SWAR.bytes_in?(bin, lo, hi) ==
               Enum.all?(:binary.bin_to_list(bin), &(&1 >= lo and &1 <= hi))
    end
  end

  property "bytes_in?/3 on bytes clustered at the bounds" do
    check all lo <- StreamData.integer(0..127),
              hi <- StreamData.integer(lo..127),
              bytes <-
                StreamData.list_of(
                  StreamData.member_of([max(lo - 1, 0), lo, hi, min(hi + 1, 255), 127, 128]),
                  max_length: 30
                ),
              max_runs: 2_000 do
      bin = :binary.list_to_bin(bytes)
      assert SWAR.bytes_in?(bin, lo, hi) == Enum.all?(bytes, &(&1 >= lo and &1 <= hi))
    end
  end
end
