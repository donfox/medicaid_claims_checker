# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.ClaimSplitter do
  @moduledoc """
  Splits an X12 837 file into standalone X12 texts, one per claim.

  A file can hold several interchanges (ISA...IEA), each with functional
  groups (GS...GE) of transaction sets (ST...SE), and a transaction set can
  hold several claims (CLM segments). Splitting runs in two steps:

    1. `split_transaction_sets/1` checks the whole file's envelope and cuts
       it into one standalone X12 text per transaction set.
    2. `split_claims_to_x12/1` cuts one transaction set into one standalone
       X12 text per claim.

  Each piece is rebuilt with the file's own delimiters and corrected
  trailer counts, then goes through `Converter` and `SegmentMapper`.

  ## X12 837 Structure

      ISA ... GS ... ST ...              <- envelope (shared)
      BHT ... NM1*41 ... NM1*40 ...      <- submitter/receiver (shared)
      HL*1 ... NM1*85 ...               <- provider (shared header)
      HL*2 ... SBR ... NM1*IL ...       <- subscriber 1 (claim-specific)
      CLM*CLAIM001 ... LX ... SV1 ...   <- claim 1
      HL*3 ... SBR ... NM1*IL ...       <- subscriber 2 (claim-specific)
      CLM*CLAIM002 ... LX ... SV1 ...   <- claim 2
      SE ... GE ... IEA ...             <- trailers (SE count corrected)
  """

  alias MedicaidClaimsChecker.X12.Parser

  @no_claims "No claims found: the transaction set has no CLM segment"

  @doc """
  Splits an X12 file into standalone X12 texts, one per transaction set.
  Each ST...SE block gets its own interchange (ISA) and group (GS) headers
  and newly built GE and IEA trailers that count exactly that one set.

  Returns `{:ok, nil}` when the file has only one transaction set.
  Returns `{:ok, [x12_content_strings]}` when it has several, across any
  number of groups and interchanges.

  This must be called BEFORE `split_claims_to_x12/1` when processing raw EDI
  files that may have been batched with multiple transaction sets.

  It is the entry point for a whole file, so it also checks the envelope
  (see `check_envelope/1`) and returns `{:error, reason}` for a file that is
  truncated or whose trailers don't match its headers.
  """
  def split_transaction_sets(x12_content) when is_binary(x12_content) do
    with {:ok, %{segments: segments, delimiters: delimiters}} <- Parser.parse(x12_content),
         :ok <- check_envelope(segments) do
      st_count = Enum.count(segments, &(&1.id == "ST"))

      if st_count <= 1 do
        {:ok, nil}
      else
        {:ok, do_split_transaction_sets(segments, delimiters)}
      end
    end
  end

  @doc """
  Checks the envelope of a whole X12 file.

  The file must end with an IEA trailer, every ISA/GS/ST must be closed by
  its IEA/GE/SE before the next one opens, each SE count must equal the
  segments from ST to SE inclusive, the GE and IEA counts must match the
  transaction sets and groups they close, and every trailer's control
  number must match its header's. A file may hold several interchanges.
  Returns `:ok` or `{:error, reason}`.
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

  defp check_segment({%{id: "ISA"} = seg, _idx}, state) do
    if state.isa,
      do: halt("Incomplete transmission: interchange #{el(state.isa, 13)} has no IEA trailer"),
      else: {:cont, %{state | isa: seg, groups: 0}}
  end

  defp check_segment({%{id: "GS"} = seg, _idx}, state) do
    cond do
      state.gs ->
        halt("Incomplete transmission: functional group #{el(state.gs, 6)} has no GE trailer")

      state.isa == nil ->
        halt("GS segment outside an interchange: it comes after an IEA and before the next ISA")

      true ->
        {:cont, %{state | gs: seg, sets: 0}}
    end
  end

  defp check_segment({%{id: "ST"} = seg, idx}, state) do
    cond do
      state.st ->
        halt(
          "Incomplete transmission: transaction set #{el(elem(state.st, 0), 2)} has no SE trailer"
        )

      state.gs == nil ->
        halt("ST segment outside a functional group: it has no GS header")

      true ->
        {:cont, %{state | st: {seg, idx}}}
    end
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

      state.isa == nil ->
        halt("IEA segment without a matching ISA")

      count(seg, 1) != state.groups ->
        halt(
          "IEA says #{el(seg, 1)} functional groups but interchange #{el(state.isa, 13)} " <>
            "has #{state.groups}"
        )

      el(seg, 2) != el(state.isa, 13) ->
        halt(
          "Interchange control number mismatch: ISA13 is #{el(state.isa, 13)} but IEA02 is #{el(seg, 2)}"
        )

      true ->
        {:cont, %{state | isa: nil}}
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

  # Walks the segments keeping the open ISA and GS. Each ST...SE block becomes
  # ISA + GS + the block + a GE and IEA that count one set and one group.
  # The envelope has already been checked, so every block is well nested.
  defp do_split_transaction_sets(segments, delimiters) do
    init = %{isa: nil, gs: nil, st_buf: nil, parts: []}

    segments
    |> Enum.reduce(init, fn seg, state ->
      case seg.id do
        "ISA" ->
          %{state | isa: seg}

        "GS" ->
          %{state | gs: seg}

        "ST" ->
          %{state | st_buf: [seg]}

        "SE" ->
          ge = build_segment(["GE", "1", el(state.gs, 6)], delimiters)
          iea = build_segment(["IEA", "1", el(state.isa, 13)], delimiters)
          block = Enum.reverse([seg | state.st_buf])
          text = segments_to_x12([state.isa, state.gs] ++ block ++ [ge, iea], delimiters)
          %{state | st_buf: nil, parts: [text | state.parts]}

        _ when state.st_buf != nil ->
          %{state | st_buf: [seg | state.st_buf]}

        _ ->
          state
      end
    end)
    |> Map.fetch!(:parts)
    |> Enum.reverse()
  end

  @doc """
  Splits one transaction set into standalone X12 texts, one per claim.

  Each reassembled X12 includes the shared envelope/provider header, the
  single claim's subscriber and service-line segments, and the trailers
  with a corrected SE count.

  Returns `{:ok, nil}` for single-claim files.
  Returns `{:ok, claims}` for multi-claim files, where each claim is:
    * `:claim_id` - The claim identifier from the CLM segment
    * `:x12_content` - The standalone X12 text for this claim
  """
  def split_claims_to_x12(x12_content) when is_binary(x12_content) do
    with {:ok, %{segments: segments, delimiters: delimiters}} <- Parser.parse(x12_content) do
      case Enum.count(segments, &(&1.id == "CLM")) do
        0 -> {:error, @no_claims}
        1 -> {:ok, nil}
        _ -> do_split_to_x12(segments, delimiters)
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

  # Splits segments into per-claim X12 texts.
  defp do_split_to_x12(segments, delimiters) do
    {shared_header, claim_blocks, trailers} = partition_segments(segments)

    results =
      Enum.map(claim_blocks, fn block ->
        reassembled = fix_se_count(shared_header ++ block ++ trailers, delimiters)

        %{
          claim_id: extract_claim_id(block),
          x12_content: segments_to_x12(reassembled, delimiters)
        }
      end)

    if Enum.empty?(results) do
      {:error, "No claims produced after splitting"}
    else
      {:ok, results}
    end
  end

  # Joins segments into X12 text with the file's own segment terminator,
  # one segment per line unless the terminator is itself a line break.
  defp segments_to_x12(segments, %{segment: term}) do
    separator = if term in ["\n", "\r"], do: term, else: term <> "\n"
    Enum.map_join(segments, separator, & &1.raw) <> separator
  end

  defp build_segment(elements, %{element: sep}) do
    %Parser.Segment{id: hd(elements), elements: elements, raw: Enum.join(elements, sep)}
  end

  # Updates the SE segment's element-1 (count) to reflect the actual
  # number of segments from ST through SE inclusive.
  defp fix_se_count(segments, delimiters) do
    st_idx = Enum.find_index(segments, &(&1.id == "ST"))
    se_idx = Enum.find_index(segments, &(&1.id == "SE"))

    case {st_idx, se_idx} do
      {st, se} when is_integer(st) and is_integer(se) ->
        List.update_at(segments, se, fn seg ->
          build_segment(["SE", to_string(se - st + 1) | Enum.drop(seg.elements, 2)], delimiters)
        end)

      _ ->
        segments
    end
  end
end
