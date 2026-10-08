defmodule Heddle.CompilerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Heddle.Test.{CodecGen, Command, Env, Session, Team, User, UriCodecs}

  @large [max_bytes: 64 * 1_048_576, max_depth: 1_000, max_nodes: 10_000_000]

  defp bytes(codec, value), do: codec |> Heddle.encode!(value) |> IO.iodata_to_binary()

  defp agree!(codec, values, extra_bins \\ []) do
    bins = Enum.map(values, &bytes(codec, &1)) ++ extra_bins
    assert :ok = Heddle.Check.backends(codec, bins, @large)
    assert :ok = Heddle.Check.encoders(codec, values)

    for value <- values do
      assert {:ok, ^value} = Heddle.decode(codec, bytes(codec, value), @large)
    end
  end

  describe "examples from the design" do
    test "defschema" do
      agree!(Session.codec(), [
        %Session{user_id: 1, roles: [:admin], expires_at: 5},
        %Session{user_id: 9, roles: [], expires_at: 0, meta: %{"a" => "b"}}
      ])

      without_meta =
        :erlang.term_to_binary(%{__struct__: Session, user_id: 1, roles: [], expires_at: 1})

      assert {:ok, %Session{meta: %{}}} = Heddle.decode(Session.codec(), without_meta)
      assert :ok = Heddle.Check.differential(Session.codec(), [without_meta])
    end

    test "defunion" do
      agree!(Command.codec(), [:ping, {:put, "k", "v"}, {:delete, "k"}], [
        :erlang.term_to_binary({:get, "k"})
      ])
    end

    test "a finite bind expands per value" do
      agree!(Env.envelope(), [%{version: 1, body: "x"}, %{version: 2, body: {:put, "a", "b"}}])

      assert {:error, %Heddle.DecodeError{path: [2]}} =
               Heddle.decode(Env.envelope(), :erlang.term_to_binary({:envelope, 2, "x"}))
    end

    test "a parameter bind compiles once with the bound passed in" do
      agree!(Env.sized(), [%{n: 2, items: [1, 2]}, %{n: 0, items: []}], [
        :erlang.term_to_binary({3, [1, 2, 3, 4]})
      ])

      assert {:error, %Heddle.DecodeError{reason: :too_large, path: [1]}} =
               Heddle.decode(Env.sized(), :erlang.term_to_binary({3, [1, 2, 3, 4]}))

      assert {:error, %Heddle.EncodeError{reason: {:too_large, 2, 1}}} =
               Heddle.encode(Env.sized(), %{n: 1, items: [1, 2]})
    end

    test "recursion through self-reference and lazy" do
      agree!(Env.tree(), [:leaf, {:node, :leaf, 1, {:node, :leaf, 2, :leaf}}])
      agree!(Env.lazy_tree(), [nil, [nil, [nil]], []])
    end

    test "iso and refine with local captures" do
      agree!(Env.refined(), [{:n, 2}, {:n, -4}], [:erlang.term_to_binary(3)])
    end

    test "derived structs and module references" do
      agree!(Heddle.codec_for(User), [%User{id: 1, name: "a"}])
      team = %Team{name: "t", lead: %User{id: 1, name: "a"}, members: [%User{id: 2, name: "b"}]}
      agree!(Team.codec(), [team])
      assert Heddle.Codec.codec(%User{}) == Heddle.codec_for(User)
    end

    test "codecs for structs you don't own" do
      uri = %URI{scheme: :https, host: "example.com"}
      agree!(UriCodecs.uri_codec(), [uri, %{uri | scheme: {:unknown, "gopher"}}])
      agree!(UriCodecs.profile(), [%{homepage: uri}])
    end

    test "structs in different modules may name each other" do
      folder = %Heddle.Test.Folder{
        name: "root",
        files: [%Heddle.Test.File{name: "a", parent: nil}]
      }

      file = %Heddle.Test.File{name: "b", parent: folder}
      agree!(Heddle.Test.Folder.codec(), [folder])
      agree!(Heddle.Test.File.codec(), [file])
    end

    test "STRING_EXT fast paths fall back to the element decoder" do
      module = compile(quote(do: Heddle.list(Heddle.integer(min: 0, max: 100), max: 500)))
      ok = :erlang.term_to_binary(Enum.to_list(0..100))
      bad = :erlang.term_to_binary(Enum.to_list(0..100) ++ [101])
      assert {:ok, _} = Heddle.decode(module, ok)

      assert {:error, %Heddle.DecodeError{reason: :out_of_range, path: [101]}} =
               Heddle.decode(module, bad)

      assert :ok = Heddle.Check.backends(module, [ok, bad])
      assert :ok = Heddle.Check.backends(module, [ok], max_depth: 1)
      assert :ok = Heddle.Check.backends(module, [ok], max_nodes: 50)
    end

    test "compiled codecs expose their IR, summary and name" do
      assert %Heddle{node: {:struct, Session, :map, _}} = Session.__heddle_ir__(:codec)
      assert %{first: [:map]} = Session.__heddle_summary__(:codec)
      assert Env.__heddle_codecs__() == [:envelope, :sized, :tree, :lazy_tree, :refined]
    end
  end

  describe "compiled agrees with the interpreter" do
    property "on random codecs, valid and mutated bytes, both directions" do
      check all ast <- CodecGen.codec_ast(),
                runtime = CodecGen.eval(ast),
                values <-
                  StreamData.list_of(Heddle.Gen.from(runtime), min_length: 1, max_length: 4),
                flips <-
                  StreamData.list_of(
                    StreamData.tuple({StreamData.integer(0..200), StreamData.integer(0..255)}),
                    max_length: 6
                  ),
                max_runs: 60 do
        compiled = compile(ast)
        source = Macro.to_string(ast)

        bins = Enum.map(values, &bytes(runtime, &1))
        mutated = for bin <- bins, {i, b} <- flips, i < byte_size(bin), do: flip(bin, i, b)
        truncated = for bin <- bins, i <- [1, div(byte_size(bin), 2)], do: binary_part(bin, 0, i)
        corpus = bins ++ mutated ++ truncated

        assert :ok = Heddle.Check.backends(compiled, corpus, @large), source
        assert :ok = Heddle.Check.encoders(compiled, values), source

        for bin <- corpus do
          assert Heddle.decode(compiled, bin, @large) == Heddle.decode(runtime, bin, @large),
                 source
        end

        for value <- values do
          assert Heddle.encode(compiled, value) |> elem(1) |> IO.iodata_to_binary() ==
                   bytes(runtime, value),
                 source
        end
      end
    end
  end

  defp flip(bin, i, b) do
    <<pre::binary-size(^i), _, post::binary>> = bin
    <<pre::binary, b, post::binary>>
  end

  defp compile(ast) do
    module = Module.concat(Heddle.Test.Random, "M#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Heddle.Schema

          defcodec c do
            unquote(ast)
          end
        end
      end
    )

    module.c()
  end

  describe "compile errors" do
    defp compile_error(source) do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(source, "test/compile_error_fixture.ex")
        end

      Exception.message(error)
    end

    test "calling the module's own functions (H005)" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad1 do
          use Heddle.Schema
          def helper, do: Heddle.integer()
          defcodec c do
            Heddle.list(helper())
          end
        end
        """)

      assert message =~ "H005"
      assert message =~ "helper/0 cannot be called"
      assert message =~ "defcodec"
    end

    @tag :tmp_dir
    test "overlapping alternatives label both (H001)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overlap.ex")

      File.write!(path, """
        defmodule Heddle.Test.Bad2 do
          use Heddle.Schema
          defcodec c do
            Heddle.one_of([
              Heddle.integer(max: 0),
              Heddle.integer(min: 1)
            ])
          end
        end
      """)

      message = Exception.message(assert_raise(CompileError, fn -> Code.compile_file(path) end))
      assert message =~ "H001"
      assert message =~ "this alternative can start with an integer"
      assert message =~ "so can this earlier one"
      assert message =~ "5 │"
      assert message =~ "6 │"
    end

    test "a :__struct__ key (H003)" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad3 do
          use Heddle.Schema
          defcodec c do
            Heddle.map_of(Heddle.enum([:__struct__]), Heddle.integer())
          end
        end
        """)

      assert message =~ "H003"
      assert message =~ "Heddle.struct/2"
    end

    test "a module with no codec (H006)" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad4 do
          use Heddle.Schema
          defcodec c do
            Heddle.list(URI)
          end
        end
        """)

      assert message =~ "H006"
      assert message =~ "URI has no Heddle codec"
    end

    test "left recursion (H007)" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad5 do
          use Heddle.Schema
          defcodec c do
            Heddle.one_of([c(), Heddle.atom(:a)])
          end
        end
        """)

      assert message =~ "H007"
    end

    test "anonymous functions in @derive options (H008)" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad6 do
          @derive {Heddle.Codec, fields: [id: Heddle.refine(Heddle.integer(), fn x -> x > 0 end, :pos)]}
          defstruct [:id]
        end
        """)

      assert message =~ "H008"
    end

    test "unknown fields in @derive options" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad7 do
          @derive {Heddle.Codec, fields: [nope: Heddle.integer()]}
          defstruct [:id]
        end
        """)

      assert message =~ "no fields [:nope]"
    end

    test "malformed tuple_seq blocks" do
      message =
        compile_error("""
        defmodule Heddle.Test.Bad8 do
          use Heddle.Schema
          import Heddle.Syntax
          defcodec c do
            tuple_seq do
              x <- Heddle.integer()
            end
          end
        end
        """)

      assert message =~ "pure"
    end
  end

  describe "opaque binds" do
    test "warn at compile time and run in the interpreter" do
      source = """
      defmodule Heddle.Test.Opaque do
        use Heddle.Schema
        import Heddle.Syntax

        defcodec c do
          tuple_seq do
            k <- Heddle.binary(max_size: 8) <~ field(:k)
            v <- pick(k) <~ field(:v)
            pure %{k: k, v: v}
          end
        end

        def pick("int"), do: Heddle.integer()
        def pick(_), do: Heddle.binary()
      end
      """

      stderr =
        capture_io(:stderr, fn ->
          [{module, _}] = Code.compile_string(source)
          send(self(), {:compiled, module})
        end)

      assert stderr =~ "W001"
      assert_received {:compiled, module}
      codec = module.c()
      agree!(codec, [%{k: "int", v: 5}, %{k: "s", v: "x"}])
      assert [%Pentiment.Report{code: "W001"}] = Heddle.lint(codec)
    end
  end
end
