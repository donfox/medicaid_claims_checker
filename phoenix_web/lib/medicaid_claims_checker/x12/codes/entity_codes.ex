defmodule MedicaidClaimsChecker.X12.Codes.EntityCodes do
  @moduledoc """
  NM1 Segment Entity Identifier Code Lookups

  Maps X12 entity codes to human-readable descriptions.
  Used in NM1 (Name) segments to identify entity types.
  """

  @doc """
  Get description for NM1 entity identifier code.

  Returns the code itself if no description found (defensive).
  """
  def lookup(code) do
    case code do
      "40" -> "Receiver"
      "41" -> "Submitter"
      "71" -> "Attending Physician"
      "72" -> "Operating Physician"
      "77" -> "Service Location"
      "82" -> "Rendering Provider"
      "85" -> "Billing Provider"
      "87" -> "Pay-to Provider"
      "DN" -> "Referring Provider"
      "DQ" -> "Supervising Provider"
      "IL" -> "Insured/Subscriber"
      "P3" -> "Primary Care Provider"
      "PR" -> "Payer"
      "QC" -> "Patient"
      "X3" -> "Dependent"
      _ -> code
    end
  end
end
