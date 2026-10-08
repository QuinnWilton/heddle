defmodule Heddle.ETF do
  @moduledoc """
  Low-level reading and writing of external term format pieces.

  Both the interpreter and compiled codecs call these functions, so the two
  backends read atoms, integers and lengths identically and report the same
  `found` description for the same bytes. Every reader takes a binary that
  starts at a term's tag byte.
  """

  import Bitwise

  @version 131

  @small_integer 97
  @integer 98
  @small_big 110
  @large_big 111
  @new_float 70
  @float_ext 99
  @atom_utf8 118
  @small_atom_utf8 119
  @atom_latin1 100
  @small_atom_latin1 115
  @binary 109
  @bit_binary 77
  @small_tuple 104
  @large_tuple 105
  @nil_ext 106
  @string 107
  @list 108
  @map 116

  @max_atom_chars 255

  # The VM refuses a bignum whose declared magnitude exceeds this many bytes
  # (2^22 - 64 bits on 64-bit builds), even when the high bytes are zero.
  @max_bignum_bytes 524_280

  @preview_bytes 64

  @typedoc "A short, bounded description of the term at some offset, for errors."
  @type found :: term()

  @typedoc "Why a reader refused the bytes in front of it."
  @type read_error :: :unexpected | :unexpected_eof | :invalid_atom | :too_large

  @doc "The version byte that starts every external term."
  @spec version() :: 131
  def version, do: @version

  @doc "The largest bignum magnitude, in bytes, that the VM decodes."
  @spec max_bignum_bytes() :: pos_integer()
  def max_bignum_bytes, do: @max_bignum_bytes

  @doc "The largest atom, in characters, the VM accepts."
  @spec max_atom_chars() :: pos_integer()
  def max_atom_chars, do: @max_atom_chars

  @doc "The atom tags, in the order compiled clauses list them."
  @spec atom_tags() :: [byte()]
  def atom_tags, do: [@small_atom_utf8, @atom_utf8, @small_atom_latin1, @atom_latin1]

  @doc "The integer tags."
  @spec integer_tags() :: [byte()]
  def integer_tags, do: [@small_integer, @integer, @small_big, @large_big]

  @doc "The list tags: `NIL_EXT`, `STRING_EXT` and `LIST_EXT`."
  @spec list_tags() :: [byte()]
  def list_tags, do: [@nil_ext, @string, @list]

  ## Atoms

  @doc """
  Reads an atom's name, in UTF-8, without creating the atom.

  Names written with the Latin-1 tags are transcoded, so the same atom reads
  as the same binary whichever tag carried it. A name the VM would refuse
  (invalid UTF-8, or more than 255 characters) is `:invalid_atom`.
  """
  @spec read_atom_name(binary()) :: {:ok, String.t(), binary()} | {:error, read_error()}
  def read_atom_name(<<@small_atom_utf8, len, rest::binary>>), do: utf8_name(rest, len)
  def read_atom_name(<<@atom_utf8, len::16, rest::binary>>), do: utf8_name(rest, len)
  def read_atom_name(<<@small_atom_latin1, len, rest::binary>>), do: latin1_name(rest, len)
  def read_atom_name(<<@atom_latin1, len::16, rest::binary>>), do: latin1_name(rest, len)

  def read_atom_name(<<tag, _::binary>>) when tag in [118, 119, 100, 115],
    do: {:error, :unexpected_eof}

  def read_atom_name(<<_, _::binary>>), do: {:error, :unexpected}
  def read_atom_name(<<>>), do: {:error, :unexpected_eof}

  defp utf8_name(rest, len) do
    case rest do
      <<name::binary-size(^len), rest::binary>> ->
        if String.valid?(name) and codepoints(name) <= @max_atom_chars,
          do: {:ok, name, rest},
          else: {:error, :invalid_atom}

      _ ->
        {:error, :unexpected_eof}
    end
  end

  defp latin1_name(rest, len) do
    case rest do
      <<name::binary-size(^len), rest::binary>> when len <= @max_atom_chars ->
        {:ok, :unicode.characters_to_binary(name, :latin1, :utf8), rest}

      <<_::binary-size(^len), _::binary>> ->
        {:error, :invalid_atom}

      _ ->
        {:error, :unexpected_eof}
    end
  end

  @doc "Counts the code points of a valid UTF-8 binary."
  @spec codepoints(binary()) :: non_neg_integer()
  def codepoints(bin), do: codepoints(bin, 0)

  defp codepoints(<<b, rest::binary>>, n) when (b &&& 0xC0) == 0x80, do: codepoints(rest, n)
  defp codepoints(<<_, rest::binary>>, n), do: codepoints(rest, n + 1)
  defp codepoints(<<>>, n), do: n

  @doc """
  Whether a binary is a name an atom can have: valid UTF-8 of at most 255
  characters.
  """
  @spec valid_atom_name?(term()) :: boolean()
  def valid_atom_name?(name) when is_binary(name),
    do: String.valid?(name) and codepoints(name) <= @max_atom_chars

  def valid_atom_name?(_), do: false

  @doc "Encodes an atom name with the shortest UTF-8 atom tag."
  @spec encode_atom_name(String.t()) :: binary()
  def encode_atom_name(name) when byte_size(name) <= 255,
    do: <<@small_atom_utf8, byte_size(name), name::binary>>

  def encode_atom_name(name), do: <<@atom_utf8, byte_size(name)::16, name::binary>>

  @doc "Encodes an atom."
  @spec encode_atom(atom()) :: binary()
  def encode_atom(atom) when is_atom(atom), do: encode_atom_name(Atom.to_string(atom))

  @doc """
  Every byte sequence that encodes `atom`, one per accepted tag.

  The Latin-1 spellings are present only for names that have one.
  """
  @spec atom_spellings(atom()) :: [binary()]
  def atom_spellings(atom) when is_atom(atom) do
    name = Atom.to_string(atom)
    len = byte_size(name)

    utf8 = [<<@small_atom_utf8, len, name::binary>>, <<@atom_utf8, len::16, name::binary>>]

    case :unicode.characters_to_binary(name, :utf8, :latin1) do
      latin1 when is_binary(latin1) ->
        llen = byte_size(latin1)

        utf8 ++
          [
            <<@small_atom_latin1, llen, latin1::binary>>,
            <<@atom_latin1, llen::16, latin1::binary>>
          ]

      _ ->
        utf8
    end
  end

  ## Integers

  @doc """
  Reads an integer written with any integer tag.

  `max_big_bytes` bounds a bignum's declared magnitude; it is checked before
  the magnitude is read, and never exceeds what the VM accepts.
  """
  @spec read_integer(binary(), non_neg_integer()) ::
          {:ok, integer(), binary()} | {:error, read_error()}
  def read_integer(<<@small_integer, i, rest::binary>>, _), do: {:ok, i, rest}
  def read_integer(<<@integer, i::signed-32, rest::binary>>, _), do: {:ok, i, rest}

  def read_integer(<<@small_big, n, sign, rest::binary>>, max) when sign in [0, 1],
    do: read_big(rest, n, sign, max)

  def read_integer(<<@large_big, n::32, sign, rest::binary>>, max) when sign in [0, 1],
    do: read_big(rest, n, sign, max)

  def read_integer(<<tag, _::binary>>, _) when tag in [97, 98, 110, 111],
    do: {:error, :unexpected_eof}

  def read_integer(<<_, _::binary>>, _), do: {:error, :unexpected}
  def read_integer(<<>>, _), do: {:error, :unexpected_eof}

  defp read_big(rest, n, sign, max) do
    cond do
      n > max or n > @max_bignum_bytes ->
        {:error, :too_large}

      byte_size(rest) < n ->
        {:error, :unexpected_eof}

      true ->
        <<magnitude::little-unsigned-size(^n)-unit(8), rest::binary>> = rest
        {:ok, if(sign == 0, do: magnitude, else: -magnitude), rest}
    end
  end

  @doc """
  The number of magnitude bytes the largest value in `min..max` needs, or the
  VM's cap when the range is unbounded.
  """
  @spec big_bytes_for(integer() | nil, integer() | nil) :: non_neg_integer()
  def big_bytes_for(min, max) when is_integer(min) and is_integer(max),
    do: max(magnitude_bytes(abs(min)), magnitude_bytes(abs(max)))

  def big_bytes_for(_, _), do: @max_bignum_bytes

  defp magnitude_bytes(0), do: 0
  defp magnitude_bytes(n), do: div(bit_size(:binary.encode_unsigned(n)), 8)

  @doc "Encodes an integer with the smallest tag that holds it."
  @spec encode_integer(integer()) :: binary()
  def encode_integer(i) when i >= 0 and i <= 255, do: <<@small_integer, i>>

  def encode_integer(i) when i >= -2_147_483_648 and i <= 2_147_483_647,
    do: <<@integer, i::signed-32>>

  def encode_integer(i) do
    sign = if i < 0, do: 1, else: 0
    magnitude = :binary.encode_unsigned(abs(i), :little)
    n = byte_size(magnitude)

    if n <= 255,
      do: <<@small_big, n, sign, magnitude::binary>>,
      else: <<@large_big, n::32, sign, magnitude::binary>>
  end

  ## Floats, binaries, containers

  @doc "Encodes a float as `NEW_FLOAT_EXT`."
  @spec encode_float(float()) :: binary()
  def encode_float(f) when is_float(f), do: <<@new_float, f::float-64>>

  @doc "The header of a binary of `size` bytes."
  @spec binary_header(non_neg_integer()) :: binary()
  def binary_header(size), do: <<@binary, size::32>>

  @doc "The header of a tuple of `arity` elements."
  @spec tuple_header(non_neg_integer()) :: binary()
  def tuple_header(arity) when arity <= 255, do: <<@small_tuple, arity>>
  def tuple_header(arity), do: <<@large_tuple, arity::32>>

  @doc "The header of a map of `arity` pairs."
  @spec map_header(non_neg_integer()) :: binary()
  def map_header(arity), do: <<@map, arity::32>>

  @doc "The header of a proper list of `length` elements; its tail is `nil_ext/0`."
  @spec list_header(pos_integer()) :: binary()
  def list_header(length), do: <<@list, length::32>>

  @doc "`NIL_EXT`, the empty list."
  @spec nil_ext() :: binary()
  def nil_ext, do: <<@nil_ext>>

  @doc "A `STRING_EXT` holding `bytes`."
  @spec string_ext(binary()) :: binary()
  def string_ext(bytes) when byte_size(bytes) < 65_536,
    do: <<@string, byte_size(bytes)::16, bytes::binary>>

  ## Classification

  @typedoc """
  What the next term looks like, for choosing among `one_of` alternatives.

  Reading it consumes nothing and charges no budget.
  """
  @type class ::
          {:atom, String.t() | :invalid}
          | :integer
          | :float
          | :binary
          | :list
          | :map
          | {:tuple, non_neg_integer(), String.t() | nil}
          | :other

  @doc "Classifies the term at the front of `bin`."
  @spec classify(binary()) :: class()
  def classify(<<tag, _::binary>> = bin) when tag in [118, 119, 100, 115] do
    case read_atom_name(bin) do
      {:ok, name, _} -> {:atom, name}
      {:error, _} -> {:atom, :invalid}
    end
  end

  def classify(<<tag, _::binary>>) when tag in [97, 98, 110, 111], do: :integer
  def classify(<<@new_float, _::binary>>), do: :float
  def classify(<<@binary, _::binary>>), do: :binary
  def classify(<<tag, _::binary>>) when tag in [106, 107, 108], do: :list
  def classify(<<@map, _::binary>>), do: :map
  def classify(<<@small_tuple, n, rest::binary>>), do: {:tuple, n, first_name(rest)}
  def classify(<<@large_tuple, n::32, rest::binary>>), do: {:tuple, n, first_name(rest)}
  def classify(_), do: :other

  defp first_name(rest) do
    case read_atom_name(rest) do
      {:ok, name, _} -> name
      {:error, _} -> nil
    end
  end

  ## Descriptions

  @doc """
  Describes the term at the front of `bin` for an error message.

  The description quotes at most 64 bytes of input; a longer value is
  `{:truncated, prefix, byte_size}`.
  """
  @spec describe(binary()) :: found()
  def describe(<<>>), do: :eof
  def describe(<<@small_integer, i, _::binary>>), do: {:small_integer, i}
  def describe(<<@integer, i::signed-32, _::binary>>), do: {:integer, i}
  def describe(<<@small_big, n, _::binary>>), do: {:small_big, {:bytes, n}}
  def describe(<<@large_big, n::32, _::binary>>), do: {:large_big, {:bytes, n}}
  def describe(<<@new_float, f::float-64, _::binary>>), do: {:new_float, f}
  def describe(<<@new_float, _::64, _::binary>>), do: {:new_float, :not_finite}
  def describe(<<@float_ext, _::binary>>), do: :float_ext
  def describe(<<@small_atom_utf8, n, rest::binary>>), do: {:small_atom_utf8, preview(rest, n)}
  def describe(<<@atom_utf8, n::16, rest::binary>>), do: {:atom_utf8, preview(rest, n)}
  def describe(<<@small_atom_latin1, n, rest::binary>>), do: {:small_atom, preview(rest, n)}
  def describe(<<@atom_latin1, n::16, rest::binary>>), do: {:atom, preview(rest, n)}
  def describe(<<@binary, n::32, rest::binary>>), do: {:binary, preview(rest, n)}
  def describe(<<@bit_binary, n::32, _::binary>>), do: {:bit_binary, {:bytes, n}}
  def describe(<<@small_tuple, n, _::binary>>), do: {:small_tuple, n}
  def describe(<<@large_tuple, n::32, _::binary>>), do: {:large_tuple, n}
  def describe(<<@nil_ext, _::binary>>), do: :nil_ext
  def describe(<<@string, n::16, rest::binary>>), do: {:string, preview(rest, n)}
  def describe(<<@list, n::32, _::binary>>), do: {:list, n}
  def describe(<<@map, n::32, _::binary>>), do: {:map, n}
  def describe(<<80, _::binary>>), do: :compressed
  def describe(<<68, _::binary>>), do: :distribution_header
  def describe(<<82, _::binary>>), do: :atom_cache_ref
  def describe(<<tag, _::binary>>) when tag in [112, 117], do: :fun
  def describe(<<113, _::binary>>), do: :export
  def describe(<<121, _::binary>>), do: :local
  def describe(<<tag, _::binary>>) when tag in [88, 103], do: :pid
  def describe(<<tag, _::binary>>) when tag in [89, 102, 120], do: :port
  def describe(<<tag, _::binary>>) when tag in [90, 101, 114], do: :reference
  def describe(<<tag, _::binary>>), do: {:tag, tag}

  defp preview(rest, n) do
    available = min(n, byte_size(rest))

    if n <= @preview_bytes and available == n do
      binary_part(rest, 0, n)
    else
      {:truncated, binary_part(rest, 0, min(available, @preview_bytes)), n}
    end
  end
end
