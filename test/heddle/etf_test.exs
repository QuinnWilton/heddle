defmodule Heddle.ETFTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Heddle.ETF

  defp body(term, opts \\ []) do
    <<131, rest::binary>> = :erlang.term_to_binary(term, opts)
    rest
  end

  describe "read_atom_name/1" do
    test "reads every atom tag and transcodes Latin-1 to UTF-8" do
      assert {:ok, "ok", ""} = ETF.read_atom_name(body(:ok))
      assert {:ok, "ok", ""} = ETF.read_atom_name(body(:ok, minor_version: 1))
      assert {:ok, "é", ""} = ETF.read_atom_name(<<115, 1, 233>>)
      assert {:ok, "é", ""} = ETF.read_atom_name(<<100, 0, 1, 233>>)
      assert {:ok, "é", ""} = ETF.read_atom_name(<<119, 2, 195, 169>>)
      assert {:ok, "é", ""} = ETF.read_atom_name(<<118, 0, 2, 195, 169>>)
    end

    test "rejects names the VM would refuse" do
      assert {:error, :invalid_atom} = ETF.read_atom_name(<<119, 1, 255>>)
      long = String.duplicate("a", 256)
      assert {:error, :invalid_atom} = ETF.read_atom_name(<<118, 256::16, long::binary>>)
      assert {:error, :invalid_atom} = ETF.read_atom_name(<<100, 256::16, long::binary>>)
      chars = String.duplicate("é", 255)
      assert {:ok, ^chars, ""} = ETF.read_atom_name(<<118, byte_size(chars)::16, chars::binary>>)
    end

    test "distinguishes truncation from other terms" do
      assert {:error, :unexpected_eof} = ETF.read_atom_name(<<119, 5, "ab">>)
      assert {:error, :unexpected_eof} = ETF.read_atom_name(<<118, 0>>)
      assert {:error, :unexpected} = ETF.read_atom_name(<<97, 1>>)
      assert {:error, :unexpected_eof} = ETF.read_atom_name(<<>>)
    end
  end

  describe "integers" do
    property "encode_integer/1 matches term_to_binary/1" do
      check all i <-
                  StreamData.one_of([
                    StreamData.integer(),
                    StreamData.map(
                      StreamData.integer(0..2000),
                      &(Integer.pow(2, &1) * if(rem(&1, 2) == 0, do: 1, else: -1))
                    )
                  ]) do
        assert ETF.encode_integer(i) == body(i)
        assert {:ok, ^i, ""} = ETF.read_integer(ETF.encode_integer(i), ETF.max_bignum_bytes())
      end
    end

    test "accepts non-minimal bignums within the bound" do
      assert {:ok, 5, ""} = ETF.read_integer(<<110, 2, 0, 5, 0>>, 2)
      assert {:error, :too_large} = ETF.read_integer(<<110, 2, 0, 5, 0>>, 1)
      assert {:ok, 0, ""} = ETF.read_integer(<<110, 1, 1, 0>>, 1)
    end

    test "caps bignums at the VM's limit" do
      n = ETF.max_bignum_bytes() + 1
      assert {:error, :too_large} = ETF.read_integer(<<111, n::32, 0>>, n)
    end

    test "big_bytes_for/2 bounds by the range" do
      assert ETF.big_bytes_for(0, 255) == 1
      assert ETF.big_bytes_for(-(2 ** 64), 0) == 9
      assert ETF.big_bytes_for(nil, 5) == ETF.max_bignum_bytes()
    end
  end

  describe "atom_spellings/1" do
    test "lists Latin-1 spellings only for names that have one" do
      assert length(ETF.atom_spellings(:é)) == 4
      assert length(ETF.atom_spellings(:日本)) == 2
    end

    test "every spelling decodes to the atom in the VM" do
      for atom <- [:ok, :é, :日本], spelling <- ETF.atom_spellings(atom) do
        assert :erlang.binary_to_term(<<131, spelling::binary>>) == atom
      end
    end
  end

  describe "describe/1" do
    test "quotes at most 64 bytes" do
      assert {:binary, "abc"} = ETF.describe(body("abc"))
      long = :binary.copy("x", 100)
      assert {:binary, {:truncated, prefix, 100}} = ETF.describe(body(long))
      assert byte_size(prefix) == 64
    end

    test "names forms Heddle never accepts" do
      assert :fun = ETF.describe(body(fn -> :ok end))
      assert :pid = ETF.describe(body(self()))
      assert :reference = ETF.describe(body(make_ref()))
      assert :export = ETF.describe(body(&Enum.map/2))
    end
  end
end
