# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.Parser do
  @moduledoc """
  X12 EDI Parser

  Provides low-level parsing utilities for X12 EDI files:
  - Delimiter extraction
  - Segment parsing
  - Element extraction
  - Loop detection and hierarchy
  """

  @min_isa_length 106

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
  Parse X12 content and return structured segments

  ## Examples

      iex> Parser.parse("ISA*00*...")
      {:ok, %{delimiters: %Delimiters{}, segments: [%Segment{}]}}
  """
  def parse(content) when is_binary(content) do
    with {:ok, delimiters} <- parse_delimiters(content),
         {:ok, segments} <- parse_segments(content, delimiters) do
      {:ok, %{delimiters: delimiters, segments: segments}}
    end
  end

  @doc """
  Parse delimiters from ISA segment

  ## Examples

      iex> Parser.parse_delimiters("ISA*00*...")
      {:ok, %Delimiters{element: "*", sub_element: ":", segment: "~"}}
  """
  def parse_delimiters(content) when byte_size(content) < @min_isa_length do
    {:error, "File too short to contain valid ISA segment"}
  end

  def parse_delimiters(content) do
    if String.starts_with?(content, "ISA") do
      element_sep = String.at(content, 3)
      sub_element_sep = String.at(content, 104)

      # Find segment terminator (typically ~ at end of ISA)
      isa_segment =
        content
        |> String.split("\n", parts: 2)
        |> List.first()
        |> String.trim()

      segment_term = String.last(isa_segment)

      {:ok,
       %Delimiters{
         element: element_sep,
         sub_element: sub_element_sep,
         segment: segment_term
       }}
    else
      {:error, "File must start with ISA segment"}
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

  def get_element(segment_elements, position) when is_list(segment_elements) do
    Enum.at(segment_elements, position, "")
  end

  @doc """
  Get multiple elements from segment

  ## Examples

      iex> segment = %Segment{elements: ["NM1", "85", "2", "ACME CLINIC"]}
      iex> Parser.get_elements(segment, [1, 2, 3])
      ["85", "2", "ACME CLINIC"]
  """
  def get_elements(%Segment{} = segment, positions) when is_list(positions) do
    Enum.map(positions, &get_element(segment, &1))
  end

  @doc """
  Parse composite element (sub-elements separated by sub_element delimiter)

  ## Examples

      iex> Parser.parse_composite("HC:99213", ":")
      ["HC", "99213"]
  """
  def parse_composite(element, sub_delimiter) when is_binary(element) do
    String.split(element, sub_delimiter, trim: false)
  end

  @doc """
  Find all segments with a specific ID

  ## Examples

      iex> Parser.find_segments(segments, "CLM")
      [%Segment{id: "CLM", ...}, ...]
  """
  def find_segments(segments, segment_id) when is_list(segments) do
    Enum.filter(segments, fn %Segment{id: id} -> id == segment_id end)
  end

  @doc """
  Find first segment with specific ID

  ## Examples

      iex> Parser.find_segment(segments, "ISA")
      %Segment{id: "ISA", ...}
  """
  def find_segment(segments, segment_id) when is_list(segments) do
    Enum.find(segments, fn %Segment{id: id} -> id == segment_id end)
  end
end
