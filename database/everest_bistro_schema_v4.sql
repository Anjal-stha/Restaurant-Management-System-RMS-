-- =====================================================================
-- THE EVEREST BISTRO — Database Schema v4
-- Target: PostgreSQL 15+ / Supabase
--
-- CHANGES vs v3:
--   1. order_items.is_taxable_at_time — tax status snapshotted per line,
--      auto-populated from menu_items when the app omits it
--   2. orders.taxable_subtotal — subtotal split into taxable / exempt
--   3. Discount prorated across taxable and exempt lines by value
--   4. Service charge base is now a policy setting (applies to exempt
--      items or not), snapshotted per order
--   5. Zero-subtotal guard on the proration division
--
-- ASSUMPTION IN FORCE: menu prices are VAT-EXCLUSIVE. If the restaurant
-- advertises VAT-inclusive prices, recalc_order_money() must be rewritten
-- to extract tax from the price rather than add it, and
-- restaurant_settings.prices_include_tax must be read by that function
-- (it is currently a placeholder that nothing consults).
--
-- Bill computation (supersedes §10.1 of the Master Spec):
--     net_subtotal     = subtotal - discount_amount
--     taxable_discount = discount_amount * (taxable_subtotal / subtotal)
--     net_taxable      = taxable_subtotal - taxable_discount
--     service_base     = net_subtotal  OR  net_taxable   (per policy)
--     service_charge   = round(service_base * service_rate, 2)
--     tax_amount       = round((net_taxable + service_charge) * tax_rate, 2)
--     total_amount     = net_subtotal + service_charge + tax_amount
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";

-- ---------------------------------------------------------------------
-- 0. HELPERS & CONFIGURATION
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TABLE restaurant_settings (
    id                              BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
    business_timezone               TEXT NOT NULL DEFAULT 'Asia/Kathmandu',
    default_tax_rate                NUMERIC(5,4) NOT NULL DEFAULT 0.1300
                                        CHECK (default_tax_rate BETWEEN 0 AND 1),
    default_service_rate            NUMERIC(5,4) NOT NULL DEFAULT 0.1000
                                        CHECK (default_service_rate BETWEEN 0 AND 1),
    -- Policy: does the service charge apply to tax-exempt lines (bottled
    -- water, retail goods) or only to taxable ones? House decision.
    service_charge_on_exempt_items  BOOLEAN NOT NULL DEFAULT true,
    -- Placeholder — NOT yet consulted by recalc_order_money().
    prices_include_tax              BOOLEAN NOT NULL DEFAULT false,
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO restaurant_settings (id) VALUES (true);


-- ---------------------------------------------------------------------
-- 1. STAFF ACCOUNTS (FR-03)
-- ---------------------------------------------------------------------

CREATE TYPE staff_role AS ENUM ('ADMIN', 'KITCHEN');

CREATE TABLE staff_users (
    staff_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username        CITEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,
    role            staff_role NOT NULL,
    display_name    VARCHAR(100),
    is_active       BOOLEAN NOT NULL DEFAULT true,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT username_len CHECK (length(username) BETWEEN 3 AND 100)
);

CREATE TRIGGER trg_staff_users_updated
    BEFORE UPDATE ON staff_users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_staff_users_role ON staff_users(role) WHERE is_active;


-- ---------------------------------------------------------------------
-- 2. PHYSICAL TABLES (§5.1) — status is derived, see section 3
-- ---------------------------------------------------------------------

CREATE TYPE table_status AS ENUM ('EMPTY', 'OCCUPIED', 'CHECKOUT');

CREATE TABLE restaurant_tables (
    table_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_number    VARCHAR(50) UNIQUE NOT NULL,
    qr_code_hash    UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
    status          table_status NOT NULL DEFAULT 'EMPTY',
    seat_capacity   SMALLINT CHECK (seat_capacity > 0),
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_restaurant_tables_updated
    BEFORE UPDATE ON restaurant_tables
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION enforce_derived_table_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status AND pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION
            'restaurant_tables.status is derived from table_sessions; '
            'open, check out or close the session instead';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_derived_table_status
    BEFORE UPDATE OF status ON restaurant_tables
    FOR EACH ROW EXECUTE FUNCTION enforce_derived_table_status();


-- ---------------------------------------------------------------------
-- 3. TABLE SESSIONS (§5.2, §6.1, FR-10)
-- ---------------------------------------------------------------------

CREATE TYPE session_status AS ENUM ('ACTIVE', 'CHECKOUT', 'CLOSED', 'ABANDONED');

CREATE TABLE table_sessions (
    session_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_id        UUID NOT NULL REFERENCES restaurant_tables(table_id) ON DELETE RESTRICT,
    status          session_status NOT NULL DEFAULT 'ACTIVE',
    opened_by       UUID REFERENCES staff_users(staff_id) ON DELETE SET NULL,
    closed_by       UUID REFERENCES staff_users(staff_id) ON DELETE SET NULL,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at       TIMESTAMPTZ,
    device_count    SMALLINT NOT NULL DEFAULT 0,   -- FR-11

    CONSTRAINT closed_sessions_have_timestamp
        CHECK ( (status IN ('CLOSED','ABANDONED')) = (closed_at IS NOT NULL) ),
    CONSTRAINT closed_after_opened
        CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

CREATE UNIQUE INDEX uniq_live_session_per_table
    ON table_sessions(table_id)
    WHERE status IN ('ACTIVE', 'CHECKOUT');

CREATE INDEX idx_sessions_table_opened ON table_sessions(table_id, opened_at DESC);
CREATE INDEX idx_sessions_status       ON table_sessions(status) WHERE status <> 'CLOSED';

CREATE OR REPLACE FUNCTION enforce_session_transition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF NOT (
           (OLD.status = 'ACTIVE'   AND NEW.status IN ('CHECKOUT','ABANDONED'))
        OR (OLD.status = 'CHECKOUT' AND NEW.status IN ('CLOSED','ACTIVE','ABANDONED'))
    ) THEN
        RAISE EXCEPTION 'Illegal session transition: % -> %', OLD.status, NEW.status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_session_transition
    BEFORE UPDATE ON table_sessions
    FOR EACH ROW EXECUTE FUNCTION enforce_session_transition();

CREATE OR REPLACE FUNCTION sync_table_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    new_table_status table_status;
BEGIN
    new_table_status := CASE NEW.status
        WHEN 'ACTIVE'    THEN 'OCCUPIED'::table_status
        WHEN 'CHECKOUT'  THEN 'CHECKOUT'::table_status
        ELSE                  'EMPTY'::table_status
    END;

    UPDATE restaurant_tables
    SET status = new_table_status
    WHERE table_id = NEW.table_id
      AND status IS DISTINCT FROM new_table_status;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sync_table_status
    AFTER INSERT OR UPDATE OF status ON table_sessions
    FOR EACH ROW EXECUTE FUNCTION sync_table_status();


-- ---------------------------------------------------------------------
-- 4. MENU CATALOG (FR-01, FR-02)
-- ---------------------------------------------------------------------

CREATE TABLE categories (
    category_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_category_id  UUID REFERENCES categories(category_id) ON DELETE RESTRICT,
    name                VARCHAR(100) NOT NULL,
    sort_order          INTEGER NOT NULL DEFAULT 0,
    is_visible          BOOLEAN NOT NULL DEFAULT true,
    archived_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT no_self_parent CHECK (category_id <> parent_category_id)
);

CREATE UNIQUE INDEX uniq_category_name_per_parent
    ON categories(
        COALESCE(parent_category_id, '00000000-0000-0000-0000-000000000000'::uuid),
        lower(name)
    )
    WHERE archived_at IS NULL;

CREATE TRIGGER trg_categories_updated
    BEFORE UPDATE ON categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION enforce_category_depth()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_category_id IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM categories
           WHERE category_id = NEW.parent_category_id
             AND parent_category_id IS NOT NULL
       )
    THEN
        RAISE EXCEPTION 'Category hierarchy is limited to two levels';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_category_depth
    BEFORE INSERT OR UPDATE ON categories
    FOR EACH ROW EXECUTE FUNCTION enforce_category_depth();


CREATE TABLE menu_items (
    item_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id     UUID NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    image_url       TEXT,
    is_visible      BOOLEAN NOT NULL DEFAULT true,
    is_out_of_stock BOOLEAN NOT NULL DEFAULT false,   -- FR-04
    -- Current tax status. Historical orders read their own snapshot,
    -- never this column (see order_items.is_taxable_at_time).
    is_tax_exempt   BOOLEAN NOT NULL DEFAULT false,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    archived_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_menu_items_updated
    BEFORE UPDATE ON menu_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_menu_items_category_sorted
    ON menu_items(category_id, sort_order)
    WHERE archived_at IS NULL AND is_visible;


-- ---------------------------------------------------------------------
-- 5. ORDERS — money model with taxable / exempt split
-- ---------------------------------------------------------------------

CREATE TYPE order_status AS ENUM ('ACTIVE', 'COMPLETED', 'VOID');

CREATE TABLE orders (
    order_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          UUID NOT NULL REFERENCES table_sessions(session_id) ON DELETE RESTRICT,
    table_id            UUID NOT NULL REFERENCES restaurant_tables(table_id) ON DELETE RESTRICT,
    status              order_status NOT NULL DEFAULT 'ACTIVE',

    -- Gross value of all non-cancelled lines.
    subtotal            NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (subtotal >= 0),
    -- Portion of the above that was taxable at time of ordering.
    taxable_subtotal    NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (taxable_subtotal >= 0),

    discount_amount     NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (discount_amount >= 0),
    discount_reason     TEXT,

    -- Rate and policy snapshots — a change next quarter must not rewrite
    -- this quarter's books (FR-09 extended to fiscal parameters).
    service_rate        NUMERIC(5,4) NOT NULL DEFAULT 0.1000,
    service_on_exempt   BOOLEAN NOT NULL DEFAULT true,
    service_charge      NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (service_charge >= 0),
    tax_rate            NUMERIC(5,4) NOT NULL DEFAULT 0.1300,
    tax_amount          NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (tax_amount >= 0),
    total_amount        NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),

    void_reason         TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ,

    CONSTRAINT taxable_within_subtotal CHECK (taxable_subtotal <= subtotal),
    CONSTRAINT discount_not_exceeding_subtotal CHECK (discount_amount <= subtotal),
    CONSTRAINT discount_requires_reason
        CHECK (discount_amount = 0 OR discount_reason IS NOT NULL),
    CONSTRAINT completed_orders_have_timestamp
        CHECK ( (status = 'COMPLETED') = (completed_at IS NOT NULL) ),
    CONSTRAINT void_requires_reason
        CHECK (status <> 'VOID' OR void_reason IS NOT NULL)
);

CREATE UNIQUE INDEX uniq_order_per_session ON orders(session_id);
CREATE UNIQUE INDEX uniq_active_order_per_table
    ON orders(table_id) WHERE status = 'ACTIVE';
CREATE INDEX idx_orders_completed_at
    ON orders(completed_at DESC) WHERE status = 'COMPLETED';
CREATE INDEX idx_orders_table_status ON orders(table_id, status);


CREATE OR REPLACE FUNCTION recalc_order_money()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    net_subtotal     NUMERIC(12,4);
    taxable_discount NUMERIC(12,4);
    net_taxable      NUMERIC(12,4);
    service_base     NUMERIC(12,4);
BEGIN
    net_subtotal := NEW.subtotal - NEW.discount_amount;

    -- Spread the discount across taxable and exempt lines in proportion
    -- to their value. Guarded: subtotal is 0 for every order between
    -- "Open Table" and the first ticket.
    IF NEW.subtotal > 0 THEN
        taxable_discount := round(
            NEW.discount_amount * (NEW.taxable_subtotal / NEW.subtotal), 4
        );
    ELSE
        taxable_discount := 0;
    END IF;

    net_taxable := NEW.taxable_subtotal - taxable_discount;

    -- House policy: does service charge apply to exempt goods?
    IF NEW.service_on_exempt THEN
        service_base := net_subtotal;
    ELSE
        service_base := net_taxable;
    END IF;

    NEW.service_charge := round(service_base * NEW.service_rate, 2);

    -- The service charge is treated as a taxable supply in full, even the
    -- portion levied on exempt goods, on the basis that it is a supply of
    -- service rather than of the exempt item. CONFIRM WITH YOUR ACCOUNTANT.
    -- If they disagree, prorate it here by (net_taxable / net_subtotal).
    NEW.tax_amount := round((net_taxable + NEW.service_charge) * NEW.tax_rate, 2);

    NEW.total_amount := net_subtotal + NEW.service_charge + NEW.tax_amount;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_recalc_order_money
    BEFORE INSERT OR UPDATE OF
        subtotal, taxable_subtotal, discount_amount,
        service_rate, service_on_exempt, tax_rate
    ON orders
    FOR EACH ROW EXECUTE FUNCTION recalc_order_money();


CREATE OR REPLACE FUNCTION lock_finalised_orders()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'ACTIVE' THEN
        RAISE EXCEPTION
            'Order % is % and cannot be modified', OLD.order_id, OLD.status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_finalised_orders
    BEFORE UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION lock_finalised_orders();


-- ---------------------------------------------------------------------
-- 6. ORDER TICKETS — race-free sequential numbering
-- ---------------------------------------------------------------------

CREATE TABLE order_tickets (
    ticket_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id         UUID NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    ticket_number    INTEGER NOT NULL,
    idempotency_key  UUID NOT NULL,
    submitted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged_at  TIMESTAMPTZ,
    CONSTRAINT uniq_ticket_number_per_order UNIQUE (order_id, ticket_number)
);

CREATE UNIQUE INDEX uniq_idempotency_key ON order_tickets(idempotency_key);
CREATE INDEX idx_tickets_queue ON order_tickets(submitted_at) WHERE acknowledged_at IS NULL;

CREATE OR REPLACE FUNCTION assign_ticket_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    parent_status order_status;
BEGIN
    SELECT status INTO parent_status
    FROM orders
    WHERE order_id = NEW.order_id
    FOR UPDATE;              -- serialises concurrent submits (FR-11)

    IF parent_status IS NULL THEN
        RAISE EXCEPTION 'Order % does not exist', NEW.order_id;
    ELSIF parent_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Cannot add a ticket to a % order', parent_status;
    END IF;

    SELECT COALESCE(MAX(ticket_number), 0) + 1
    INTO NEW.ticket_number
    FROM order_tickets
    WHERE order_id = NEW.order_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_assign_ticket_number
    BEFORE INSERT ON order_tickets
    FOR EACH ROW EXECUTE FUNCTION assign_ticket_number();


-- ---------------------------------------------------------------------
-- 7. ORDER ITEMS (FR-09)
-- ---------------------------------------------------------------------

CREATE TYPE order_item_status AS ENUM ('PENDING', 'DELIVERED', 'CANCELLED');

CREATE TABLE order_items (
    order_item_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id            UUID NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    ticket_id           UUID NOT NULL REFERENCES order_tickets(ticket_id) ON DELETE CASCADE,
    menu_item_id        UUID REFERENCES menu_items(item_id) ON DELETE SET NULL,

    item_name_snapshot  VARCHAR(200) NOT NULL,
    quantity            INTEGER NOT NULL CHECK (quantity > 0),
    price_at_time       NUMERIC(10,2) NOT NULL CHECK (price_at_time >= 0),
    -- Tax status snapshot. Populated from menu_items by trigger when the
    -- application omits it; explicit values are respected.
    is_taxable_at_time  BOOLEAN NOT NULL,
    line_total          NUMERIC(10,2) GENERATED ALWAYS AS (price_at_time * quantity) STORED,

    item_status         order_item_status NOT NULL DEFAULT 'PENDING',
    delivered_at        TIMESTAMPTZ,
    cancelled_by        UUID REFERENCES staff_users(staff_id) ON DELETE SET NULL,
    cancel_reason       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT delivered_items_have_timestamp
        CHECK ( (item_status = 'DELIVERED') = (delivered_at IS NOT NULL) )
);

CREATE INDEX idx_order_items_order     ON order_items(order_id);
CREATE INDEX idx_order_items_ticket    ON order_items(ticket_id);
CREATE INDEX idx_order_items_menu_item ON order_items(menu_item_id);
CREATE INDEX idx_order_items_pending   ON order_items(order_id) WHERE item_status = 'PENDING';
CREATE INDEX idx_order_items_taxable   ON order_items(order_id) WHERE is_taxable_at_time;

-- NOT NULL columns are validated AFTER BEFORE-triggers run, so this
-- trigger can legitimately fill a column the INSERT omitted.
CREATE OR REPLACE FUNCTION snapshot_item_tax_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.is_taxable_at_time IS NULL THEN
        IF NEW.menu_item_id IS NULL THEN
            RAISE EXCEPTION
                'is_taxable_at_time must be supplied for ad-hoc line items';
        END IF;

        SELECT NOT is_tax_exempt
        INTO NEW.is_taxable_at_time
        FROM menu_items
        WHERE item_id = NEW.menu_item_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_snapshot_item_tax_status
    BEFORE INSERT ON order_items
    FOR EACH ROW EXECUTE FUNCTION snapshot_item_tax_status();


-- RETURN COALESCE(NEW, OLD): on a BEFORE DELETE, NEW is NULL, and
-- returning NULL would silently cancel the delete instead of allowing it.
CREATE OR REPLACE FUNCTION lock_items_on_finalised_orders()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    parent_status order_status;
BEGIN
    SELECT status INTO parent_status
    FROM orders
    WHERE order_id = COALESCE(NEW.order_id, OLD.order_id);

    IF parent_status IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION 'Cannot modify items on a % order',
            COALESCE(parent_status::text, 'missing');
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_lock_items_on_finalised_orders
    BEFORE INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION lock_items_on_finalised_orders();


-- Maintains both subtotal columns; the money trigger on orders derives
-- everything downstream of them.
CREATE OR REPLACE FUNCTION recalc_order_subtotals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    target_order UUID := COALESCE(NEW.order_id, OLD.order_id);
    gross        NUMERIC(10,2);
    taxable      NUMERIC(10,2);
BEGIN
    SELECT
        COALESCE(SUM(line_total), 0.00),
        COALESCE(SUM(line_total) FILTER (WHERE is_taxable_at_time), 0.00)
    INTO gross, taxable
    FROM order_items
    WHERE order_id = target_order
      AND item_status <> 'CANCELLED';

    UPDATE orders
    SET subtotal         = gross,
        taxable_subtotal = taxable
    WHERE order_id = target_order;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_recalc_order_subtotals
    AFTER INSERT OR UPDATE OR DELETE ON order_items
    FOR EACH ROW EXECUTE FUNCTION recalc_order_subtotals();


-- ---------------------------------------------------------------------
-- 8. PAYMENTS (FR-07, UC-03)
--
-- A fully comped meal produces a legitimate 0.00 payment row with
-- method OTHER. Every constraint below permits it; the POS UI must
-- therefore allow submitting a zero-value checkout.
-- ---------------------------------------------------------------------

CREATE TYPE payment_method AS ENUM ('CASH', 'CARD', 'DIGITAL', 'OTHER');

CREATE TABLE payments (
    payment_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE RESTRICT,
    method          payment_method NOT NULL DEFAULT 'CASH',
    total_due       NUMERIC(10,2) NOT NULL CHECK (total_due >= 0),
    amount_tendered NUMERIC(10,2) NOT NULL CHECK (amount_tendered >= 0),
    change_given    NUMERIC(10,2) GENERATED ALWAYS AS (amount_tendered - total_due) STORED,
    reference_no    TEXT,
    processed_by    UUID REFERENCES staff_users(staff_id) ON DELETE SET NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT sufficient_payment CHECK (amount_tendered >= total_due),
    CONSTRAINT exact_tender_for_non_cash
        CHECK (method = 'CASH' OR amount_tendered = total_due),
    CONSTRAINT reference_for_digital
        CHECK (method NOT IN ('CARD','DIGITAL') OR reference_no IS NOT NULL)
);

CREATE INDEX idx_payments_processed_at ON payments(processed_at DESC);

CREATE OR REPLACE FUNCTION assert_payment_matches_order()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    bill NUMERIC(10,2);
BEGIN
    SELECT total_amount INTO bill FROM orders WHERE order_id = NEW.order_id;

    IF bill IS DISTINCT FROM NEW.total_due THEN
        RAISE EXCEPTION
            'Payment total_due (%) does not match order total (%)', NEW.total_due, bill;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_assert_payment_matches_order
    BEFORE INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION assert_payment_matches_order();

CREATE OR REPLACE FUNCTION block_payment_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Payment records are immutable; issue a reversal instead';
END;
$$;

CREATE TRIGGER trg_block_payment_mutation
    BEFORE UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION block_payment_mutation();


-- ---------------------------------------------------------------------
-- 9. ANALYTICS (FR-08, §10.2)
-- ---------------------------------------------------------------------

CREATE VIEW daily_sales AS
SELECT
    (o.completed_at AT TIME ZONE s.business_timezone)::date AS business_date,
    COUNT(*)                                    AS orders_completed,
    SUM(o.subtotal)                             AS gross_item_sales,
    SUM(o.taxable_subtotal)                     AS taxable_sales,
    SUM(o.subtotal - o.taxable_subtotal)        AS exempt_sales,
    SUM(o.discount_amount)                      AS total_discounts,
    SUM(o.service_charge)                       AS total_service_charge,
    SUM(o.tax_amount)                           AS total_tax_collected,
    SUM(o.total_amount)                         AS gross_revenue,
    AVG(o.total_amount)                         AS average_ticket
FROM orders o
CROSS JOIN restaurant_settings s
WHERE o.status = 'COMPLETED'
GROUP BY 1;

CREATE VIEW daily_writeoffs AS
SELECT
    (o.created_at AT TIME ZONE s.business_timezone)::date AS business_date,
    COUNT(*)            AS voided_orders,
    SUM(o.total_amount) AS value_written_off
FROM orders o
CROSS JOIN restaurant_settings s
WHERE o.status = 'VOID'
GROUP BY 1;


-- ---------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY
--
-- Deny-all default. If the browser is ever given a Supabase anon key,
-- write explicit SELECT policies for menu_items and categories only —
-- never for restaurant_tables, which holds the QR bearer secrets.
-- ---------------------------------------------------------------------

ALTER TABLE restaurant_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_tables   ENABLE ROW LEVEL SECURITY;
ALTER TABLE table_sessions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories          ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders              ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_tickets       ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items         ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments            ENABLE ROW LEVEL SECURITY;

ALTER TABLE restaurant_tables   FORCE ROW LEVEL SECURITY;
ALTER TABLE payments            FORCE ROW LEVEL SECURITY;
ALTER TABLE staff_users         FORCE ROW LEVEL SECURITY;

REVOKE ALL ON restaurant_tables FROM anon, authenticated;
REVOKE ALL ON staff_users       FROM anon, authenticated;
REVOKE ALL ON payments          FROM anon, authenticated;
