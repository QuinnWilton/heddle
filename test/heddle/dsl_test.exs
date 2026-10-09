defmodule Heddle.DSLTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "imported constructors" do
    test "build the same codecs as the qualified ones" do
      import Heddle.DSL

      assert list(enum([:a, :b]), max: 4) == Heddle.list(Heddle.enum([:a, :b]), max: 4)

      assert map_of(binary(), integer(min: 0)) ==
               Heddle.map_of(Heddle.binary(), Heddle.integer(min: 0))

      assert one_of([null(), float()]) == Heddle.one_of([Heddle.null(), Heddle.float()])
    end

    test "build sequences outside defcodec, run by the interpreter" do
      import Heddle.DSL

      codec =
        tuple_seq do
          n <- integer(min: 0, max: 3) <~ field(:n)
          items <- list(boolean(), max: n) <~ field(:items)
          pure %{n: n, items: items}
        end

      value = %{n: 2, items: [true, false]}
      assert {:ok, iodata} = Heddle.encode(codec, value)
      assert Heddle.decode(codec, IO.iodata_to_binary(iodata)) == {:ok, value}
      assert {:error, _} = Heddle.encode(codec, %{n: 1, items: [true, false]})
    end
  end

  describe "inside defcodec" do
    @tag :tmp_dir
    test "imported calls carry source spans into compile errors", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overlap.ex")

      File.write!(path, """
      defmodule Heddle.Test.DSLOverlap do
        use Heddle.Schema
        defcodec c do
          one_of([
            integer(max: 0),
            integer(min: 1)
          ])
        end
      end
      """)

      message = Exception.message(assert_raise(CompileError, fn -> Code.compile_file(path) end))
      assert message =~ "H001"
      assert message =~ "5 │"
      assert message =~ "6 │"
    end

    test "a finite bind over imported constructors compiles without a warning" do
      source = """
      defmodule Heddle.Test.DSLFinite do
        use Heddle.Schema

        defcodec c do
          tuple_seq do
            v <- integer(min: 1, max: 2) <~ field(:v)
            body <- (case v do
                       1 -> binary(max_size: 4)
                       2 -> list(integer(), max: 2)
                     end) <~ field(:body)
            pure %{v: v, body: body}
          end
        end
      end
      """

      stderr =
        capture_io(:stderr, fn -> send(self(), {:compiled, Code.compile_string(source)}) end)

      assert stderr == ""
      assert_received {:compiled, [{module, _}]}
      assert Heddle.lint(module.c()) == []
      round_trip!(module.c(), [%{v: 1, body: "abc"}, %{v: 2, body: [1, 2]}])
    end

    test "qualified Heddle.DSL calls compile like Heddle calls" do
      [{module, _}] =
        Code.compile_string("""
        defmodule Heddle.Test.DSLQualified do
          use Heddle.Schema
          alias Heddle.DSL

          defcodec c do
            DSL.list(Heddle.DSL.integer(min: 0), max: 3)
          end
        end
        """)

      round_trip!(module.c(), [[], [0, 7, 9]])
      assert Heddle.decode(module.c(), :erlang.term_to_binary([0, 7, 9])) == {:ok, [0, 7, 9]}

      assert {:error, %Heddle.DecodeError{}} =
               Heddle.decode(module.c(), :erlang.term_to_binary([-1]))
    end

    test "a codec defined earlier wins over the constructor of the same name" do
      [{module, _}] =
        Code.compile_string("""
        defmodule Heddle.Test.DSLShadow do
          use Heddle.Schema

          defcodec null do
            atom(:none)
          end

          defcodec c do
            list(null(), max: 2)
          end
        end
        """)

      round_trip!(module.c(), [[:none, :none]])
      assert {:error, _} = Heddle.decode(module.c(), :erlang.term_to_binary([nil]))
    end
  end

  defp round_trip!(codec, values) do
    for value <- values do
      bin = IO.iodata_to_binary(Heddle.encode!(codec, value))
      assert Heddle.decode(codec, bin) == {:ok, value}
    end
  end
end
