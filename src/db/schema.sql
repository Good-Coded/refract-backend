-- Refract Protocol Database Schema
-- PostgreSQL 15+

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ─── Coverage Types ──────────────────────────────────────────────────────────

CREATE TYPE coverage_type AS ENUM (
  'stablecoin_depeg',
  'market_crash',
  'liquidation_shield',
  'smart_contract_risk',
  'flight_delay'
);

-- ─── Risk Pool Snapshots ─────────────────────────────────────────────────────

CREATE TABLE pool_snapshots (
  id              BIGSERIAL       PRIMARY KEY,
  total_usdc      NUMERIC(30, 0)  NOT NULL,
  total_shares    NUMERIC(30, 0)  NOT NULL,
  locked_usdc     NUMERIC(30, 0)  NOT NULL,
  premium_accrued NUMERIC(30, 0)  NOT NULL,
  share_price     NUMERIC(20, 7)  NOT NULL,
  utilization_bps SMALLINT        NOT NULL,
  apy_bps         SMALLINT        NOT NULL,
  snapshotted_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_pool_total_usdc_nonneg       CHECK (total_usdc >= 0),
  CONSTRAINT chk_pool_total_shares_nonneg     CHECK (total_shares >= 0),
  CONSTRAINT chk_pool_locked_usdc_nonneg      CHECK (locked_usdc >= 0),
  CONSTRAINT chk_pool_locked_lte_total        CHECK (locked_usdc <= total_usdc),
  CONSTRAINT chk_pool_premium_accrued_nonneg  CHECK (premium_accrued >= 0),
  CONSTRAINT chk_pool_share_price_positive    CHECK (share_price > 0),
  -- utilization_bps: 0–10000 bps (0–100%); prevents a bug storing 50000 (500%)
  CONSTRAINT chk_pool_utilization_bps_range   CHECK (utilization_bps BETWEEN 0 AND 10000),
  CONSTRAINT chk_pool_apy_bps_nonneg          CHECK (apy_bps >= 0)
);

-- Index for the "latest snapshot" query (ORDER BY snapshotted_at DESC LIMIT 1)
-- that pool stats runs on every request. fillfactor=90 reduces bloat from the
-- continuous insert rate of the snapshot writer (issue #22).
CREATE INDEX idx_pool_snapshots_snapshotted_at
  ON pool_snapshots(snapshotted_at DESC)
  WITH (fillfactor = 90);

-- ─── Policies ────────────────────────────────────────────────────────────────

CREATE TABLE policies (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id       VARCHAR(32)     UNIQUE,             -- on-chain policy ID
  holder          VARCHAR(56)     NOT NULL,            -- Stellar address
  coverage_type   coverage_type   NOT NULL,
  coverage_amount NUMERIC(30, 0)  NOT NULL,            -- 1e7 USDC
  premium         NUMERIC(30, 0)  NOT NULL,
  duration_days   SMALLINT        NOT NULL,
  expires_at      TIMESTAMPTZ     NOT NULL,
  trigger_params  JSONB           NOT NULL DEFAULT '{}',
  is_active       BOOLEAN         NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_policy_coverage_amount_positive  CHECK (coverage_amount > 0),
  CONSTRAINT chk_policy_premium_positive          CHECK (premium > 0),
  CONSTRAINT chk_policy_duration_days_range       CHECK (duration_days BETWEEN 1 AND 365),
  CONSTRAINT chk_policy_expires_after_created     CHECK (expires_at > created_at)
);

CREATE INDEX idx_policies_holder  ON policies(holder);
CREATE INDEX idx_policies_type    ON policies(coverage_type);
CREATE INDEX idx_policies_active  ON policies(is_active, expires_at);

-- ─── Claims ──────────────────────────────────────────────────────────────────

CREATE TABLE claims (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id       UUID            NOT NULL REFERENCES policies(id),
  holder          VARCHAR(56)     NOT NULL,
  coverage_type   coverage_type   NOT NULL,
  payout          NUMERIC(30, 0)  NOT NULL,
  trigger_value   NUMERIC(20, 6)  NOT NULL,    -- oracle value that triggered
  trigger_source  VARCHAR(40)     NOT NULL,
  tx_hash         VARCHAR(64),
  processed_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_claim_payout_positive        CHECK (payout > 0),
  CONSTRAINT chk_claim_trigger_value_nonneg   CHECK (trigger_value >= 0)
);

CREATE INDEX idx_claims_holder ON claims(holder);
CREATE INDEX idx_claims_policy ON claims(policy_id);

-- Covers ORDER BY processed_at DESC in getRecentSettlements() and
-- getHistoryForHolder() (issue #22).
CREATE INDEX idx_claims_processed_at ON claims(processed_at DESC);

-- Idempotency guard: prevents a crash-and-retry from inserting a second claim
-- row for an already-settled policy (issue #23). Partial: a zero-payout row
-- can never represent a real settlement and is excluded from uniqueness.
CREATE UNIQUE INDEX idx_claims_policy_id_settled
  ON claims(policy_id)
  WHERE payout > 0;

-- ─── Oracle Events ───────────────────────────────────────────────────────────

CREATE TABLE oracle_events (
  id              BIGSERIAL       PRIMARY KEY,
  coverage_type   coverage_type   NOT NULL,
  value           NUMERIC(20, 6)  NOT NULL,
  source          VARCHAR(40)     NOT NULL,
  severity        VARCHAR(10)     NOT NULL,  -- low | medium | high | triggered
  recorded_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_oracle_value_nonneg      CHECK (value >= 0),
  CONSTRAINT chk_oracle_severity_values   CHECK (severity IN ('low', 'medium', 'high', 'triggered'))
);

CREATE INDEX idx_oracle_type ON oracle_events(coverage_type, recorded_at DESC);

-- ─── LP Positions ────────────────────────────────────────────────────────────

CREATE TABLE lp_positions (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider        VARCHAR(56)     NOT NULL UNIQUE,
  shares          NUMERIC(30, 0)  NOT NULL DEFAULT 0,
  usdc_deposited  NUMERIC(30, 0)  NOT NULL DEFAULT 0,
  premium_earned  NUMERIC(30, 0)  NOT NULL DEFAULT 0,
  first_deposit   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  last_updated    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_lp_shares_nonneg          CHECK (shares >= 0),
  CONSTRAINT chk_lp_usdc_deposited_nonneg  CHECK (usdc_deposited >= 0),
  CONSTRAINT chk_lp_premium_earned_nonneg  CHECK (premium_earned >= 0)
);

-- ─── Premium Revenue ─────────────────────────────────────────────────────────

CREATE TABLE premium_revenue (
  id              BIGSERIAL       PRIMARY KEY,
  policy_id       UUID            NOT NULL REFERENCES policies(id),
  amount          NUMERIC(30, 0)  NOT NULL,
  coverage_type   coverage_type   NOT NULL,
  collected_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- Financial invariants (issue #21)
  CONSTRAINT chk_premium_revenue_amount_positive  CHECK (amount > 0)
);

-- FK lookups premium_revenue → policies (Postgres does not auto-index FKs)
-- and day-bucket aggregation by collected_at (issue #22).
CREATE INDEX idx_premium_revenue_policy_id  ON premium_revenue(policy_id);
CREATE INDEX idx_premium_revenue_collected_at ON premium_revenue(collected_at DESC);
