# Copies test data with every claim ID tagged, so it can be uploaded again.
#
#   elixir mock_data/retag.exs --tag N --out DIR SRC...
#
# Phoenix refuses a file it has already received and a claim it has already
# evaluated, so each test file can be uploaded once per database. This
# writes copies whose claim IDs end in "-N", which Phoenix treats as new
# claims in new files. Use a new N for each round of manual testing.
#
# Each SRC (a file or a directory) is copied to DIR/<its name>. Inside it:
#
#   * .json      every "claim_id" value gets the suffix (claims and
#                manifest.json expectations alike)
#   * .x12 .edi  every CLM01 (the claim ID) gets the suffix; a file without
#                an ISA header is copied unchanged
#   * .zip       its entries are retagged the same way, names kept
#   * .dsl       copied unchanged (rule files a manifest names)
#
# Other files (.exs, .md) are skipped. A copied suite with a manifest can be
# checked like the original:
#
#   mix run --no-start ../mock_data/verify.exs --suite DIR/mock_data
#
# Files with no claims (the error cases) are never recorded as submitted, so
# they can be uploaded again as they are; they are copied for completeness.

defmodule RetagTestData do
  @data_exts ~w(.json .x12 .edi .zip .dsl)

  def run(tag, out, sources) do
    Enum.each(sources, fn src ->
      src = Path.expand(src)
      unless File.exists?(src), do: raise("#{src} does not exist")
      dest = Path.join(out, Path.basename(src))

      files =
        if File.dir?(src),
          do: Path.wildcard(Path.join(src, "**/*")) |> Enum.reject(&File.dir?/1),
          else: [src]

      count =
        files
        |> Enum.filter(&(ext(&1) in @data_exts))
        |> Enum.map(fn file ->
          target = if File.dir?(src), do: Path.join(dest, Path.relative_to(file, src)), else: dest
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, retag(Path.basename(file), File.read!(file), tag))
        end)
        |> length()

      IO.puts("#{count} files: #{src} -> #{dest}")
    end)
  end

  def retag(name, content, tag) do
    case ext(name) do
      ".json" -> retag_json(content, tag)
      e when e in [".x12", ".edi"] -> retag_x12(content, tag)
      ".zip" -> retag_zip(content, tag)
      _ -> content
    end
  end

  defp ext(name), do: name |> Path.extname() |> String.downcase()

  # Text substitution keeps each file's layout exactly as it was.
  defp retag_json(content, tag) do
    Regex.replace(~r/("claim_id"\s*:\s*")((?:[^"\\]|\\.)+)(")/, content, "\\1\\2-#{tag}\\3")
  end

  # ISA is fixed width: the element separator is its 4th character and the
  # segment terminator follows ISA16 at position 105.
  defp retag_x12(<<"ISA", sep::binary-size(1), _::binary>> = content, tag) when byte_size(content) > 106 do
    term = binary_part(content, 105, 1)
    clm = Regex.compile!("^(\\s*CLM" <> Regex.escape(sep) <> ")([^" <> Regex.escape(sep <> term) <> "]+)")

    content
    |> String.split(term)
    |> Enum.map_join(term, &Regex.replace(clm, &1, "\\1\\2-#{tag}"))
  end

  defp retag_x12(content, _tag), do: content

  # Erlang's unzip turns an entry named ../escape.x12 into escape.x12, so the
  # names written back are the raw ones from the central directory (the
  # path-traversal test case depends on them).
  defp retag_zip(content, tag) do
    {:ok, entries} = :zip.unzip(content, [:memory])
    raw = raw_names(content)

    retagged =
      Enum.map(entries, fn {name, data} ->
        name = to_string(name)
        original = Enum.find(raw, name, &(&1 == name or String.ends_with?(&1, "/" <> name)))
        {String.to_charlist(original), retag(name, data, tag)}
      end)

    {:ok, {_, zip}} = :zip.create(~c"retagged.zip", retagged, [:memory])
    zip
  end

  defp raw_names(content) do
    content
    |> :binary.matches(<<"PK", 1, 2>>)
    |> Enum.map(fn {pos, _} ->
      <<_::binary-size(28), len::little-16, _::binary>> = binary_part(content, pos, byte_size(content) - pos)
      binary_part(content, pos + 46, len)
    end)
  end
end

{opts, sources} = OptionParser.parse!(System.argv(), strict: [tag: :string, out: :string])

unless opts[:tag] && opts[:out] && sources != [] do
  raise "usage: retag.exs --tag N --out DIR SRC..."
end

unless opts[:tag] =~ ~r/^[A-Za-z0-9]+$/, do: raise("--tag must be letters and digits")

# Unzipping ../escape.x12 logs an "Illegal path" error; it is expected.
:logger.set_primary_config(:level, :critical)
RetagTestData.run(opts[:tag], Path.expand(opts[:out]), sources)
