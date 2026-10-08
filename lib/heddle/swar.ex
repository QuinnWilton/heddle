defmodule Heddle.SWAR do
  @moduledoc false
  # Byte scans seven bytes at a time (SIMD within a register).
  #
  # Words are 56 bits so they stay small integers: on a 64-bit VM an integer
  # past 60 bits is a heap bignum, and allocating one per step would cost
  # more than the scan saves.

  import Bitwise

  @high 0x80808080808080
  @ones 0x01010101010101

  @doc """
  Whether `bin` is valid UTF-8, as `String.valid?/1` decides.

  ASCII prefixes are skipped eight words (56 bytes) at a time, which on
  ASCII text beats `String.valid?(bin, :fast_ascii)`, and an ASCII tail
  shorter than a word is checked byte by byte; the first word with a high
  bit set hands the rest to the VM's own UTF-8 validator
  (`:unicode.characters_to_binary/3`), which on non-ASCII text is three
  times faster than `String.valid?/1` and accepts exactly the same
  binaries.
  """
  @spec utf8?(binary()) :: boolean()
  def utf8?(<<a::56, b::56, c::56, d::56, e::56, f::56, g::56, h::56, rest::binary>>)
      when band(bor(bor(bor(a, b), bor(c, d)), bor(bor(e, f), bor(g, h))), @high) == 0,
      do: utf8?(rest)

  def utf8?(<<w::56, rest::binary>>) when band(w, @high) == 0, do: utf8?(rest)
  def utf8?(<<b, rest::binary>>) when b < 128, do: utf8?(rest)
  def utf8?(<<>>), do: true
  def utf8?(bin), do: is_binary(:unicode.characters_to_binary(bin, :utf8, :utf8))

  @doc """
  Whether every byte of `bin` lies in `lo..hi`.

  Uses the classic has-less / has-more word tests, which need `hi <= 127`
  and `lo <= 128`; other ranges are checked a byte at a time.
  """
  @spec bytes_in?(binary(), 0..255, 0..255) :: boolean()
  def bytes_in?(bin, lo, hi) when hi <= 127 and lo <= 128 and lo <= hi,
    do: words_in(bin, lo, hi, lo * @ones, (127 - hi) * @ones)

  def bytes_in?(bin, lo, hi), do: bytes_in(bin, lo, hi)

  # For a word whose bytes are all below 128 and hi <= 127, adding 127 - hi
  # to each byte cannot carry, and sets a byte's high bit exactly when the
  # byte exceeds hi; or-ing in the word catches bytes already 128 or more.
  # Then (w | high) - lo per byte cannot borrow (lo <= 128), and keeps a
  # byte's high bit exactly when the byte is at least lo.
  defp words_in(<<w::56, rest::binary>>, lo, hi, sub, add)
       when band(bor(w, w + add), @high) == 0 do
    if band(bor(w, @high) - sub, @high) == @high,
      do: words_in(rest, lo, hi, sub, add),
      else: false
  end

  defp words_in(<<_::56, _::binary>>, _lo, _hi, _sub, _add), do: false
  defp words_in(bin, lo, hi, _sub, _add), do: bytes_in(bin, lo, hi)

  defp bytes_in(<<b, rest::binary>>, lo, hi) when b >= lo and b <= hi, do: bytes_in(rest, lo, hi)
  defp bytes_in(<<>>, _lo, _hi), do: true
  defp bytes_in(_, _lo, _hi), do: false
end
