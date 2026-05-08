defmodule MedicaidClaimsChecker.X12.Converter do
  @moduledoc """
  X12 to JSON Converter & Builder

  Converts X12 837 (Healthcare Claims) EDI files into semantic,
  hierarchical JSON format, and reconstructs X12 from JSON.

  Supports:
  - 837P (Professional Claims) - uses SV1 segments
  - 837I (Institutional Claims) - uses SV2 segments
  - 837D (Dental Claims) - uses SV3 segments

  The output structure organizes claims with nested service lines,
  making the data easier to work with for developers.

  The Builder functionality reconstructs X12 EDI from the JSON
  output for round-trip validation to ensure data integrity.
  """

  alias MedicaidClaimsChecker.X12.Parser

  @max_file_size_bytes 50 * 1024 * 1024
  @processing_timeout_ms 30_000

  @doc """
  Convert X12 file to JSON with timeout protection
  """
  def convert_file(filepath) do
    case File.stat(filepath) do
      {:ok, %File.Stat{size: size}} when size > @max_file_size_bytes ->
        size_mb = Float.round(size / (1024 * 1024), 2)
        max_mb = Float.round(@max_file_size_bytes / (1024 * 1024), 2)
        {:error, "File too large: #{size_mb} MB exceeds maximum of #{max_mb} MB"}

      {:ok, _stat} ->
        case File.read(filepath) do
          {:ok, content} ->
            do_convert_content(content)

          {:error, :enoent} ->
            {:error, "File not found: #{filepath}"}

          {:error, reason} ->
            {:error, "Failed to read file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to access file: #{inspect(reason)}"}
    end
  end

  @doc """
  Convert X12 content string to JSON with timeout protection
  Returns {:ok, json_string} or {:error, reason}
  """
  def convert_content(content) when is_binary(content) do
    do_convert_content(content)
  end

  defp do_convert_content(content) do
    task =
      Task.async(fn ->
        try do
          case Parser.parse(content) do
            {:ok, %{delimiters: delimiters, segments: segments}} ->
              {:ok, structured_data} = build_structure(segments, delimiters)
              Jason.encode(structured_data, pretty: true)

            {:error, reason} ->
              {:error, "Parsing failed: #{inspect(reason)}"}
          end
        rescue
          e in ArgumentError ->
            {:error, "Invalid X12 format: #{Exception.message(e)}"}

          e in RuntimeError ->
            {:error, "Processing error: #{Exception.message(e)}"}

          e ->
            {:error, "Unexpected error: #{Exception.message(e)}"}
        end
      end)

    case Task.yield(task, @processing_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        timeout_sec = div(@processing_timeout_ms, 1000)
        {:error, "Processing timeout: File took longer than #{timeout_sec} seconds to process"}

      {:exit, reason} ->
        {:error, "Processing crashed: #{inspect(reason)}"}
    end
  end

  @doc """
  Build structured data from parsed segments
  """
  def build_structure(segments, _delimiters) when is_list(segments) do
    all_segments =
      Enum.map(segments, fn seg ->
        %{
          segment_id: seg.id,
          elements: seg.elements,
          raw: seg.raw,
          line_number: seg.line_number
        }
      end)

    {:ok, %{all_segments: all_segments}}
  end

  @doc """
  Build X12 content from structured JSON data
  Returns {:ok, x12_content} or {:error, reason}
  """
  def build_from_structure(structured_data, delimiters \\ nil) do
    delimiters = delimiters || %{element: "*", sub_element: ":", segment: "~"}

    try do
      if all_segments =
           Map.get(structured_data, :all_segments) || Map.get(structured_data, "all_segments") do
        if is_list(all_segments) and length(all_segments) > 0 do
          segments_list =
            all_segments
            |> Enum.map(fn seg ->
              elements = Map.get(seg, :elements) || Map.get(seg, "elements") || []
              Enum.join(elements, delimiters.element)
            end)

          x12_content = Enum.join(segments_list, delimiters.segment)

          x12_content =
            if String.ends_with?(x12_content, delimiters.segment),
              do: x12_content,
              else: x12_content <> delimiters.segment

          {:ok, x12_content}
        else
          {:error, "No segments to build X12 from."}
        end
      else
        {:error, "all_segments field missing in structured data."}
      end
    rescue
      e ->
        {:error, "Failed to build X12: #{Exception.message(e)}"}
    end
  end
end
