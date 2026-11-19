# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.Parser do
  @moduledoc """
  X12 EDI Parser

  Low-level parsing for X12 EDI files: reads the delimiters from the ISA
  segment and splits the content into segments and elements. It knows
  nothing about loops or claims; `ClaimSplitter` and `SegmentMapper` do.
  """

  # The ISA segment is fixed width: 106 characters including its terminator.
  # Byte 3 is the element separator, byte 104 (ISA16) the sub-element
  # separator and byte 105 the segment terminator.
  @isa_length 106
  @isa_element_count 16

  defmodule Delimiters do
    @moduledoc "X12 delimiter configuration"
    defstruct [:element, :sub_element, :segment]

    @type t :: %__MODULE__{
            element: String.t(),
            sub_element: String.t(),
            segment: String.t()
          }
  end

  defmodule Segment do
    @moduledoc "Represents a parsed X12 segment"
    defstruct [:id, :elements, :raw, :line_number]

    @type t :: %__MODULE__{
            id: String.t(),
            elements: list(String.t()),
            raw: String.t(),
            line_number: non_neg_integer()
          }
  end

  @doc """
  Parse X12 content and return structured segments.

  A leading byte-order mark and leading whitespace are ignored. Returns
  `{:ok, %{delimiters: %Delimiters{}, segments: [%Segment{}]}}` or
  `{:error, reason}` with a message that can be shown to the user as is.
  """
  def parse(content) when is_binary(content) do
    content = strip_leading(content)

    with {:ok, delimiters} <- parse_delimiters(content),
         {:ok, segments} <- parse_segments(content, delimiters) do
      {:ok, %{delimiters: delimiters, segments: segments}}
    end
  end

  defp strip_leading(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: strip_leading(rest)
  defp strip_leading(content), do: String.trim_leading(content)

  @doc """
  Parse delimiters from the fixed-width ISA segment.

  ## Examples

      iex> Parser.parse_delimiters("ISA*00*...")
      {:ok, %Delimiters{element: "*", sub_element: ":", segment: "~"}}
  """
  def parse_delimiters(content) do
    cond do
      not String.starts_with?(content, "ISA") ->
        {:error, "Not an X12 file: it must start with ISA, the interchange header"}

      byte_size(content) < @isa_length ->
        {:error, "File too short to hold an ISA interchange header"}

      true ->
        element = binary_part(content, 3, 1)
        isa = binary_part(content, 0, @isa_length - 1)

        # In a fixed-width ISA the 16th element separator, the one before
        # ISA16, is byte 103.
        if match?({103, 1}, Enum.at(:binary.matches(isa, element), @isa_element_count - 1)) do
          {:ok,
           %Delimiters{
             element: element,
             sub_element: binary_part(content, 104, 1),
             segment: binary_part(content, 105, 1)
           }}
        else
          {:error,
           "The ISA interchange header is not the standard fixed width of 106 characters, " <>
             "so its delimiters can't be read"}
        end
    end
  end

  @doc """
  Parse all segments from X12 content

  Returns list of Segment structs with parsed elements
  """
  def parse_segments(content, %Delimiters{} = delimiters) do
    segments =
      content
      |> String.split(delimiters.segment, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))
      |> Enum.with_index(1)
      |> Enum.map(fn {raw_segment, line_num} ->
        elements = String.split(raw_segment, delimiters.element)
        segment_id = List.first(elements) || ""

        %Segment{
          id: segment_id,
          elements: elements,
          raw: raw_segment,
          line_number: line_num
        }
      end)

    {:ok, segments}
  end

  @doc """
  Get element value from segment by position (0-indexed)

  ## Examples

      iex> segment = %Segment{elements: ["CLM", "CLAIM123", "150.00"]}
      iex> Parser.get_element(segment, 1)
      "CLAIM123"
  """
  def get_element(%Segment{elements: elements}, position) when is_integer(position) do
    Enum.at(elements, position, "")
  end
end
