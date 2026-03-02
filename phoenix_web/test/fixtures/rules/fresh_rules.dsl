# fresh_rules.dsl
# -----------------------------------------------------------------------
# Fresh BA Rule set for interactive testing.
# Load via:  POST http://localhost:8080/api/compile-rules
#            { "rulesText": "<contents of this file>" }
# Evaluate:  POST http://localhost:8080/api/evaluate
#            { "rulesText": "...", "document": <claim JSON>, "claimId": "..." }
# -----------------------------------------------------------------------

# Rule 1 — High-value claims need a human sign-off before payment.
RULE high_value_claim
DESCRIPTION "Claims exceeding $50,000 require manual review before payment"
WHEN financial.claim_amount > 50000
THEN REQUIRE_REVIEW "Claim exceeds high-value threshold — manual approval required"
END

# Rule 2 — Don't pay a large claim that has no authorization on file.
RULE unauthorized_procedure
DESCRIPTION "High-value claim submitted without a valid authorization number"
WHEN authorization.authorization_number IS NULL
     AND financial.claim_amount > 5000
THEN REJECT "High-value claim lacks required authorization"
END

# Rule 3 — New providers submitting large claims are higher risk.
RULE new_provider_large_submission
DESCRIPTION "Large claim from a provider credentialed less than 90 days ago"
WHEN provider.tenure_days < 90
     AND financial.claim_amount > 10000
THEN REQUIRE_REVIEW "Large submission from newly credentialed provider"
END

# Rule 4 — Sub-$5 charges suggest a data entry error or fraud probe.
RULE suspicious_low_charge
DESCRIPTION "Charge below $5 may indicate billing manipulation or data error"
WHEN financial.claim_amount < 5
THEN FLAG_FRAUD "Suspiciously low charge — possible billing manipulation"
END

# Rule 5 — High-complexity ER visits with large bills warrant clinical review.
RULE high_complexity_er_visit
DESCRIPTION "High-complexity ER visit (99285) with elevated charges requires clinical review"
WHEN service_lines.0.procedure_code = "99285"
     AND financial.claim_amount > 10000
THEN REQUIRE_REVIEW "High-complexity ER — clinical validation required"
END
