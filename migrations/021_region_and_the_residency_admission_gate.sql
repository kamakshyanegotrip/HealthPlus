-- HealthPlus migration: 20. Migration 021 — region, and the residency admission gate
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 021 — region seed (HP-ADR-004) and the residency admission gate
-- ============================================================================

-- One region. HP-ADR-003 §2.1, reaffirmed by HP-ADR-004 §2. Immutable at project
-- creation, so this row is the single most expensive line in the schema to get wrong.
INSERT INTO public.region_registry (code, legal_basis, primary_regime, active_from) VALUES
  ('IN', 'DPDP Act 2023 (Rules notified Nov 2025); HP-ADR-003 §2.1, HP-ADR-004 §2',
   'DPDP', DATE '2026-08-29')
ON CONFLICT (code) DO NOTHING;

-- 'DE' is deliberately NOT seeded. Adding it is a second-region project under the
-- Migration Pack §2.2 procedure, not a row.

CREATE TABLE public.residency_admission (
  residency_country char(2) PRIMARY KEY,
  data_region       char(2) NOT NULL REFERENCES public.region_registry(code),
  admission_state   text NOT NULL
    CHECK (admission_state IN ('ADMITTED','PENDING_REVIEW','BLOCKED')),
  transfer_mechanism text,          -- 'NOT_REQUIRED' | 'SCC_PLUS_TIA' | 'IDTA_PLUS_TRA'
  blocked_reason    text,
  charter_clause    text NOT NULL,
  reviewed_by       uuid REFERENCES principal.app_user(id),
  reviewed_at       timestamptz,
  adopted_version   text NOT NULL,
  -- §5.2 is a legal determination. An ADMITTED row must name how the transfer is
  -- lawful; 'NOT_REQUIRED' is the honest value when there is no transfer at all.
  CONSTRAINT c_admitted_names_mechanism CHECK (
    admission_state <> 'ADMITTED' OR transfer_mechanism IS NOT NULL),
  CONSTRAINT c_blocked_states_reason CHECK (
    admission_state <> 'BLOCKED' OR blocked_reason IS NOT NULL)
);

ALTER TABLE principal.patient_profile
  ADD COLUMN residency_country char(2) REFERENCES public.residency_admission(residency_country);

-- Default-deny. A residency with no ADMITTED row cannot become a data subject, and the
-- absence of a row is a refusal, not a permission — §3.0.3's philosophy applied to people.
CREATE OR REPLACE FUNCTION principal.assert_residency_admitted() RETURNS trigger AS $$
DECLARE st text; reg char(2);
BEGIN
  IF NEW.residency_country IS NULL THEN
    RAISE EXCEPTION
      'HP-ADR-004 §3: a patient profile must state a residency country before it exists';
  END IF;
  SELECT a.admission_state, a.data_region INTO st, reg
    FROM public.residency_admission a WHERE a.residency_country = NEW.residency_country;
  IF st IS DISTINCT FROM 'ADMITTED' THEN
    RAISE EXCEPTION
      'HP-ADR-004 §3: residency % is % — onboarding refused until counsel admits it',
      NEW.residency_country, COALESCE(st, 'UNREVIEWED');
  END IF;
  IF reg IS DISTINCT FROM NEW.data_region THEN
    RAISE EXCEPTION
      'HP-ADR-004 §3: residency % routes to region %, not % (Migration Pack §2.2 step 3)',
      NEW.residency_country, reg, NEW.data_region;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_residency_admitted
  BEFORE INSERT OR UPDATE ON principal.patient_profile
  FOR EACH ROW EXECUTE FUNCTION principal.assert_residency_admitted();

-- ---- the seed: 1 admitted, 32 blocked, 20 pending ----
INSERT INTO public.residency_admission
  (residency_country, data_region, admission_state, transfer_mechanism, blocked_reason,
   charter_clause, adopted_version)
SELECT v.residency_country, v.data_region, v.admission_state, v.transfer_mechanism,
       v.blocked_reason, v.charter_clause, 'HP-SCHEMA-001 v0.3'
FROM (VALUES
  ('IN', 'IN', 'ADMITTED', 'NOT_REQUIRED', NULL, 'HP-ADR-004 §2.1'),
  ('AT', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('BE', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('BG', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('HR', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('CY', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('CZ', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('DK', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('EE', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('FI', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('FR', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('DE', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('GR', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('HU', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('IE', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('IT', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('LV', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('LT', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('LU', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('MT', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('NL', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('PL', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('PT', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('RO', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('SK', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('SI', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('ES', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('SE', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('IS', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('LI', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('NO', 'IN', 'BLOCKED', NULL, 'GDPR Art. 44-49: India has no adequacy decision. SCCs + transfer impact assessment required before admission.', 'HP-ADR-004 §3.2'),
  ('GB', 'IN', 'BLOCKED', NULL, 'UK GDPR Chapter V: India is not on the UK adequacy list. IDTA or Addendum + TRA required.', 'HP-ADR-004 §3.2'),
  ('CH', 'IN', 'BLOCKED', NULL, 'Swiss FADP: India is not on the Swiss adequacy list.', 'HP-ADR-004 §3.2'),
  ('AE', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('SA', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('OM', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('QA', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('KW', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('BH', 'IN', 'PENDING_REVIEW', NULL, 'GCC cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('NG', 'IN', 'PENDING_REVIEW', NULL, 'Africa cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('KE', 'IN', 'PENDING_REVIEW', NULL, 'Africa cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('GH', 'IN', 'PENDING_REVIEW', NULL, 'Africa cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('TZ', 'IN', 'PENDING_REVIEW', NULL, 'Africa cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('ET', 'IN', 'PENDING_REVIEW', NULL, 'Africa cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('BD', 'IN', 'PENDING_REVIEW', NULL, 'South Asia cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('NP', 'IN', 'PENDING_REVIEW', NULL, 'South Asia cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('LK', 'IN', 'PENDING_REVIEW', NULL, 'South Asia cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('MV', 'IN', 'PENDING_REVIEW', NULL, 'South Asia cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('AF', 'IN', 'PENDING_REVIEW', NULL, 'South Asia cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('IQ', 'IN', 'PENDING_REVIEW', NULL, 'MENA cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('US', 'IN', 'PENDING_REVIEW', NULL, 'North America cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('CA', 'IN', 'PENDING_REVIEW', NULL, 'North America cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3'),
  ('AU', 'IN', 'PENDING_REVIEW', NULL, 'Oceania cohort. No known general restriction on outbound transfer to India; needs counsel confirmation per market before admission.', 'HP-ADR-004 §3.3')
) AS v(residency_country, data_region, admission_state, transfer_mechanism,
       blocked_reason, charter_clause);

ALTER TABLE public.residency_admission ENABLE ROW LEVEL SECURITY;
