-- HealthPlus migration: 18. Migration 019 — the clinical-domain vocabulary, and the scope trigger
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 019 — clinical-domain vocabulary + §2.3.4b/c scope enforcement
-- ============================================================================

-- ---- seed prerequisites ----
-- 'ZZ' is a sentinel, not a residency decision. The seed principal below holds no
-- personal data and is not a data subject, so AMB-S-02 (Mumbai vs Frankfurt) does not
-- have to be answered before reference data can be loaded. Real users get a real region.
INSERT INTO public.region_registry (code, legal_basis, primary_regime, active_from) VALUES
  ('ZZ', 'Reference data only — no data subject', 'NONE', DATE '2026-01-01')
ON CONFLICT (code) DO NOTHING;

-- the attributing principal for reference data. §6.3 requires an adopter on every
-- change to a §3-governed value; seeded rows are adopted by the schema, and say so.
INSERT INTO principal.app_user (id, auth_subject, data_region, status) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'system:hp-schema-001', 'ZZ', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- ---- the vocabulary: 71 rows, parent_covers false on every one ----
INSERT INTO safety.clinical_domain
  (code, parent_code, name, elevated_risk, parent_covers, requires_prepublication_review,
   adoption_state, adopted_version, effective_from)
SELECT v.code, v.parent_code, v.name, v.elevated_risk, v.parent_covers,
       v.requires_prepublication_review, 'PROVISIONAL', 'HP-SCHEMA-001 v0.2', now()
FROM (VALUES
  ('ONCOLOGY', NULL, 'Oncology', true, false, true),
  ('MEDICAL_ONCOLOGY', 'ONCOLOGY', 'Medical oncology', true, false, true),
  ('SURGICAL_ONCOLOGY', 'ONCOLOGY', 'Surgical oncology', true, false, true),
  ('RADIATION_ONCOLOGY', 'ONCOLOGY', 'Radiation oncology', true, false, true),
  ('HAEMATO_ONCOLOGY', 'ONCOLOGY', 'Haemato-oncology', true, false, true),
  ('PAEDIATRIC_ONCOLOGY', 'ONCOLOGY', 'Paediatric oncology', true, false, true),
  ('CARDIAC', NULL, 'Cardiac', true, false, true),
  ('INTERVENTIONAL_CARDIOLOGY', 'CARDIAC', 'Interventional cardiology', true, false, true),
  ('ELECTROPHYSIOLOGY', 'CARDIAC', 'Cardiac electrophysiology', true, false, true),
  ('CARDIAC_SURGERY', 'CARDIAC', 'Cardiac surgery', true, false, true),
  ('HEART_FAILURE', 'CARDIAC', 'Heart failure', true, false, true),
  ('ADULT_CONGENITAL', 'CARDIAC', 'Adult congenital heart disease', true, false, true),
  ('NEURO', NULL, 'Neurological and neuro-interventional', true, false, true),
  ('NEUROSURGERY', 'NEURO', 'Neurosurgery', true, false, true),
  ('INTERVENTIONAL_NEURORADIOLOGY', 'NEURO', 'Interventional neuroradiology', true, false, true),
  ('STROKE', 'NEURO', 'Stroke medicine', true, false, true),
  ('EPILEPSY', 'NEURO', 'Epilepsy', true, false, true),
  ('TRANSPLANT', NULL, 'Transplantation', true, false, true),
  ('SOLID_ORGAN_TRANSPLANT', 'TRANSPLANT', 'Solid organ transplantation', true, false, true),
  ('HAEMATOPOIETIC_TRANSPLANT', 'TRANSPLANT', 'Haematopoietic stem cell transplantation', true, false, true),
  ('FERTILITY', NULL, 'Fertility and reproductive medicine', true, false, true),
  ('IVF', 'FERTILITY', 'In vitro fertilisation', true, false, true),
  ('SURROGACY', 'FERTILITY', 'Surrogacy', true, false, true),
  ('GAMETE_DONATION', 'FERTILITY', 'Gamete donation', true, false, true),
  ('PAEDIATRIC', NULL, 'Paediatrics', true, false, true),
  ('NEONATAL', 'PAEDIATRIC', 'Neonatology', true, false, true),
  ('PAEDIATRIC_SURGERY', 'PAEDIATRIC', 'Paediatric surgery', true, false, true),
  ('OBSTETRIC', NULL, 'Obstetrics and pregnancy', true, false, true),
  ('MATERNAL_FETAL_MEDICINE', 'OBSTETRIC', 'Maternal-fetal medicine', true, false, true),
  ('BARIATRIC', NULL, 'Bariatric surgery', true, false, true),
  ('REGENERATIVE', NULL, 'Stem-cell, gene and regenerative therapy', true, false, true),
  ('STEM_CELL', 'REGENERATIVE', 'Stem-cell therapy', true, false, true),
  ('GENE_THERAPY', 'REGENERATIVE', 'Gene therapy', true, false, true),
  ('COSMETIC', NULL, 'Cosmetic and aesthetic surgery', true, false, true),
  ('AESTHETIC_SURGERY_GA', 'COSMETIC', 'Aesthetic surgery under general anaesthesia', true, false, true),
  ('HAIR_RESTORATION', 'COSMETIC', 'Hair restoration', true, false, false),
  ('DERMATOLOGIC_AESTHETIC', 'COSMETIC', 'Dermatologic aesthetics', true, false, false),
  ('MENTAL_HEALTH', NULL, 'Mental health', true, false, true),
  ('PSYCHIATRY', 'MENTAL_HEALTH', 'Psychiatry', true, false, true),
  ('ADDICTION_MEDICINE', 'MENTAL_HEALTH', 'Addiction medicine', true, false, true),
  ('SELF_HARM_SAFEGUARDING', 'MENTAL_HEALTH', 'Self-harm and safeguarding', true, false, true),
  ('END_OF_LIFE', NULL, 'End-of-life and assisted dying', true, false, true),
  ('PALLIATIVE_CARE', 'END_OF_LIFE', 'Palliative care', true, false, true),
  ('GENDER_AFFIRMING', NULL, 'Gender-affirming care', true, false, true),
  ('UNAPPROVED_THERAPY', NULL, 'Unapproved, off-label or illegal therapy', true, false, true),
  ('NARROW_THERAPEUTIC_INDEX', NULL, 'Narrow-therapeutic-index drug contexts', true, false, true),
  ('ANTICOAGULATION', 'NARROW_THERAPEUTIC_INDEX', 'Anticoagulation', true, false, true),
  ('IMMUNOSUPPRESSION', 'NARROW_THERAPEUTIC_INDEX', 'Immunosuppression', true, false, true),
  ('CHEMOTHERAPY_DOSING', 'NARROW_THERAPEUTIC_INDEX', 'Chemotherapy dosing', true, false, true),
  ('GENERAL', NULL, 'General — not on the Elevated-Risk Topic List', false, false, false),
  ('ORTHOPAEDICS', 'GENERAL', 'Orthopaedics', false, false, false),
  ('SPINE', 'GENERAL', 'Spine surgery', false, false, false),
  ('OPHTHALMOLOGY', 'GENERAL', 'Ophthalmology', false, false, false),
  ('ENT', 'GENERAL', 'Otorhinolaryngology', false, false, false),
  ('DENTISTRY', 'GENERAL', 'Dentistry', false, false, false),
  ('GASTROENTEROLOGY', 'GENERAL', 'Gastroenterology', false, false, false),
  ('UROLOGY', 'GENERAL', 'Urology', false, false, false),
  ('NEPHROLOGY', 'GENERAL', 'Nephrology', false, false, false),
  ('ENDOCRINOLOGY', 'GENERAL', 'Endocrinology', false, false, false),
  ('DERMATOLOGY', 'GENERAL', 'Dermatology', false, false, false),
  ('PULMONOLOGY', 'GENERAL', 'Pulmonology', false, false, false),
  ('RHEUMATOLOGY', 'GENERAL', 'Rheumatology', false, false, false),
  ('INFECTIOUS_DISEASE', 'GENERAL', 'Infectious disease', false, false, false),
  ('VASCULAR_SURGERY', 'GENERAL', 'Vascular surgery', false, false, false),
  ('PLASTIC_RECONSTRUCTIVE', 'GENERAL', 'Plastic and reconstructive surgery', false, false, false),
  ('PAIN_MEDICINE', 'GENERAL', 'Pain medicine', false, false, false),
  ('REHABILITATION_MEDICINE', 'GENERAL', 'Rehabilitation medicine', false, false, false),
  ('PRIMARY_CARE', 'GENERAL', 'Primary care', false, false, false),
  ('RADIOLOGY', 'GENERAL', 'Radiology', false, false, false),
  ('PATHOLOGY', 'GENERAL', 'Pathology', false, false, false),
  ('ANAESTHESIA', 'GENERAL', 'Anaesthesia', false, false, false)
) AS v(code, parent_code, name, elevated_risk, parent_covers, requires_prepublication_review)
ORDER BY (v.parent_code IS NOT NULL), v.code;

-- §2.4: one domain, several elevated-risk items.
INSERT INTO safety.clinical_domain_risk_link (domain_code, charter_ref) VALUES
  ('ONCOLOGY', '§2.4.1 item 1'),
  ('PAEDIATRIC_ONCOLOGY', '§2.4.1 item 1'),
  ('PAEDIATRIC_ONCOLOGY', '§2.4.1 item 5'),
  ('CARDIAC', '§2.4.1 item 2'),
  ('NEURO', '§2.4.1 item 2'),
  ('TRANSPLANT', '§2.4.1 item 3'),
  ('TRANSPLANT', '§2.4.2'),
  ('SOLID_ORGAN_TRANSPLANT', '§2.4.2'),
  ('FERTILITY', '§2.4.1 item 4'),
  ('PAEDIATRIC', '§2.4.1 item 5'),
  ('PAEDIATRIC', '§2.4.3'),
  ('OBSTETRIC', '§2.4.1 item 6'),
  ('BARIATRIC', '§2.4.1 item 7'),
  ('REGENERATIVE', '§2.4.1 item 8'),
  ('COSMETIC', '§2.4.1 item 9'),
  ('MENTAL_HEALTH', '§2.4.1 item 10'),
  ('MENTAL_HEALTH', '§4.5.2'),
  ('ADDICTION_MEDICINE', '§2.4.1 item 10'),
  ('SELF_HARM_SAFEGUARDING', '§4.5.2'),
  ('SELF_HARM_SAFEGUARDING', 'AMB-18'),
  ('END_OF_LIFE', '§2.4.1 item 11'),
  ('GENDER_AFFIRMING', '§2.4.1 item 12'),
  ('UNAPPROVED_THERAPY', '§2.4.1 item 13'),
  ('NARROW_THERAPEUTIC_INDEX', '§2.4.1 item 14')
;

-- ---- §2.3.4b/c: the publish-time scope check, written and running ----
-- ADR-003 §3.1 specified this as prose and left it unimplemented because the vocabulary
-- did not exist. It exists now. Fail-closed: no matching scope means no approval.
CREATE OR REPLACE FUNCTION principal.reviewer_covers_domain(
  p_clinician uuid, p_domain text, p_jurisdiction char(2), p_as_at timestamptz
) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE cur text := p_domain; state text; hops int := 0; par text; covers boolean;
BEGIN
  LOOP
    SELECT d.adoption_state, d.parent_code, d.parent_covers
      INTO state, par, covers
      FROM safety.clinical_domain d WHERE d.code = cur;
    IF NOT FOUND THEN RETURN false; END IF;          -- unknown domain: refuse

    IF EXISTS (SELECT 1 FROM principal.clinician_scope s
                WHERE s.clinician_id = p_clinician
                  AND s.domain = cur
                  AND s.jurisdiction = p_jurisdiction) THEN
      RETURN true;
    END IF;

    -- §18.1: a PROVISIONAL boundary grants no inheritance. Exact scope or nothing.
    IF hops = 0 AND state = 'PROVISIONAL' THEN RETURN false; END IF;
    EXIT WHEN par IS NULL OR NOT covers;
    cur := par; hops := hops + 1;
    IF hops > 16 THEN
      RAISE EXCEPTION 'HP-SCHEMA 019: clinical_domain hierarchy cycle at %', p_domain;
    END IF;
  END LOOP;
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION principal.assert_reviewer_in_scope() RETURNS trigger AS $$
DECLARE reg_jur char(2);
BEGIN
  IF NEW.review_state IN ('APPROVED','APPROVED_WITH_EDITS') THEN
    IF NEW.reviewer_id IS NULL OR NEW.reviewer_reg_id IS NULL THEN
      RAISE EXCEPTION 'HP-ESC 2.3.4b: an approval requires a named, registered reviewer';
    END IF;
    -- §2.3.4b: registration valid AS AT the review, not as at now. A clinician whose
    -- registration lapses next year does not retroactively invalidate this review.
    SELECT r.jurisdiction INTO reg_jur
      FROM principal.clinician_registration r
     WHERE r.id = NEW.reviewer_reg_id
       AND r.clinician_id = NEW.reviewer_id
       AND r.verified_at IS NOT NULL
       AND r.revoked_at IS NULL
       AND (r.expires_at IS NULL OR r.expires_at >= NEW.occurred_at::date);
    IF reg_jur IS NULL THEN
      RAISE EXCEPTION
        'HP-ESC 2.3.4b: reviewer % has no verified, unrevoked registration valid at %',
        NEW.reviewer_id, NEW.occurred_at;
    END IF;
    IF NEW.clinical_domain IS NULL THEN
      RAISE EXCEPTION 'HP-ESC 2.3.4c: an approved response must name its clinical domain';
    END IF;
    IF NOT principal.reviewer_covers_domain(
             NEW.reviewer_id, NEW.clinical_domain, reg_jur, NEW.occurred_at) THEN
      RAISE EXCEPTION
        'HP-ESC 2.3.4c: reviewer % is out of scope for domain % in jurisdiction %',
        NEW.reviewer_id, NEW.clinical_domain, reg_jur;
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reviewer_in_scope
  BEFORE INSERT OR UPDATE ON obs.response_audit
  FOR EACH ROW EXECUTE FUNCTION principal.assert_reviewer_in_scope();

-- §2.2.5b: the queue is the v1 review path, and the same scope rule governs who may
-- claim an item. A clinician cannot pick up work they could not lawfully approve.
CREATE OR REPLACE FUNCTION obs.assert_queue_claim_in_scope() RETURNS trigger AS $$
DECLARE reg_jur char(2);
BEGIN
  IF NEW.claimed_by IS NOT NULL AND NEW.claimed_by IS DISTINCT FROM OLD.claimed_by THEN
    SELECT r.jurisdiction INTO reg_jur
      FROM principal.clinician_registration r
     WHERE r.clinician_id = NEW.claimed_by AND r.verified_at IS NOT NULL
       AND r.revoked_at IS NULL
     ORDER BY r.verified_at DESC LIMIT 1;
    IF reg_jur IS NULL OR NOT principal.reviewer_covers_domain(
         NEW.claimed_by, NEW.clinical_domain, reg_jur, now()) THEN
      RAISE EXCEPTION
        'HP-ESC 2.3.4c: clinician % may not claim a % review', NEW.claimed_by, NEW.clinical_domain;
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_queue_claim_in_scope
  BEFORE UPDATE ON obs.review_queue_item
  FOR EACH ROW EXECUTE FUNCTION obs.assert_queue_claim_in_scope();
