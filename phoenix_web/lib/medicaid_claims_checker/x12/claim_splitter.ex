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

  @no_claims "No claims found: the transaction set has no CLM segment"

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
        case Enum.count(segments, &(&1.id == "CLM")) do
          0 -> {:error, @no_claims}
          # Single claim - no splitting needed
          1 -> {:ok, nil}
          _ -> do_split(segments)
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

  It is the entry point for a whole file, so it also checks the envelope
  (see `check_envelope/1`) and returns `{:error, reason}` for a file that is
  truncated or whose trailers don't match its headers.
  """
  def split_transaction_sets(x12_content) when is_binary(x12_content) do
    with {:ok, %{segments: segments}} <- parse(x12_content),
         :ok <- check_envelope(segments) do
      st_count = Enum.count(segments, &(&1.id == "ST"))

      if st_count <= 1 do
        {:ok, nil}
      else
        do_split_transaction_sets(segments)
      end
    end
  end

  defp parse(x12_content) do
    case Parser.parse(x12_content) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, "Parse failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Checks the interchange envelope of a whole X12 file.

  The file must end with an IEA trailer, every ST/GS must be closed by its
  SE/GE, each SE count must equal the segments from ST to SE inclusive, the
  GE and IEA counts must match the transaction sets and groups they close,
  and every trailer's control number must match its header's. Returns `:ok`
  or `{:error, reason}`.
  """
  def check_envelope(segments) when is_list(segments) do
    case List.last(segments) do
      %{id: "IEA"} ->
        segments
        |> Enum.with_index()
        |> Enum.reduce_while(%{isa: nil, gs: nil, st: nil, sets: 0, groups: 0}, &check_segment/2)
        |> case do
          {:error, _} = error -> error
          _ -> :ok
        end

      last ->
        ended_at = if last, do: "a #{last.id} segment", else: "no segments"

        {:error,
         "Incomplete transmission: the file ends with #{ended_at} instead of the IEA trailer, " <>
           "so it may have been cut off in transfer"}
    end
  end

  defp check_segment({%{id: "ISA"} = seg, _idx}, state), do: {:cont, %{state | isa: seg}}

  defp check_segment({%{id: "GS"} = seg, _idx}, state) do
    if state.gs,
      do: halt("Incomplete transmission: functional group #{el(state.gs, 6)} has no GE trailer"),
      else: {:cont, %{state | gs: seg, sets: 0}}
  end

  defp check_segment({%{id: "ST"} = seg, idx}, state) do
    if state.st,
      do:
        halt(
          "Incomplete transmission: transaction set #{el(elem(state.st, 0), 2)} has no SE trailer"
        ),
      else: {:cont, %{state | st: {seg, idx}}}
  end

  defp check_segment({%{id: "SE"} = seg, idx}, %{st: {st, st_idx}} = state) do
    actual = idx - st_idx + 1

    cond do
      count(seg, 1) != actual ->
        halt(
          "SE segment count is #{el(seg, 1)} but transaction set #{el(st, 2)} has #{actual} segments"
        )

      el(seg, 2) != el(st, 2) ->
        halt(
          "Transaction set control number mismatch: ST02 is #{el(st, 2)} but SE02 is #{el(seg, 2)}"
        )

      true ->
        {:cont, %{state | st: nil, sets: state.sets + 1}}
    end
  end

  defp check_segment({%{id: "SE"}, _idx}, _state), do: halt("SE segment without a matching ST")

  defp check_segment({%{id: "GE"} = seg, _idx}, state) do
    cond do
      state.st ->
        halt(
          "Incomplete transmission: transaction set #{el(elem(state.st, 0), 2)} has no SE trailer"
        )

      state.gs == nil ->
        halt("GE segment without a matching GS")

      count(seg, 1) != state.sets ->
        halt("GE says #{el(seg, 1)} transaction sets but the group has #{state.sets}")

      el(seg, 2) != el(state.gs, 6) ->
        halt(
          "Functional group control number mismatch: GS06 is #{el(state.gs, 6)} but GE02 is #{el(seg, 2)}"
        )

      true ->
        {:cont, %{state | gs: nil, groups: state.groups + 1}}
    end
  end

  defp check_segment({%{id: "IEA"} = seg, _idx}, state) do
    cond do
      state.st ->
        halt(
          "Incomplete transmission: transaction set #{el(elem(state.st, 0), 2)} has no SE trailer"
        )

      state.gs ->
        halt("Incomplete transmission: functional group #{el(state.gs, 6)} has no GE trailer")

      count(seg, 1) != state.groups ->
        halt("IEA says #{el(seg, 1)} functional groups but the file has #{state.groups}")

      state.isa && el(seg, 2) != el(state.isa, 13) ->
        halt(
          "Interchange control number mismatch: ISA13 is #{el(state.isa, 13)} but IEA02 is #{el(seg, 2)}"
        )

      true ->
        {:cont, state}
    end
  end

  defp check_segment(_, state), do: {:cont, state}

  defp halt(reason), do: {:halt, {:error, reason}}
  defp el(seg, pos), do: seg |> Parser.get_element(pos) |> String.trim()

  defp count(seg, pos) do
    case Integer.parse(el(seg, pos)) do
      {n, ""} -> n
      _ -> nil
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
        case Enum.count(segments, &(&1.id == "CLM")) do
          0 -> {:error, @no_claims}
          1 -> {:ok, nil}
          _ -> do_split_to_x12(segments)
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

  The shared header is everything before the first HL. Each claim block is
  self-contained: the billing-provider (HL 20), subscriber (HL 22) and
  patient (HL 23) loops the claim sits under, followed by the claim's own
  segments up to the next HL or CLM. Several claims under one subscriber
  each get a copy of that subscriber's loop.
  """
  def partition_segments(segments) do
    trailer_start = find_trailer_start(segments)

    body_start =
      Enum.find_index(segments, &(&1.id in ["HL", "CLM"])) || trailer_start

    shared_header = Enum.slice(segments, 0, body_start)
    body = Enum.slice(segments, body_start, trailer_start - body_start)
    trailers = Enum.slice(segments, trailer_start, length(segments) - trailer_start)

    {shared_header, claim_blocks(body), trailers}
  end

  # Walks the body keeping the segments of the HL loops currently open.
  # Loops and blocks are built in reverse and flipped when closed.
  defp claim_blocks(body) do
    init = %{loops: %{"20" => [], "22" => [], "23" => []}, level: "20", claim: nil, blocks: []}

    body
    |> Enum.reduce(init, fn seg, state ->
      case seg.id do
        "HL" ->
          level = hl_level(seg)
          state = close_claim(state)

          loops =
            case level do
              "20" -> %{"20" => [seg], "22" => [], "23" => []}
              "22" -> %{state.loops | "22" => [seg], "23" => []}
              "23" -> %{state.loops | "23" => [seg]}
            end

          %{state | loops: loops, level: level}

        "CLM" ->
          state = close_claim(state)
          context = Enum.flat_map(["20", "22", "23"], &Enum.reverse(state.loops[&1]))
          %{state | claim: Enum.reverse(context, [seg])}

        _ when state.claim != nil ->
          %{state | claim: [seg | state.claim]}

        _ ->
          %{state | loops: Map.update!(state.loops, state.level, &[seg | &1])}
      end
    end)
    |> close_claim()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
  end

  defp close_claim(%{claim: nil} = state), do: state

  defp close_claim(state),
    do: %{state | claim: nil, blocks: [Enum.reverse(state.claim) | state.blocks]}

  # HL03 is the hierarchical level code: 20 billing provider, 22 subscriber,
  # 23 patient. Anything else is treated as a patient-level child loop.
  defp hl_level(seg) do
    case Parser.get_element(seg, 3) do
      code when code in ["20", "22"] -> code
      _ -> "23"
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
