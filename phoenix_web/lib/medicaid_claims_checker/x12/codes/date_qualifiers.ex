defmodule MedicaidClaimsChecker.X12.Codes.DateQualifiers do
  @moduledoc """
  DTP Segment Date/Time Qualifier Code Lookups

  Maps X12 date qualifier codes to descriptions.
  Used in DTP (Date/Time) segments.
  """

  @doc """
  Get description for DTP date/time qualifier code.
  """
  def lookup(code) do
    case code do
      "096" -> "Discharge Date"
      "097" -> "Discharge Hour"
      "098" -> "Admission Date"
      "291" -> "Statement From Date"
      "292" -> "Statement To Date"
      "304" -> "Last Visit Date"
      "318" -> "Symptom Date"
      "319" -> "Last X-Ray Date"
      "431" -> "Onset of Current Symptoms"
      "435" -> "Admission Date/Hour"
      "439" -> "Accident Date"
      "453" -> "Acute Manifestation Date"
      "454" -> "Initial Treatment Date"
      "455" -> "Last Seen Date"
      "471" -> "Prescription Date"
      "472" -> "Service Date"
      "573" -> "Certification Date"
      "607" -> "Disability From Date"
      "610" -> "Disability Through Date"
      _ -> code
    end
  end
end
