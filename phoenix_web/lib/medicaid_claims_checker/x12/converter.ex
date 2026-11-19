defmodule MedicaidClaimsChecker.X12.Converter do
  @moduledoc """
  X12 to flat JSON converter.

  Parses one X12 837 claim (usually a piece cut by `ClaimSplitter`) into a
  JSON object holding the file's sub-element separator and the flat list of
  segments. `SegmentMapper.map_from_json/1` then turns that list into the
  claim layout the engine checks (837P, 837I and 837D).
  """

  alias MedicaidClaimsChecker.X12.Parser

  @processing_timeout_ms 30_000

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

            {:error, _reason} = error ->
              error
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
  def build_structure(segments, delimiters) when is_list(segments) do
    all_segments =
      Enum.map(segments, fn seg ->
        %{
          segment_id: seg.id,
          elements: seg.elements,
          raw: seg.raw,
          line_number: seg.line_number
        }
      end)

    # SegmentMapper needs ISA16 to split composite elements.
    sub = if delimiters, do: delimiters.sub_element, else: nil
    {:ok, %{sub_element_separator: sub, all_segments: all_segments}}
  end
end
