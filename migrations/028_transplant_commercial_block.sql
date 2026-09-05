-- HealthPlus migration 028 — the §2.4.2 transplant commercial block
-- Source: HP-DR-002 (5 September 2026) §4, item T1.
-- Charter: §2.4.2, as restated by pending amendment C-31.
--
-- ============================================================================
-- WHAT THIS ENFORCES
-- ============================================================================
-- HP-DR-002: "The commercial engine never applies to transplantation." No
-- pricing, no ranking, no comparison, no routing — for EVERY donor pathway,
-- including deceased-donor and near-relative. The block attaches to our own
-- function, never to an assessment of anybody's individual arrangement, which
-- is what keeps it a hard block rather than the confidence-based decision
-- §2.4.2's own final sentence forbids.
--
-- Three layers enforce it. This is the structural one:
--
--   1. THIS FILE  — the database refuses to bind provider-commercial evidence
--                   to a transplant, whatever code attempts it.
--   2. surfaceGate() (chat-pipeline) — the render-time gate, forced on
--                   independently of red-flag severity.
--   3. The §4.5 red-flag rule (T3) — transplant intent in free text. CL2's to
--                   author; not seeded here.
--
-- Layer 1 is the one that holds against code nobody has written yet.
--
-- ============================================================================
-- HOW THE COMMERCIAL PATH ACTUALLY RUNS — found by executing, not by design
-- ============================================================================
-- The first draft of this migration guarded entity types 'treatment',
-- 'procedure' and 'surgery'. Running it proved that useless: migration 020's
-- attribute registry declares NO commercial contract on any of those three.
-- Their attributes are description, mechanism, efficacy, typical_recovery —
-- population-level reference content, which HP-DR-002 §1 expressly permits.
-- A COST claim bound to 'treatment' is already refused upstream by
-- trg_domain_attribute_kind_matches, so the guard could never fire.
--
-- Every commercial contract in the registry that can reach a treatment runs
-- through the PROVIDER side of the schema instead:
--
--   hospital_cost.{amount,inclusions,exclusions}  COST
--        -> hospital_treatment -> treatment
--   hospital_treatment_outcome.rate              PROVIDER_OUTCOME
--        -> hospital_treatment -> treatment
--   hospital_treatment.availability              LOGISTICS
--        -> treatment
--   medical_tourism_package.price                COST
--        -> primary_treatment_id
--   package_component.price                      COST
--        -> treatment_id
--
-- So the block has two halves, on two different principles.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- T1. The flag. A property of the PROCEDURE, never of the request.
-- ---------------------------------------------------------------------------
-- Deliberately NOT a new `treatment_kind` enum value. A transplant IS a
-- surgery; making the two mutually exclusive would mean a transplant recorded
-- as SURGERY silently escapes the block, which is precisely the failure this
-- exists to prevent. An orthogonal boolean cannot be escaped by picking a
-- different kind.
ALTER TABLE domain.treatment
  ADD COLUMN involves_donated_organ_or_tissue boolean NOT NULL DEFAULT false;

-- ...and drop the default immediately. Existing rows backfill to false
-- (correct — the repository seeds no transplant treatments), but every FUTURE
-- insert must state the answer. NOT NULL with no default turns "nobody thought
-- about it" from a quiet mis-classification into a failed insert.
ALTER TABLE domain.treatment
  ALTER COLUMN involves_donated_organ_or_tissue DROP DEFAULT;

COMMENT ON COLUMN domain.treatment.involves_donated_organ_or_tissue IS
  'HP-DR-002 / HP-ESC 2.4.2. True for any treatment in which an organ or '
  'tissue is procured from another person — solid organ, cornea, and '
  'haematopoietic stem cell. Autologous procedures are false. Set it '
  'deliberately: there is no default, and a true value permanently bars this '
  'treatment from every provider-commercial surface. Narrowing this scope is a '
  'Clinical Governance Board decision (HP-DR-002 §1), not an engineering one.';

-- ---------------------------------------------------------------------------
-- T1b. Resolve the treatment behind an entity, following the real paths.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION domain.treatment_for_entity(
  p_entity_type text,
  p_entity_id   uuid
) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT CASE p_entity_type
    -- Keyed directly on domain.treatment.id. `procedure` and `surgery` both
    -- declare `treatment_id uuid PRIMARY KEY REFERENCES domain.treatment(id)`
    -- and are registered as their own entity types in migration 020, so the
    -- same treatment is addressable three ways. No commercial contract targets
    -- them today; they are listed so that adding one later cannot open a door.
    WHEN 'treatment' THEN p_entity_id
    WHEN 'procedure' THEN p_entity_id
    WHEN 'surgery'   THEN p_entity_id

    WHEN 'hospital_treatment' THEN
      (SELECT ht.treatment_id FROM domain.hospital_treatment ht WHERE ht.id = p_entity_id)
    WHEN 'hospital_cost' THEN
      (SELECT ht.treatment_id
         FROM domain.hospital_cost hc
         JOIN domain.hospital_treatment ht ON ht.id = hc.hospital_treatment_id
        WHERE hc.id = p_entity_id)
    WHEN 'hospital_treatment_outcome' THEN
      (SELECT ht.treatment_id
         FROM domain.hospital_treatment_outcome o
         JOIN domain.hospital_treatment ht ON ht.id = o.hospital_treatment_id
        WHERE o.id = p_entity_id)
    WHEN 'medical_tourism_package' THEN
      (SELECT p.primary_treatment_id FROM domain.medical_tourism_package p WHERE p.id = p_entity_id)
    WHEN 'package_component' THEN
      (SELECT pc.treatment_id FROM domain.package_component pc WHERE pc.id = p_entity_id)

    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION domain.treatment_for_entity(text, uuid) IS
  'HP-DR-002. The treatment a bindable entity is about, or NULL. Covers the '
  'three treatment-keyed entity types and the five provider-side types that '
  'carry commercial attribute contracts in migration 020''s registry.';

-- ---------------------------------------------------------------------------
-- T1c. Which entity types exist only to describe a specific provider's offer.
-- ---------------------------------------------------------------------------
-- On these, EVERY attribute is provider routing, whatever its claim kind.
-- `hospital_treatment.availability` is declared LOGISTICS, not COST — but
-- "this hospital performs liver transplants, next slot in three weeks" is
-- routing a patient to a transplant centre in the most literal sense
-- HP-DR-002 §1 names. Filtering on claim kind alone would let it through.
CREATE OR REPLACE FUNCTION domain.is_provider_commercial_entity(p_entity_type text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_entity_type IN (
    'hospital_treatment',
    'hospital_cost',
    'hospital_treatment_outcome',
    'medical_tourism_package',
    'package_component'
  );
$$;

-- ---------------------------------------------------------------------------
-- The trigger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evidence.reject_commercial_transplant_binding()
RETURNS trigger
LANGUAGE plpgsql
-- SECURITY DEFINER, deliberately, and this is migration 027's grant bug (see
-- HP-RECON-001 §2c) applied forward: the check reads domain.treatment and
-- several provider tables. Running as the invoker would mean a role without
-- SELECT on any of them either raises a permission error or, after some future
-- refactor, silently stops enforcing for exactly the role doing the inserting.
-- A hard block that depends on the caller's grants is not a hard block.
-- search_path is pinned — an unpinned SECURITY DEFINER function is a
-- privilege-escalation vector.
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_kind      claim_kind;
  v_treatment uuid;
  v_is_tx     boolean;
BEGIN
  v_treatment := domain.treatment_for_entity(NEW.entity_type, NEW.entity_id);
  IF v_treatment IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT t.involves_donated_organ_or_tissue INTO v_is_tx
    FROM domain.treatment t WHERE t.id = v_treatment;
  IF NOT COALESCE(v_is_tx, false) THEN
    RETURN NEW;
  END IF;

  SELECT c.kind INTO v_kind FROM evidence.claim c WHERE c.id = NEW.claim_id;

  -- Half one: on a provider-specific entity, every claim kind is blocked.
  -- Half two: on a generic treatment entity, only the commercial kinds are —
  -- description, mechanism and efficacy are the population-level reference
  -- content HP-DR-002 §1 expressly permits, and blocking those would leave a
  -- transplant patient with nothing at all.
  IF domain.is_provider_commercial_entity(NEW.entity_type)
     OR v_kind IN ('COST', 'PROVIDER_OUTCOME')
  THEN
    RAISE EXCEPTION
      'HP-ESC 2.4.2 / HP-DR-002: refusing to bind a % claim to %:% — that entity '
      'resolves to transplant treatment %, and the commercial engine never applies '
      'to transplantation, for any donor pathway.',
      v_kind, NEW.entity_type, NEW.entity_id, v_treatment
      USING ERRCODE = 'raise_exception',
            HINT = 'Cited population-level reference content on treatment/procedure/'
                   'surgery is permitted. Pricing, provider outcomes and provider '
                   'availability are not. See HP-DR-002 §1.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reject_commercial_transplant_binding
  BEFORE INSERT OR UPDATE ON evidence.domain_attribute
  FOR EACH ROW
  EXECUTE FUNCTION evidence.reject_commercial_transplant_binding();

-- ---------------------------------------------------------------------------
-- Coverage boundary, stated rather than implied.
-- ---------------------------------------------------------------------------
-- NOT covered, and each for a reason rather than an oversight:
--
--   * `specialist.procedure_volume` (PROVIDER_OUTCOME). `domain.specialist`
--     links to a specialty, never to a treatment, so no query can tell whether
--     a surgeon's case volume is a transplant volume. A transplant surgeon's
--     published volume is also legitimate credential context. If a treatment
--     link is ever added to that table, add it to treatment_for_entity above.
--   * The free-text path — a COST claim whose statement describes a transplant
--     while bound to something unrelated, or to nothing. That belongs to the
--     §4.5 red-flag rule (T3) and the render gate, not to a keyword match in
--     the database, which would be exactly the confidence-based decision
--     §2.4.2 rules out.
--   * `domain.disease_treatment` carries its own surrogate id rather than a
--     treatment id, so bindings through it do not resolve. No commercial
--     contract targets it in migration 020's registry today.
