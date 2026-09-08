CREATE TABLE IF NOT EXISTS `player_vehicles` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `license` varchar(50) DEFAULT NULL,
    `citizenid` varchar(50) DEFAULT NULL,
    `vehicle` varchar(50) DEFAULT NULL,
    `hash` varchar(50) DEFAULT NULL,
    `mods` text CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
    `plate` varchar(15) NOT NULL,
    `fakeplate` varchar(50) DEFAULT NULL,
    `garage` varchar(50) DEFAULT 'pillboxgarage',
    `fuel` int(11) DEFAULT 100,
    `engine` float DEFAULT 1000,
    `body` float DEFAULT 1000,
    `state` int(11) DEFAULT 1,
    `depotprice` int(11) NOT NULL DEFAULT 0,
    `drivingdistance` int(50) DEFAULT NULL,
    `status` text DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `plate` (`plate`),
    KEY `citizenid` (`citizenid`),
    KEY `license` (`license`)
) ENGINE=InnoDB AUTO_INCREMENT=1;

-- Align citizenid collation with players.citizenid so the FK constraint is compatible
ALTER TABLE `player_vehicles`
MODIFY COLUMN `citizenid` varchar(50) DEFAULT NULL COLLATE utf8mb4_0900_ai_ci;

-- Add unique plate index only if it doesn't already exist
SET @idx_exists = (SELECT COUNT(*) FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles'
  AND INDEX_NAME = 'UK_playervehicles_plate');
SET @sql = IF(@idx_exists = 0,
  'ALTER TABLE `player_vehicles` ADD UNIQUE INDEX UK_playervehicles_plate (plate)',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Add FK to players only if it doesn't already exist
SET @fk_exists = (SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles'
  AND CONSTRAINT_NAME = 'FK_playervehicles_players');
SET @sql = IF(@fk_exists = 0,
  'ALTER TABLE `player_vehicles` ADD CONSTRAINT FK_playervehicles_players FOREIGN KEY (citizenid) REFERENCES `players` (citizenid) ON DELETE CASCADE ON UPDATE CASCADE',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Add finance columns only if they don't already exist
SET @col_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles' AND COLUMN_NAME = 'balance');
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE `player_vehicles` ADD COLUMN `balance` int(11) NOT NULL DEFAULT 0',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @col_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles' AND COLUMN_NAME = 'paymentamount');
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE `player_vehicles` ADD COLUMN `paymentamount` int(11) NOT NULL DEFAULT 0',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @col_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles' AND COLUMN_NAME = 'paymentsleft');
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE `player_vehicles` ADD COLUMN `paymentsleft` int(11) NOT NULL DEFAULT 0',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @col_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles' AND COLUMN_NAME = 'financetime');
SET @sql = IF(@col_exists = 0,
  'ALTER TABLE `player_vehicles` ADD COLUMN `financetime` int(11) NOT NULL DEFAULT 0',
  'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
