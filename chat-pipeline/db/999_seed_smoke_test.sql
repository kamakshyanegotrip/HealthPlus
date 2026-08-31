-- Minimal seed data + adoption of the PROVISIONAL pricing rows, so the
-- pipeline's actual queries (run separately by scripts/smoke-test.mjs as
-- hp_app) have something real to find. Run as superuser/owner, not hp_app.

UPDATE obs.model_pricing SET adoption_state = 'ADOPTED', adopted_version = 'SMOKE-TEST', reviewed_at = now();

INSERT INTO app_user (id, data_region) VALUES ('11111111-1111-1111-1111-111111111111', 'IN');
INSERT INTO patient_profile (user_id, data_region, age_band, preferences, is_minor)
  VALUES ('11111111-1111-1111-1111-111111111111', 'IN', '30-39', '{"budget":"moderate","destination_pref":"Chennai"}'::jsonb, false);
INSERT INTO patient_attribute (user_id, kind, label, provenance)
  VALUES ('11111111-1111-1111-1111-111111111111', 'condition', 'type 2 diabetes', 'stated');

-- A second patient, used only to prove RLS isolation (db/020_rls.sql) in
-- scripts/smoke-test.mjs — never referenced by the pipeline's own claim/rule
-- seed data above.
INSERT INTO app_user (id, data_region) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'IN');
INSERT INTO patient_profile (user_id, data_region, age_band, preferences, is_minor)
  VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'IN', '40-49', '{"budget":"premium","destination_pref":"Delhi"}'::jsonb, false);
INSERT INTO patient_attribute (user_id, kind, label, provenance)
  VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'condition', 'hypertension', 'stated');

-- Two hospitals, used to prove the HP-SEC-001 §4 marketplace pattern:
-- hospital_admin isolated to its own org across all statuses, patient/
-- clinician/platform_admin see PUBLISHED rows from any org.
INSERT INTO hospital_profile (id, name, status) VALUES
  ('cccccccc-1111-1111-1111-111111111111', 'Chennai Cardiac Institute', 'PUBLISHED'),
  ('cccccccc-2222-2222-2222-222222222222', 'Delhi Orthopaedic Centre (draft listing)', 'DRAFT');
INSERT INTO hospital_cost (id, hospital_id) VALUES
  ('dddddddd-1111-1111-1111-111111111111', 'cccccccc-1111-1111-1111-111111111111'),
  ('dddddddd-2222-2222-2222-222222222222', 'cccccccc-2222-2222-2222-222222222222');

INSERT INTO evidence.evidence_source (id, tier, retracted) VALUES
  ('22222222-2222-2222-2222-222222222222', 'TIER_2', false);

INSERT INTO evidence.claim (id, kind, domain_table, text, population, search_tsv) VALUES
  ('33333333-3333-3333-3333-333333333333', 'GUIDELINE', 'domain.guideline',
   'ADA 2026 guidance recommends HbA1c target below 7% for most non-pregnant adults with type 2 diabetes.',
   'non-pregnant adults with type 2 diabetes',
   to_tsvector('english', 'ADA guidance HbA1c target diabetes guideline'));

INSERT INTO evidence.claim_source (claim_id, source_id, confidence) VALUES
  ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 0.82);

INSERT INTO evidence.claim_policy (tier, kind, category, disposition, confidence_cap, min_sources, charter_clause, adopted_version, adopted_by, effective_from)
  VALUES ('TIER_2', 'GUIDELINE', 'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day');

INSERT INTO safety.red_flag_rule (ruleset_version, severity, pattern, pattern_notes, clinically_adopted, adopted_by, adopted_at)
  VALUES ('rf-rules-2026.08.1', 'URGENT', 'chest pain|crushing pain|can''t breathe', 'cardiac/respiratory emergency keywords — SMOKE TEST ONLY, not clinician-authored', true, '11111111-1111-1111-1111-111111111111', now());

INSERT INTO safety.safety_template (id, body, active, clinically_adopted, adopted_by, adopted_at)
  VALUES ('44444444-4444-4444-4444-444444444444',
          'This may be a medical emergency. Contact your local emergency number now.',
          true, true, '11111111-1111-1111-1111-111111111111', now());

-- ---- GENERIC_ESCALATION_TEMPLATE_ID (redFlagEngine.ts's
-- resolveTemplateRequirement fallback for a WARNING+ severity whose rule
-- carries no template of its own). Seeded so that fallback resolves to a
-- real row — see redFlagEngine.ts's GENERIC_ESCALATION_TEMPLATE_ID comment
-- for the bug (a bare non-UUID placeholder string) this closes.
INSERT INTO safety.safety_template (id, body, active, clinically_adopted, adopted_by, adopted_at)
  VALUES ('55555555-5555-5555-5555-555555555555',
          'This has been flagged for clinical review. A member of our care team will follow up; if your situation ' ||
          'changes or feels urgent in the meantime, please seek in-person care rather than waiting for that follow-up.',
          true, true, '11111111-1111-1111-1111-111111111111', now());

-- ---- Other 8 of 9 knowledge domains ----------------------------------------
-- Turn-5 gap: only GUIDELINE (seeded above) had ever been exercised. One
-- claim per remaining KnowledgeDomain, same TIER_2 evidence_source and
-- DECISION_SUPPORT category as the GUIDELINE seed, so lookupKnowledge /
-- lookupDomain can actually be driven across all nine domain tables — not
-- just re-reading the "identical code path, different table name" claim in
-- knowledgeLookup.ts's comment, but exercising it — and any per-domain
-- divergence has something real to surface against. Distinct search terms
-- per row so a test can target one domain's claim without cross-matching
-- another's via claim_search's websearch_to_tsquery ranking.
INSERT INTO evidence.claim (id, kind, domain_table, text, population, search_tsv) VALUES
  ('a1000000-0000-0000-0000-000000000001', 'GENERAL_EDUCATION', 'domain.nutrition_pattern',
   'A low-glycaemic-index diet is commonly recommended alongside metformin for type 2 diabetes management.',
   'adults with type 2 diabetes',
   to_tsvector('english', 'low glycaemic index diet nutrition diabetes')),
  ('a1000000-0000-0000-0000-000000000002', 'GENERAL_EDUCATION', 'domain.exercise_guidance',
   '150 minutes per week of moderate aerobic activity is a commonly cited target for adults managing type 2 diabetes.',
   'adults with type 2 diabetes',
   to_tsvector('english', 'exercise aerobic activity minutes diabetes')),
  ('a1000000-0000-0000-0000-000000000003', 'GENERAL_EDUCATION', 'domain.lifestyle_screening_tool',
   'A pre-travel checklist commonly includes a dental and vision check before elective surgery abroad.',
   'medical tourism patients',
   to_tsvector('english', 'pre-travel checklist lifestyle screening elective surgery')),
  ('a1000000-0000-0000-0000-000000000004', 'GENERAL_EDUCATION', 'domain.clinical_metric_reference',
   'Home glucose monitors are commonly calibrated against a lab reference reading during setup.',
   'adults with type 2 diabetes',
   to_tsvector('english', 'glucose monitor calibration reference reading setup')),
  -- TEST_INTERPRETATION, deliberately seeded under MONITORING's domain table
  -- (not the same claim as 004 above — different search terms) so a test
  -- can retrieve it specifically and exercise route.ts's §2.0.2
  -- post-retrieval reconciliation (retrievalImpliesClinical). See
  -- test/runPipeline.integration.test.ts.
  ('a1000000-0000-0000-0000-000000000005', 'TEST_INTERPRETATION', 'domain.clinical_metric_reference',
   'A single fasting glucose reading above the reference range on its own is not a diagnosis and needs clinical correlation.',
   'adults with type 2 diabetes',
   to_tsvector('english', 'fasting glucose reading result interpretation diagnosis correlation')),
  ('a1000000-0000-0000-0000-000000000006', 'COST', 'hospital_cost',
   'Published package pricing for elective orthopaedic procedures in Chennai commonly bundles a fixed post-op stay.',
   'medical tourism patients',
   to_tsvector('english', 'hospital cost package pricing orthopaedic Chennai')),
  ('a1000000-0000-0000-0000-000000000007', 'ACCREDITATION', 'hospital_profile',
   'JCI accreditation is commonly cited as a baseline credential when comparing hospitals for medical tourism.',
   'medical tourism patients',
   to_tsvector('english', 'JCI accreditation hospital credential comparison')),
  ('a1000000-0000-0000-0000-000000000008', 'LEGAL_REGULATORY', 'domain.regulation',
   'A medical visa commonly requires a formal invitation letter from the treating hospital.',
   'medical tourism patients',
   to_tsvector('english', 'medical visa invitation letter hospital regulation')),
  ('a1000000-0000-0000-0000-000000000009', 'GENERAL_EDUCATION', 'domain.environment_reference',
   'Air quality index guidance is commonly published for major destination cities during a recovery period.',
   'medical tourism patients',
   to_tsvector('english', 'air quality index environment recovery destination city'));

INSERT INTO evidence.claim_source (claim_id, source_id, confidence) VALUES
  ('a1000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000006', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000007', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000008', '22222222-2222-2222-2222-222222222222', 0.80),
  ('a1000000-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 0.80);

INSERT INTO evidence.claim_policy (tier, kind, category, disposition, confidence_cap, min_sources, charter_clause, adopted_version, adopted_by, effective_from) VALUES
  ('TIER_2', 'GENERAL_EDUCATION',   'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2 (SMOKE-TEST)', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day'),
  ('TIER_2', 'COST',                'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2 (SMOKE-TEST)', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day'),
  ('TIER_2', 'ACCREDITATION',       'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2 (SMOKE-TEST)', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day'),
  ('TIER_2', 'LEGAL_REGULATORY',    'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2 (SMOKE-TEST)', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day'),
  -- TEST_INTERPRETATION is a deny-only kind for CLINICAL_DECISION (§3.1/
  -- §3.1.7), but this row is scoped to DECISION_SUPPORT specifically so the
  -- claim above can surface there — the point of seeding it is to exercise
  -- the reconciliation that then upgrades the category, not to permit the
  -- kind broadly.
  ('TIER_2', 'TEST_INTERPRETATION', 'DECISION_SUPPORT', 'PERMITTED', NULL, 1, 'HP-ESC 2.2.2 (SMOKE-TEST)', 'SMOKE-TEST', '11111111-1111-1111-1111-111111111111', now() - interval '1 day');
