defmodule MedicaidClaimsCheckerWeb.RuleLive.OverlapNoteTest do
  # Saving a rule whose only redundancy matches are partial overlaps saves it
  # at once and lists the overlaps in a note; a duplicate, redundant or
  # conflicting rule still asks first (Save Anyway / Cancel).
  use MedicaidClaimsCheckerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.{BusinessRule, RuleCatalogue}
  alias MedicaidClaimsChecker.Repo

  @text ~s|RULE new_rule "New" WHEN financial.claim_amount > 2000 THEN REQUIRE_REVIEW "r";|

  setup %{conn: conn} do
    bypass = Bypass.open()

    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_url,
      "http://localhost:#{bypass.port}"
    )

    on_exit(fn -> Application.delete_env(:medicaid_claims_checker, :rule_engine_url) end)

    # Only one existing rule, so check-redundancy is always called.
    Repo.update_all(BusinessRule, set: [active: false])

    {:ok, _} =
      Claims.create_business_rule(%{
        name: "existing_rule",
        rule_text: ~s|RULE existing_rule "E" WHEN financial.claim_amount > 1000 THEN REJECT "x";|,
        active: true
      })

    Bypass.stub(bypass, "POST", "/api/parse-rule", fn conn ->
      json(conn, %{"success" => true, "rule" => [%{}]})
    end)

    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), bypass: bypass}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp engine_reports(bypass, level) do
    Bypass.stub(bypass, "POST", "/api/check-redundancy", fn conn ->
      json(conn, %{
        "success" => true,
        "matches" => [
          %{
            "matchLevel" => level,
            "matchRuleName" => "existing_rule",
            "matchExplanation" => "explanation from the engine"
          }
        ]
      })
    end)
  end

  defp submit(conn) do
    {:ok, view, _html} = live(conn, ~p"/rules")
    params = %{"catalog" => %{"name" => "NewRule", "text" => @text}}
    view |> form("#catalog-rule-form", params) |> render_submit()
    view
  end

  defp saved, do: Claims.get_business_rule_by_name("NewRule")
  defp catalogue_entry, do: Repo.get_by(RuleCatalogue, name: "NewRule")

  test "overlaps alone: saved at once, not marked redundant, overlaps listed", %{
    conn: conn,
    bypass: bypass
  } do
    engine_reports(bypass, "ConditionOverlap")
    view = submit(conn)

    refute has_element?(view, "#redundancy-warning")
    assert has_element?(view, "#overlap-note", "Saved. Partial overlap")
    assert has_element?(view, "#overlap-note li", "Partial Overlap with existing_rule")
    assert %BusinessRule{} = saved()
    assert %{redundant: false} = catalogue_entry()

    view |> element(~s(button[phx-click="dismiss_overlap_note"])) |> render_click()
    refute has_element?(view, "#overlap-note")
  end

  test "a conflict still asks before saving", %{conn: conn, bypass: bypass} do
    engine_reports(bypass, "Shadowed")
    view = submit(conn)

    assert has_element?(view, "#redundancy-warning", "Action Conflict")
    refute has_element?(view, "#overlap-note")
    assert saved() == nil

    view |> element("#save-anyway") |> render_click()
    assert %BusinessRule{} = saved()
    assert %{redundant: true} = catalogue_entry()
  end
end
