# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.ClaimSplitter do
  @moduledoc """
  Splits multi-claim X12 files into individual per-claim JSON outputs.

  An X12 837 file may contain multiple claims (CLM segments), each belonging
  to a different patient/subscriber. This module splits the file so each
  claim is translated to its own separate JSON file.

  Single-claim files pass through unchanged.

  ## X12 837 Structure

      ISA ... GS ... ST ...              <- envelope (shared)
      BHT ... NM1*41 ... NM1*40 ...      <- submitter/receiver (shared)
      HL*1 ... NM1*85 ...               <- provider (shared header)
      HL*2 ... SBR ... NM1*IL ...       <- subscriber 1 (claim-specific)
      CLM*CLAIM001 ... LX ... SV1 ...   <- claim 1
      HL*3 ... SBR ... NM1*IL ...       <- subscriber 2 (claim-specific)
      CLM*CLAIM002 ... LX ... SV1 ...   <- claim 2
      SE ... GE ... IEA ...             <- trailers (reconstructed)

  ## Output

  Each split claim is reassembled as a valid standalone X12 structure
  and converted to JSON independently.
  """

  require Logger

  alias MedicaidClaimsChecker.X12.Parser

  @doc """
  Splits a multi-claim X12 file into individual claim JSONs.

  Returns `{:ok, nil}` for single-claim files (caller should use normal conversion).
  Returns `{:ok, claims}` for multi-claim files, where each claim is:
    * `:claim_id` - The claim identifier from the CLM segment
    * `:json` - The converted JSON string for this claim
    * `:segment_count` - Number of segments in the split claim

  ## Examples

      iex> ClaimSplitter.split_claims("ISA*...*~...CLM*A*...~...CLM*B*...~...")
      {:ok, [%{claim_id: "A", json: "...", segment_count: 25}, ...]}

      iex> ClaimSplitter.split_claims("ISA*...*~...CLM*A*...~...")
      {:ok, nil}
  """
  def split_claims(x12_content) when is_binary(x12_content) do
    case Parser.parse(x12_content) do
      {:ok, %{segments: segments}} ->
        clm_count = segments |> Enum.count(&(&1.id == "CLM"))

        if clm_count <= 1 do
          # Single claim - no splitting needed
          {:ok, nil}
        else
          do_split(segments)
        end

      {:error, reason} ->
        {:error, "Parse failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Splits an X12 file containing multiple GS/ST transaction sets into individual
  standalone X12 files. Each ST...SE block is returned as a self-contained X12
  with its own ISA/GS header and GE/IEA trailer.

  Returns `{:ok, nil}` when there is only one ST transaction set.
  Returns `{:ok, [x12_content_strings]}` for multi-transaction-set files.

  This must be called BEFORE `split_claims_to_x12/1` when processing raw EDI
  files that may have been batched with multiple transaction sets per envelope.
  """
  def split_transaction_sets(x12_content) when is_binary(x12_content) do
    case Parser.parse(x12_content) do
      {:ok, %{segments: segments}} ->
        st_count = Enum.count(segments, &(&1.id == "ST"))

        if st_count <= 1 do
          {:ok, nil}
        else
          do_split_transaction_sets(segments)
        end

      {:error, reason} ->
        {:error, "Parse failed: #{inspect(reason)}"}
    end
  end

  defp do_split_transaction_sets(segments) do
    isa = Enum.find(segments, &(&1.id == "ISA"))
    iea = Enum.find(segments, &(&1.id == "IEA"))

    # Walk segments, grouping each ST...SE block with its enclosing GS
    {results, _} =
      Enum.reduce(segments, {[], %{gs: nil, st_buf: nil, collecting: false}}, fn seg,
                                                                                 {acc, state} ->
        case seg.id do
          "GS" ->
            {acc, %{state | gs: seg}}

          "ST" ->
            {acc, %{state | st_buf: [seg], collecting: true}}

          "SE" when state.collecting ->
            ts_segments = Enum.reverse([seg | state.st_buf])

            mini_segments = [isa, state.gs] ++ ts_segments ++ [iea]

            text =
              mini_segments
              |> Enum.reject(&is_nil/1)
              |> Enum.map(& &1.raw)
              |> Enum.join("~\n")

            {[text <> "~\n" | acc], %{state | st_buf: nil, collecting: false}}

          _ when state.collecting ->
            {acc, %{state | st_buf: [seg | state.st_buf]}}

          _ ->
            {acc, state}
        end
      end)

    case Enum.reverse(results) do
      [] -> {:error, "No transaction sets found after split"}
      parts -> {:ok, parts}
    end
  end

  @doc """
  Splits a multi-claim X12 file into individual standalone X12 texts.

  Like `split_claims/1` but returns reassembled X12 content instead of JSON,
  suitable for feeding back through the full Converter pipeline (round-trip
  validation + conversion).

  Each reassembled X12 includes the shared envelope/provider header, the
  single claim's subscriber and service-line segments, and corrected SE/GE/IEA
  trailers.

  Returns `{:ok, nil}` for single-claim files.
  Returns `{:ok, claims}` for multi-claim files, where each claim is:
    * `:claim_id` - The claim identifier from the CLM segment
    * `:x12_content` - The standalone X12 text for this claim
  """
  def split_claims_to_x12(x12_content) when is_binary(x12_content) do
    case Parser.parse(x12_content) do
      {:ok, %{segments: segments}} ->
        clm_count = segments |> Enum.count(&(&1.id == "CLM"))

        if clm_count <= 1 do
          {:ok, nil}
        else
          do_split_to_x12(segments)
        end

      {:error, reason} ->
        {:error, "Parse failed: #{inspect(reason)}"}
    end
  end

  # Core splitting logic
  defp do_split(segments) do
    {shared_header, claim_blocks, trailers} = partition_segments(segments)

    results =
      Enum.map(claim_blocks, fn block ->
        # Reassemble: shared header + this claim's block + trailers
        reassembled = shared_header ++ block ++ trailers

        # Convert the reassembled segments to JSON
        case segments_to_json(reassembled) do
          {:ok, json} ->
            claim_id = extract_claim_id(block)

            {:ok,
             %{
               claim_id: claim_id,
               json: json,
               segment_count: length(reassembled)
             }}

          {:error, reason} ->
            {:error, {extract_claim_id(block), reason}}
        end
      end)

    # Separate successes and failures
    successes =
      results
      |> Enum.filter(fn r -> match?({:ok, _}, r) end)
      |> Enum.map(fn {:ok, v} -> v end)

    failures =
      results
      |> Enum.filter(fn r -> match?({:error, _}, r) end)
      |> Enum.map(fn {:error, v} -> v end)

    if Enum.empty?(successes) do
      {:error, "All claims failed to convert: #{inspect(failures)}"}
    else
      if Enum.empty?(failures) do
        {:ok, successes}
      else
        # Partial success - return what we got, log failures
        require Logger

        Logger.warning("ClaimSplitter: #{length(failures)} claim(s) failed: #{inspect(failures)}")
        {:ok, successes}
      end
    end
  end

  @doc """
  Partitions segments into shared header, per-claim blocks, and trailers.

  Returns `{shared_header, [claim_block_1, claim_block_2, ...], trailers}`

  The split point is the HL segment that begins each subscriber loop
  preceding a CLM segment.
  """
  def partition_segments(segments) do
    # Find indices of all CLM segments
    clm_indices =
      segments
      |> Enum.with_index()
      |> Enum.reduce([], fn {seg, idx}, acc ->
        if seg.id == "CLM", do: [idx | acc], else: acc
      end)
      |> Enum.reverse()

    # For each CLM, find where its subscriber block starts
    # by looking backward for the nearest HL segment
    split_points =
      Enum.map(clm_indices, fn clm_idx ->
        find_subscriber_start(segments, clm_idx)
      end)

    # Shared header = everything before the first split point
    first_split = List.first(split_points)

    # Trailers = SE, GE, IEA at the end
    trailer_start = find_trailer_start(segments)

    shared_header = Enum.slice(segments, 0, first_split)

    # Build claim blocks: from each split point to the next (or to trailers)
    claim_blocks =
      split_points
      |> Enum.with_index()
      |> Enum.map(fn {start_idx, i} ->
        end_idx =
          case Enum.at(split_points, i + 1) do
            nil -> trailer_start
            next_start -> next_start
          end

        Enum.slice(segments, start_idx, end_idx - start_idx)
      end)

    trailers = Enum.slice(segments, trailer_start, length(segments) - trailer_start)

    {shared_header, claim_blocks, trailers}
  end

  # Walk backward from CLM to find the nearest HL segment
  # That HL begins the subscriber loop for this claim
  defp find_subscriber_start(segments, clm_idx) do
    clm_idx
    |> Range.new(0, -1)
    |> Enum.find(fn idx ->
      seg = Enum.at(segments, idx)
      seg.id == "HL"
    end)
    |> case do
      nil -> clm_idx
      idx -> idx
    end
  end

  # Find where trailers begin (SE segment and after)
  defp find_trailer_start(segments) do
    segments
    |> Enum.with_index()
    |> Enum.find_value(fn {seg, idx} -> seg.id == "SE" && idx end)
    |> case do
      nil -> length(segments)
      idx -> idx
    end
  end

  # Extract the claim ID from the CLM segment in a claim block
  defp extract_claim_id(block) do
    case Enum.find(block, &(&1.id == "CLM")) do
      nil -> "unknown"
      clm -> Parser.get_element(clm, 1)
    end
  end

  # Splits segments into per-claim X12 texts (not JSON).
  # Each result is reassembled as a valid standalone X12 file.
  defp do_split_to_x12(segments) do
    {shared_header, claim_blocks, trailers} = partition_segments(segments)

    results =
      Enum.map(claim_blocks, fn block ->
        reassembled = shared_header ++ block ++ trailers
        claim_id = extract_claim_id(block)
        x12_text = segments_to_x12(reassembled)
        %{claim_id: claim_id, x12_content: x12_text}
      end)

    if Enum.empty?(results) do
      {:error, "No claims produced after splitting"}
    else
      {:ok, results}
    end
  end

  # Reassembles a list of parsed Segment structs into X12 text.
  # Fixes the SE segment count so the reconstructed file is valid.
  defp segments_to_x12(segments) do
    fixed = fix_se_count(segments)

    text =
      fixed
      |> Enum.map(& &1.raw)
      |> Enum.join("~\n")

    text <> "~\n"
  end

  # Updates the SE segment's element-1 (count) to reflect the actual
  # number of segments from ST through SE inclusive.
  defp fix_se_count(segments) do
    st_idx = Enum.find_index(segments, &(&1.id == "ST"))
    se_idx = Enum.find_index(segments, &(&1.id == "SE"))

    case {st_idx, se_idx} do
      {st, se} when is_integer(st) and is_integer(se) ->
        count = se - st + 1

        segments
        |> Enum.with_index()
        |> Enum.map(fn {seg, idx} ->
          if idx == se do
            new_elements = ["SE", to_string(count)] ++ Enum.drop(seg.elements, 2)
            new_raw = Enum.join(new_elements, "*")
            %{seg | elements: new_elements, raw: new_raw}
          else
            seg
          end
        end)

      _ ->
        segments
    end
  end

  # Convert a list of parsed Segment structs to JSON
  defp segments_to_json(segments) do
    all_segments =
      Enum.map(segments, fn seg ->
        %{
          segment_id: seg.id,
          elements: seg.elements,
          raw: seg.raw,
          line_number: seg.line_number
        }
      end)

    Jason.encode(%{all_segments: all_segments}, pretty: true)
  end
end
