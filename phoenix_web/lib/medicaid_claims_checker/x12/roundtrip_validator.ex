defmodule MedicaidClaimsChecker.X12.RoundtripValidator do
  @moduledoc """
  Round-trip Validation for X12 Files

  Performs X12 → JSON → X12 round-trip validation to ensure
  data integrity during conversion. Compares original and
  regenerated X12 files with whitespace normalization.

  Validation Process:
  1. Parse original X12 → JSON
  2. Rebuild X12 from JSON (using Converter.build_from_structure/2)
  3. Normalize both X12 files (whitespace)
  4. Compare segment by segment
  5. Report differences if any
  """

  alias MedicaidClaimsChecker.X12.{Parser, Converter}

  defmodule ValidationResult do
    @moduledoc "Result of round-trip validation"
    defstruct [:valid?, :differences, :original_segments, :rebuilt_segments, :error_message]

    @type t :: %__MODULE__{
            valid?: boolean(),
            differences: list(map()) | nil,
            original_segments: integer(),
            rebuilt_segments: integer(),
            error_message: String.t() | nil
          }
  end

  @doc """
  Validate round-trip conversion of X12 content

  Takes original X12 content, converts to JSON, rebuilds X12,
  and compares the results with whitespace normalization.

  Returns ValidationResult struct
  """
  def validate(x12_content) when is_binary(x12_content) do
    try do
      # Step 1: Parse original X12
      case Parser.parse(x12_content) do
        {:ok, %{delimiters: delimiters, segments: original_segments}} ->
          # Step 2: Convert to structured data
          # Note: build_structure always returns {:ok, ...}
          {:ok, structured_data} = Converter.build_structure(original_segments, delimiters)

          # Step 3: Rebuild X12 from structured data (using Converter.build_from_structure)
          case Converter.build_from_structure(structured_data, delimiters) do
            {:ok, rebuilt_x12} ->
              # Step 4: Normalize and compare
              compare_x12(x12_content, rebuilt_x12, delimiters)

            {:error, reason} ->
              %ValidationResult{
                valid?: false,
                differences: nil,
                original_segments: length(original_segments),
                rebuilt_segments: 0,
                error_message: "Failed to rebuild X12: #{reason}"
              }
          end

        {:error, reason} ->
          %ValidationResult{
            valid?: false,
            differences: nil,
            original_segments: 0,
            rebuilt_segments: 0,
            error_message: "Failed to parse original X12: #{reason}"
          }
      end
    rescue
      e ->
        %ValidationResult{
          valid?: false,
          differences: nil,
          original_segments: 0,
          rebuilt_segments: 0,
          error_message: "Validation error: #{Exception.message(e)}"
        }
    end
  end

  @doc """
  Compare two X12 files with whitespace normalization

  Normalizes both files (removes extra whitespace, standardizes line breaks)
  and compares segment by segment.
  """
  def compare_x12(original_x12, rebuilt_x12, delimiters) do
    # Normalize both X12 files
    original_normalized = normalize_x12(original_x12, delimiters)
    rebuilt_normalized = normalize_x12(rebuilt_x12, delimiters)

    # Split into segments
    original_segments = split_segments(original_normalized, delimiters.segment)
    rebuilt_segments = split_segments(rebuilt_normalized, delimiters.segment)

    # Compare segment counts
    original_count = length(original_segments)
    rebuilt_count = length(rebuilt_segments)

    if original_count != rebuilt_count do
      %ValidationResult{
        valid?: false,
        differences: [
          %{
            type: :segment_count_mismatch,
            original_count: original_count,
            rebuilt_count: rebuilt_count,
            message:
              "Segment count mismatch: original has #{original_count}, rebuilt has #{rebuilt_count}"
          }
        ],
        original_segments: original_count,
        rebuilt_segments: rebuilt_count,
        error_message: "Segment count mismatch"
      }
    else
      # Compare segments one by one
      differences =
        original_segments
        |> Enum.zip(rebuilt_segments)
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {{orig, rebuilt}, index}, acc ->
          if orig != rebuilt do
            acc ++
              [
                %{
                  type: :segment_mismatch,
                  segment_number: index,
                  original: orig,
                  rebuilt: rebuilt,
                  message: "Segment #{index} differs"
                }
              ]
          else
            acc
          end
        end)

      if length(differences) == 0 do
        %ValidationResult{
          valid?: true,
          differences: [],
          original_segments: original_count,
          rebuilt_segments: rebuilt_count,
          error_message: nil
        }
      else
        %ValidationResult{
          valid?: false,
          differences: differences,
          original_segments: original_count,
          rebuilt_segments: rebuilt_count,
          error_message: "#{length(differences)} segment(s) differ between original and rebuilt"
        }
      end
    end
  end

  @doc """
  Normalize X12 content for comparison

  Removes:
  - Leading/trailing whitespace on each line
  - Empty lines
  - Extra spaces between elements
  - Line breaks (converts to single-line per segment)

  Preserves:
  - All segment data
  - Element delimiters
  - Segment terminators
  """
  def normalize_x12(x12_content, delimiters) when is_binary(x12_content) do
    x12_content
    # Remove all line breaks and carriage returns
    |> String.replace(~r/[\r\n]+/, "")
    # Trim leading/trailing whitespace
    |> String.trim()
    # Remove any spaces around segment terminators
    |> String.replace(~r/\s*#{Regex.escape(delimiters.segment)}\s*/, delimiters.segment)
    # Remove any spaces around element delimiters
    |> String.replace(~r/\s*#{Regex.escape(delimiters.element)}\s*/, delimiters.element)
  end

  @doc """
  Split X12 content into individual segments

  Splits on segment terminator and filters out empty segments
  """
  def split_segments(x12_content, segment_terminator) do
    x12_content
    |> String.split(segment_terminator, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) > 0))
  end

  @doc """
  Format validation result as human-readable string

  Useful for logging and error messages
  """
  def format_result(%ValidationResult{valid?: true}) do
    "✓ Round-trip validation passed - X12 file can be perfectly reconstructed from JSON"
  end

  def format_result(%ValidationResult{valid?: false, error_message: msg, differences: nil}) do
    "✗ Round-trip validation failed: #{msg}"
  end

  def format_result(%ValidationResult{
        valid?: false,
        differences: diffs,
        original_segments: orig_count,
        rebuilt_segments: rebuilt_count
      }) do
    diff_summary =
      diffs
      |> Enum.take(5)
      |> Enum.map_join("\n  ", fn diff ->
        case diff.type do
          :segment_count_mismatch ->
            "Segment count: original=#{orig_count}, rebuilt=#{rebuilt_count}"

          :segment_mismatch ->
            """
            Segment #{diff.segment_number}:
              Original: #{String.slice(diff.original, 0, 100)}#{if String.length(diff.original) > 100, do: "...", else: ""}
              Rebuilt:  #{String.slice(diff.rebuilt, 0, 100)}#{if String.length(diff.rebuilt) > 100, do: "...", else: ""}
            """
        end
      end)

    total_diffs = length(diffs)
    showing = min(total_diffs, 5)

    """
    ✗ Round-trip validation failed with #{total_diffs} difference(s)

    Showing first #{showing} difference(s):
      #{diff_summary}
    #{if total_diffs > 5, do: "\n  ... and #{total_diffs - 5} more difference(s)", else: ""}
    """
  end

  @doc """
  Get summary statistics from validation result

  Returns map with counts and status
  """
  def get_summary(%ValidationResult{} = result) do
    %{
      valid: result.valid?,
      original_segments: result.original_segments,
      rebuilt_segments: result.rebuilt_segments,
      differences_count: if(result.differences, do: length(result.differences), else: 0),
      error_message: result.error_message
    }
  end
end
