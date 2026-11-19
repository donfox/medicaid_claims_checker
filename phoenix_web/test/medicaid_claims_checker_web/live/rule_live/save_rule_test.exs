defmodule MedicaidClaimsCheckerWeb.RuleLive.SaveRuleTest do
  # Saving a rule on the Rules page: the rule and its catalogue entry are
  # saved together or not at all, an engine error never crashes the page,
  # and one text holds exactly one rule.
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

    # One active rule, so check-redundancy is always called.
    Repo.update_all(BusinessRule, set: [active: false])

    {:ok, _} =
      Claims.create_business_rule(%{
        name: "existing_rule",
        rule_text: ~s|RULE existing_rule "E" WHEN financial.claim_amount > 1000 THEN REJECT "x";|,
        active: true
      })

    parse_returns(bypass, 1)
    redundancy_replies(bypass, 200, ~s|{"success":true,"matches":[]}|)

    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), bypass: bypass}
  end

  defp parse_returns(bypass, rule_count) do
    Bypass.stub(bypass, "POST", "/api/parse-rule", fn conn ->
      body = Jason.encode!(%{"success" => true, "rule" => List.duplicate(%{}, rule_count)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
    end)
  end

  defp redundancy_replies(bypass, status, body) do
    Bypass.stub(bypass, "POST", "/api/check-redundancy", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(status, body)
    end)
  end

  defp submit(conn, name, text \\ @text) do
    {:ok, view, _html} = live(conn, ~p"/rules")

    html =
      view
      |> form("#catalog-rule-form", %{"catalog" => %{"name" => name, "text" => text}})
      |> render_submit()

    {view, html}
  end

  defp entry(name), do: Repo.get_by(RuleCatalogue, name: name)

  test "a name another catalogue entry uses saves nothing and says so", %{conn: conn} do
    {:ok, _} =
      Claims.create_catalogue_entry(%{
        name: "SomeModel",
        description: "",
        entry_type: "ML Model",
        status: "Active",
        editable: false,
        removable: false,
        redundant: false,
        db_access: false
      })

    {_view, html} = submit(conn, "SomeModel")

    assert html =~ "Could not save rule: name has already been taken"
    assert Claims.get_business_rule_by_name("SomeModel") == nil
    assert entry("SomeModel").entry_type == "ML Model"
  end

  test "renaming a rule to a taken name leaves the rule and its entry as they were", %{conn: conn} do
    {_view, _html} = submit(conn, "MyRule")
    my_entry = entry("MyRule")

    {:ok, _} =
      Claims.create_catalogue_entry(%{
        name: "Taken",
        description: "",
        entry_type: "ML Model",
        status: "Active",
        editable: false,
        removable: false,
        redundant: false,
        db_access: false
      })

    {:ok, view, _html} = live(conn, ~p"/rules")
    render_click(view, "select_catalog_rule", %{"id" => to_string(my_entry.id)})

    html =
      view
      |> form("#catalog-rule-form", %{"catalog" => %{"name" => "Taken", "text" => @text}})
      |> render_submit()

    assert html =~ "Could not save rule: name has already been taken"
    assert Claims.get_business_rule_by_name("MyRule")
    assert entry("MyRule")
  end

  test "an engine error from the redundancy check doesn't crash the page; the rule saves with a note",
       %{conn: conn, bypass: bypass} do
    redundancy_replies(bypass, 429, ~s|{"error":"rate limited"}|)

    {_view, html} = submit(conn, "RateLimited")

    assert html =~ "The redundancy check could not run (the rule engine answered HTTP 429)"
    assert Claims.get_business_rule_by_name("RateLimited").active
    assert entry("RateLimited").entry_type == "BA Rule"
  end

  test "a text holding two rules is refused", %{conn: conn, bypass: bypass} do
    parse_returns(bypass, 2)

    {_view, html} =
      submit(conn, "Pair", @text <> "\n" <> String.replace(@text, "new_rule", "other"))

    assert html =~ "This text holds 2 rules"
    assert Claims.get_business_rule_by_name("Pair") == nil
  end

  test "opening a rule leaves WHEN and THEN inside its messages alone", %{conn: conn} do
    text =
      ~s|RULE q "Paid WHEN closed" WHEN financial.claim_amount > 1 THEN REJECT "Stop THEN review";|

    {_view, _html} = submit(conn, "Quoted", text)

    {:ok, view, _html} = live(conn, ~p"/rules")
    html = render_click(view, "select_catalog_rule", %{"id" => to_string(entry("Quoted").id)})

    assert html =~ "Paid WHEN closed"
    assert html =~ "Stop THEN review"
  end
end
