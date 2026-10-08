defmodule HeddleTest do
  use ExUnit.Case, async: true

  alias Heddle.{CodecError, DecodeError, EncodeError}

  defp t2b(term, opts \\ []), do: :erlang.term_to_binary(term, opts)
  defp enc!(codec, value), do: codec |> Heddle.encode!(value) |> IO.iodata_to_binary()
  defp error(codec, bin, opts \\ []), do: elem(Heddle.decode(codec, bin, opts), 1)

  describe "atoms" do
    test "literals accept every atom tag and nothing else" do
      codec = Heddle.atom(:ok)
      assert {:ok, :ok} = Heddle.decode(codec, t2b(:ok))
      assert {:ok, :ok} = Heddle.decode(codec, t2b(:ok, minor_version: 1))
      assert {:ok, :ok} = Heddle.decode(codec, <<131, 118, 0, 2, "ok">>)

      assert %DecodeError{reason: :unexpected, found: {:small_atom_utf8, "error"}} =
               error(codec, t2b(:error))
    end

    test "Latin-1 literals match their Latin-1 spelling" do
      assert {:ok, :é} = Heddle.decode(Heddle.atom(:é), <<131, 115, 1, 233>>)
    end

    test "enums never intern unknown names" do
      codec = Heddle.enum([:http, :https], unknown: :keep)
      name = "heddle_never_an_atom_#{System.unique_integer([:positive])}"
      bin = <<131, 119, byte_size(name), name::binary>>
      assert {:ok, {:unknown, ^name}} = Heddle.decode(codec, bin)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert enc!(codec, {:unknown, name}) == bin
    end

    test "rejecting enums report the set" do
      assert %DecodeError{reason: :unexpected, expected: [atom: :a, atom: :b]} =
               error(Heddle.enum([:a, :b]), t2b(:c))
    end

    test "encoding {:unknown, name} for a member of the set fails" do
      codec = Heddle.enum([:http], unknown: :keep)

      assert {:error, %EncodeError{reason: {:known_name, "http"}}} =
               Heddle.encode(codec, {:unknown, "http"})

      assert {:error, %EncodeError{reason: {:invalid_atom_name, _}}} =
               Heddle.encode(codec, {:unknown, <<255>>})

      assert {:error, %EncodeError{reason: {:invalid_atom_name, _}}} =
               Heddle.encode(codec, {:unknown, String.duplicate("a", 256)})
    end

    test "existing_atom looks names up and never creates them" do
      assert {:ok, :ok} = Heddle.decode(Heddle.existing_atom(), t2b(:ok))
      name = "heddle_missing_#{System.unique_integer([:positive])}"
      bin = <<131, 119, byte_size(name), name::binary>>
      assert %DecodeError{reason: :unknown_atom} = error(Heddle.existing_atom(), bin)
    end

    test "invalid atom names are rejected" do
      assert %DecodeError{reason: :invalid_atom} =
               error(Heddle.existing_atom(), <<131, 119, 1, 255>>)

      assert %DecodeError{reason: :invalid_atom} = error(Heddle.atom(:a), <<131, 119, 1, 255>>)
    end
  end

  describe "integers" do
    test "range checks" do
      codec = Heddle.integer(min: 1, max: 10)
      assert {:ok, 5} = Heddle.decode(codec, t2b(5))

      assert %DecodeError{reason: :out_of_range, expected: [{:integer, 1, 10}]} =
               error(codec, t2b(11))

      assert {:error, %EncodeError{reason: {:out_of_range, 0}}} = Heddle.encode(codec, 0)
    end

    test "bignum size is bounded by the range before reading" do
      huge = <<131, 111, 100_000::32, 0>> <> :binary.copy(<<1>>, 100_000)
      assert %DecodeError{reason: :too_large} = error(Heddle.integer(min: 0, max: 2 ** 64), huge)
      assert {:ok, _} = Heddle.decode(Heddle.integer(), huge)
    end

    test "bignums past the VM's limit are rejected" do
      n = Heddle.ETF.max_bignum_bytes() + 1
      bin = <<131, 111, n::32, 0>> <> :binary.copy(<<1>>, n)
      assert %DecodeError{reason: :too_large} = error(Heddle.integer(), bin, max_bytes: 2 * n)
    end
  end

  describe "floats" do
    test "NEW_FLOAT_EXT only" do
      assert {:ok, 1.5} = Heddle.decode(Heddle.float(), t2b(1.5))
      assert {:ok, -0.0} = Heddle.decode(Heddle.float(), t2b(-0.0))

      assert %DecodeError{reason: :unexpected, found: :float_ext} =
               error(Heddle.float(), t2b(1.5, minor_version: 0))
    end

    test "NaN and infinities are rejected" do
      assert %DecodeError{reason: :invalid_float} =
               error(Heddle.float(), <<131, 70, 0x7FF8000000000000::64>>)

      assert %DecodeError{reason: :invalid_float} =
               error(Heddle.float(), <<131, 70, 0x7FF0000000000000::64>>)
    end
  end

  describe "binaries" do
    test "size and UTF-8 checks" do
      codec = Heddle.binary(max_size: 3, utf8: true)
      assert {:ok, "abc"} = Heddle.decode(codec, t2b("abc"))
      assert %DecodeError{reason: :too_large} = error(codec, t2b("abcd"))
      assert %DecodeError{reason: :invalid_utf8} = error(codec, t2b(<<255>>))
      assert {:error, %EncodeError{reason: {:too_large, 4, 3}}} = Heddle.encode(codec, "abcd")
    end

    test "a declared length past the input is rejected before reading" do
      assert %DecodeError{reason: :unexpected_eof, offset: 1} =
               error(Heddle.binary(), <<131, 109, 255, 255, 255, 255, 1>>)
    end

    test "binaries are copied by default" do
      bin = t2b(:binary.copy("x", 100))
      {:ok, copied} = Heddle.decode(Heddle.binary(), bin)
      {:ok, referenced} = Heddle.decode(Heddle.binary(), bin, binaries: :ref)
      assert :binary.referenced_byte_size(copied) == 100
      assert :binary.referenced_byte_size(referenced) == byte_size(bin)
    end
  end

  describe "lists" do
    test "STRING_EXT is read wherever the element codec takes its integers" do
      assert {:ok, [1, 2, 3]} =
               Heddle.decode(Heddle.list(Heddle.integer(min: 0, max: 1000)), t2b([1, 2, 3]))

      assert {:ok, ~c"héllo"} = Heddle.decode(Heddle.charlist(), t2b(~c"héllo"))

      assert %DecodeError{reason: :out_of_range, path: [1], offset: 5, found: {:small_integer, 2}} =
               error(Heddle.list(Heddle.integer(max: 1)), t2b([1, 2, 3]))

      assert %DecodeError{reason: :unexpected, path: [0]} =
               error(Heddle.list(Heddle.binary()), t2b([1]))
    end

    test "byte lists are written as STRING_EXT, as term_to_binary does" do
      codec = Heddle.list(Heddle.integer())
      assert enc!(codec, [1, 2, 3]) == t2b([1, 2, 3])
      assert enc!(codec, [1, 256]) == t2b([1, 256])
      assert enc!(codec, []) == t2b([])
    end

    test "bounds and proper tails" do
      codec = Heddle.list(Heddle.integer(), max: 2)
      assert %DecodeError{reason: :too_large} = error(codec, t2b([1, 2, 3]))

      assert %DecodeError{reason: :improper_list} =
               error(Heddle.list(Heddle.integer()), t2b([1 | 2]))

      assert %DecodeError{reason: :unexpected_eof} =
               error(Heddle.list(Heddle.integer()), <<131, 108, 0, 0, 0, 9, 97, 1, 106>>)
    end
  end

  describe "maps" do
    setup do
      codec = Heddle.map(required: [id: Heddle.integer()], optional: [name: Heddle.binary()])
      %{codec: codec}
    end

    test "optional keys may be absent", %{codec: codec} do
      assert {:ok, %{id: 1}} = Heddle.decode(codec, t2b(%{id: 1}))
      assert {:ok, %{id: 1, name: "x"}} = Heddle.decode(codec, t2b(%{id: 1, name: "x"}))
    end

    test "key errors", %{codec: codec} do
      assert %DecodeError{reason: :missing_key, expected: [key: :id]} =
               error(codec, t2b(%{name: "x"}))

      assert %DecodeError{reason: :unknown_key} = error(codec, t2b(%{id: 1, other: 2}))
      dup = <<131, 116, 0, 0, 0, 2, 119, 2, "id", 97, 1, 119, 2, "id", 97, 2>>
      assert %DecodeError{reason: :duplicate_key, offset: 12} = error(codec, dup)
    end

    test ":__struct__ is never accepted outside struct layouts", %{codec: codec} do
      assert_raise CodecError, ~r/H003/, fn ->
        Heddle.map(required: [__struct__: Heddle.existing_atom()])
      end

      assert_raise CodecError, ~r/H003/, fn ->
        Heddle.map_of(Heddle.enum([:__struct__, :a]), Heddle.integer())
      end

      injected = t2b(%{__struct__: URI, id: 1})
      assert %DecodeError{reason: :unknown_key} = error(codec, injected)

      any = Heddle.map_of(Heddle.existing_atom(), Heddle.existing_atom())
      assert %DecodeError{reason: :struct_key} = error(any, t2b(%{__struct__: URI}))
      assert {:error, %EncodeError{reason: :struct_key}} = Heddle.encode(any, %URI{})
    end

    test "map_of keys must decode uniquely" do
      codec = Heddle.map_of(Heddle.enum([:a], unknown: :keep), Heddle.integer())
      dup = <<131, 116, 0, 0, 0, 2, 100, 0, 1, 233, 97, 1, 119, 2, 195, 169, 97, 2>>
      assert %DecodeError{reason: :duplicate_key} = error(codec, dup)
    end

    test "encoding sorts keys by their encoded bytes" do
      codec = Heddle.map_of(Heddle.integer(), Heddle.integer())
      value = Map.new(1..40, &{&1, &1})
      assert enc!(codec, value) == enc!(codec, value |> Enum.reverse() |> Map.new())
      assert {:ok, ^value} = Heddle.decode(codec, enc!(codec, value))
    end
  end

  describe "structs" do
    test "map layout matches __struct__ as a literal and fills defaults" do
      codec =
        Heddle.struct(Heddle.Test.Point,
          fields: [x: Heddle.integer(), y: {Heddle.integer(), default: 7}]
        )

      bin = t2b(%{__struct__: Heddle.Test.Point, x: 1})
      assert {:ok, %Heddle.Test.Point{x: 1, y: 7, cache: :unset}} = Heddle.decode(codec, bin)

      assert %DecodeError{reason: :unexpected, path: [:__struct__]} =
               error(codec, t2b(%{__struct__: Heddle.Test.Box, x: 1}))

      assert %DecodeError{reason: :missing_key, expected: [key: :__struct__]} =
               error(codec, t2b(%{x: 1}))
    end

    test "the encoder writes every serialized field" do
      codec =
        Heddle.struct(Heddle.Test.Point,
          fields: [x: Heddle.integer(), y: {Heddle.integer(), default: 7}]
        )

      point = %Heddle.Test.Point{x: 1, y: 7, cache: :ignored}

      assert :erlang.binary_to_term(enc!(codec, point)) == %{
               __struct__: Heddle.Test.Point,
               x: 1,
               y: 7
             }

      assert {:ok, %Heddle.Test.Point{x: 1, y: 7, cache: :unset}} =
               Heddle.decode(codec, enc!(codec, point))
    end

    test "tuple layout with a tag" do
      codec =
        Heddle.struct(Heddle.Test.Point,
          as: :tuple,
          tag: :pt,
          fields: [x: Heddle.integer(), y: Heddle.integer()]
        )

      assert enc!(codec, %Heddle.Test.Point{x: 1, y: 2}) == t2b({:pt, 1, 2})
      assert {:ok, %Heddle.Test.Point{x: 1, y: 2}} = Heddle.decode(codec, t2b({:pt, 1, 2}))
    end

    test "unknown fields are rejected when the codec is built" do
      assert_raise CodecError, ~r/no fields \[:nope\]/, fn ->
        Heddle.struct(Heddle.Test.Point, fields: [nope: Heddle.integer()])
      end
    end
  end

  describe "one_of" do
    test "overlapping FIRST sets are rejected" do
      assert_raise CodecError, ~r/H001/, fn ->
        Heddle.one_of([Heddle.integer(max: 0), Heddle.integer(min: 1)])
      end

      assert_raise CodecError, ~r/H001/, fn ->
        Heddle.one_of([Heddle.atom(:a), Heddle.existing_atom()])
      end
    end

    test "overlapping value shapes are rejected" do
      assert_raise CodecError, ~r/H002/, fn ->
        Heddle.one_of([
          Heddle.enum([:a], unknown: :keep),
          Heddle.tagged(:unknown, Heddle.binary())
        ])
      end
    end

    test "tagged tuples dispatch on arity and tag" do
      codec =
        Heddle.one_of([
          Heddle.atom(:ping),
          Heddle.tagged(:get, Heddle.binary()),
          Heddle.tuple([Heddle.atom(:put), Heddle.binary(), Heddle.binary()])
        ])

      assert {:ok, {:put, "k", "v"}} = Heddle.decode(codec, t2b({:put, "k", "v"}))
      assert {:ok, {:get, "k"}} = Heddle.decode(codec, t2b({:get, "k"}))

      assert %DecodeError{
               reason: :unexpected,
               offset: 1,
               expected: [{:atom, :ping}, {:tuple, 2, :get}, {:tuple, 3, :put}]
             } = error(codec, t2b({:del, "k"}))
    end
  end

  describe "iso and refine" do
    test "iso maps values both ways" do
      codec =
        Heddle.iso(Heddle.binary(), &{:ok, String.to_integer(&1)}, &{:ok, Integer.to_string(&1)})

      assert enc!(codec, 42) == t2b("42")
      assert {:ok, 42} = Heddle.decode(codec, t2b("42"))
    end

    test "refine rejects values outside the predicate" do
      codec = Heddle.refine(Heddle.integer(), &(&1 > 0), :positive)
      assert %DecodeError{reason: {:refine, :positive}} = error(codec, t2b(-1))
      assert {:error, %EncodeError{reason: {:refine, :positive, -1}}} = Heddle.encode(codec, -1)
    end
  end

  describe "tuple_seq and bind" do
    setup do
      seq =
        Heddle.tuple_seq(
          Heddle.bind(Heddle.from(Heddle.integer(min: 0, max: 3), Heddle.field(:n)), fn n ->
            Heddle.bind(
              Heddle.from(Heddle.list(Heddle.integer(), max: n), Heddle.field(:items)),
              fn items ->
                Heddle.pure(%{n: n, items: items})
              end
            )
          end),
          tag: :seq
        )

      %{seq: seq}
    end

    test "later codecs depend on earlier values", %{seq: seq} do
      assert {:ok, %{n: 2, items: [1, 2]}} = Heddle.decode(seq, t2b({:seq, 2, [1, 2]}))
      assert %DecodeError{reason: :too_large, path: [2]} = error(seq, t2b({:seq, 1, [1, 2]}))
      assert enc!(seq, %{n: 2, items: [1, 2]}) == t2b({:seq, 2, [1, 2]})
    end

    test "the tuple's arity must match the steps", %{seq: seq} do
      assert %DecodeError{reason: :unexpected, offset: 1} =
               error(seq, t2b({:seq, 2, [1], :extra}))

      assert %DecodeError{reason: :unexpected, offset: 1} = error(seq, t2b({:seq, 2}))
    end

    test "each continuation is charged one node", %{seq: seq} do
      # root, tag, n, list, 2 elements = 6 terms, plus 2 continuations.
      assert {:ok, _} = Heddle.decode(seq, t2b({:seq, 2, [1, 2]}), max_nodes: 8)
      assert %DecodeError{reason: :max_nodes} = error(seq, t2b({:seq, 2, [1, 2]}), max_nodes: 7)
    end

    test "sequences and codecs do not mix" do
      assert_raise CodecError, ~r/H009/, fn -> Heddle.list(Heddle.pure(1)) end
      assert_raise CodecError, ~r/H009/, fn -> Heddle.tuple_seq(Heddle.integer()) end
    end
  end

  describe "limits" do
    test "max_bytes is checked before parsing" do
      assert %DecodeError{reason: :max_bytes, offset: 0} =
               error(Heddle.binary(), t2b("abcdef"), max_bytes: 4)
    end

    test "max_depth counts the root as depth 1" do
      codec = Heddle.list(Heddle.list(Heddle.integer()))
      assert {:ok, [[1]]} = Heddle.decode(codec, t2b([[1]]), max_depth: 3)

      assert %DecodeError{reason: :max_depth, path: [0, 0]} =
               error(codec, t2b([[1, 2]]), max_depth: 2)
    end

    test "max_nodes counts every term and is checked before allocation" do
      codec = Heddle.list(Heddle.integer())
      assert {:ok, _} = Heddle.decode(codec, t2b([1, 2, 3]), max_nodes: 4)

      assert %DecodeError{reason: :max_nodes, offset: 1} =
               error(codec, t2b([1, 2, 3]), max_nodes: 3)
    end

    test "Limits.meet/2 takes the tighter of each" do
      a = Heddle.Limits.new(max_depth: 4, binaries: :ref)
      b = Heddle.Limits.new(max_nodes: 5)
      assert %{max_depth: 4, max_nodes: 5, binaries: :copy} = Heddle.Limits.meet(a, b)
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn -> Heddle.decode(Heddle.integer(), t2b(1), max_depht: 3) end
    end
  end

  describe "always rejected" do
    test "funs, pids, refs, compressed terms, trailing bytes, bad versions" do
      any = Heddle.one_of([Heddle.integer(), Heddle.binary(), Heddle.existing_atom()])
      assert %DecodeError{reason: :unexpected, found: :fun} = error(any, t2b(fn -> :ok end))
      assert %DecodeError{reason: :unexpected, found: :pid} = error(any, t2b(self()))
      assert %DecodeError{reason: :unexpected, found: :reference} = error(any, t2b(make_ref()))

      assert %DecodeError{reason: :compressed} =
               error(any, t2b(:binary.copy("a", 1000), [:compressed]))

      assert %DecodeError{reason: :trailing_bytes, offset: 3} = error(any, t2b(1) <> <<0>>)
      assert %DecodeError{reason: :version} = error(any, <<130, 97, 1>>)
      assert %DecodeError{reason: :version, found: :eof} = error(any, <<>>)
    end

    # Other tests create atoms concurrently, so this checks the names
    # themselves rather than the global atom count.
    test "decoding never creates atoms" do
      names = for i <- 1..50, do: "heddle_fresh_#{i}_#{System.unique_integer([:positive])}"

      for name <- names do
        bin = <<131, 119, byte_size(name), name::binary>>
        assert {:ok, {:unknown, ^name}} = Heddle.decode(Heddle.enum([], unknown: :keep), bin)

        assert {:error, %DecodeError{reason: :unknown_atom}} =
                 Heddle.decode(Heddle.existing_atom(), bin)
      end

      for name <- names do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end
  end

  describe "errors" do
    test "found quotes at most 64 bytes" do
      %DecodeError{found: {:binary, {:truncated, prefix, 1000}}} =
        error(Heddle.binary(max_size: 1), t2b(:binary.copy("a", 1000)))

      assert byte_size(prefix) == 64
    end

    test "messages name the position" do
      message = Exception.message(error(Heddle.integer(), t2b(:a)))
      assert message =~ "offset 1"
      assert message =~ "unexpected"
    end
  end
end
