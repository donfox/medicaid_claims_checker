-- P4: a rule that parses but uses a field the claim converter doesn't
-- produce (the old name subscriber.subscriber_id). The Rules page must save
-- it as an inactive draft and suggest the current name, subscriber.member_id.
RULE missing_subscriber_id
DESCRIPTION "Review claims with no subscriber ID"
WHEN subscriber.subscriber_id IS NULL
THEN REQUIRE_REVIEW "Subscriber ID missing"
END
