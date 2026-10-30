-- Rocket Ramen: a zero-gravity noodle bar.
-- Idempotent: safe to run on first boot and on an already-seeded database.
-- Apply with: mariadb orders < schema.sql  (the database and grants are created first)

-- Drop the pre-Rocket-Ramen scaffold table (single row, item/delivery_days).
SET @legacy := (SELECT COUNT(*) FROM information_schema.columns
                WHERE table_schema = 'orders' AND table_name = 'orders'
                  AND column_name = 'delivery_days');
SET @stmt := IF(@legacy > 0, 'DROP TABLE orders', 'DO 0');
PREPARE legacy FROM @stmt;
EXECUTE legacy;
DEALLOCATE PREPARE legacy;

CREATE TABLE IF NOT EXISTS menu_items (
  id           INT PRIMARY KEY,
  name         VARCHAR(80)  NOT NULL,
  emoji        VARCHAR(8)   NOT NULL DEFAULT '🍜',
  description  VARCHAR(255) NOT NULL,
  price_cents  INT          NOT NULL,
  prep_seconds INT          NOT NULL,
  stock        INT          NOT NULL,
  restock_to   INT          NOT NULL,
  spice        TINYINT      NOT NULL DEFAULT 0,
  vegan        BOOLEAN      NOT NULL DEFAULT FALSE,
  tags         VARCHAR(120) NOT NULL DEFAULT '',
  active       BOOLEAN      NOT NULL DEFAULT TRUE,
  FULLTEXT KEY ft_menu (name, description, tags)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS orders (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  code         VARCHAR(12)  NOT NULL DEFAULT '',
  customer     VARCHAR(60)  NOT NULL DEFAULT 'Cadet',
  status       VARCHAR(12)  NOT NULL DEFAULT 'queued',
  total_cents  INT          NOT NULL,
  prep_seconds INT          NOT NULL,
  eta_minutes  INT          NOT NULL,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  served_at    DATETIME     NULL,
  KEY status_created (status, created_at),
  KEY created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS order_items (
  id               INT AUTO_INCREMENT PRIMARY KEY,
  order_id         INT          NOT NULL,
  menu_item_id     INT          NOT NULL,
  name             VARCHAR(80)  NOT NULL,
  qty              INT          NOT NULL,
  unit_price_cents INT          NOT NULL,
  KEY order_id (order_id),
  CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS order_events (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  order_id INT          NOT NULL,
  status   VARCHAR(12)  NOT NULL,
  note     VARCHAR(120) NOT NULL DEFAULT '',
  at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY order_id (order_id, id),
  CONSTRAINT fk_order_events_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO menu_items (id, name, emoji, description, price_cents, prep_seconds, stock, restock_to, spice, vegan, tags) VALUES
  (1, 'Apollo Tonkotsu',     '🍜', 'Twelve-hour pork bone broth, chashu, ajitama egg, bamboo shoots.',       1450, 240, 40, 40, 1, FALSE, 'broth pork classic signature'),
  (2, 'Nebula Miso',         '🌌', 'White miso, charred corn, silken tofu, black garlic oil.',               1290, 180, 36, 36, 2, TRUE,  'miso vegan tofu mild'),
  (3, 'Solar Flare Tan Tan', '🔥', 'Sesame-chilli broth, minced pork, scorpion pepper oil. Handle with care.', 1550, 300, 24, 24, 5, FALSE, 'spicy sesame chilli signature'),
  (4, 'Lunar Shoyu',         '🌙', 'Clear soy broth, chicken, naruto, nori, yuzu zest.',                     1350, 200, 30, 30, 2, FALSE, 'shoyu chicken citrus'),
  (5, 'Supernova Shio',      '💥', 'Salt-forward broth, prawn, scallop butter, shiso.',                      1390, 210, 20, 20, 3, FALSE, 'shio seafood butter'),
  (6, 'Ganymede Gyoza',      '🥟', 'Six pan-fried pork and cabbage dumplings, rayu dip.',                     850, 120, 60, 60, 1, FALSE, 'side dumplings fried'),
  (7, 'Kuiper Kombucha',     '🧋', 'Yuzu and oolong kombucha, lightly fizzy, served over ice.',                450,  30, 80, 80, 0, TRUE,  'drink vegan citrus cold'),
  (8, 'Zero-G Takoyaki',     '🐙', 'Octopus fritters, kewpie, bonito flakes that float.',                      990, 150, 24, 24, 2, FALSE, 'side octopus seafood');

-- Demo accounts and grants are created by the cloud-init bootstrap before this file runs.
