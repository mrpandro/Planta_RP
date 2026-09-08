CREATE TABLE IF NOT EXISTS `house_plants` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `building` varchar(50) DEFAULT NULL,
  `stage` int(11) DEFAULT 1,
  `sort` varchar(50) DEFAULT NULL,
  `gender` varchar(50) DEFAULT NULL,
  `food` int(11) DEFAULT 100,
  `health` int(11) DEFAULT 100,
  `progress` int(11) DEFAULT 0,
  `coords` text DEFAULT NULL,
  `plantid` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `building` (`building`),
  KEY `plantid` (`plantid`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- Update January 15, 2024
-- CAST needed so legacy string stage values can be compared safely on MySQL 8.0.13+ strict mode
UPDATE `house_plants` SET `stage` = 1 WHERE CAST(`stage` AS CHAR) = 'stage-a';
UPDATE `house_plants` SET `stage` = 2 WHERE CAST(`stage` AS CHAR) = 'stage-b';
UPDATE `house_plants` SET `stage` = 3 WHERE CAST(`stage` AS CHAR) = 'stage-c';
UPDATE `house_plants` SET `stage` = 4 WHERE CAST(`stage` AS CHAR) = 'stage-d';
UPDATE `house_plants` SET `stage` = 5 WHERE CAST(`stage` AS CHAR) = 'stage-e';
UPDATE `house_plants` SET `stage` = 6 WHERE CAST(`stage` AS CHAR) = 'stage-f';
UPDATE `house_plants` SET `stage` = 7 WHERE CAST(`stage` AS CHAR) = 'stage-g';
ALTER TABLE `house_plants` MODIFY COLUMN `stage` int(11) DEFAULT 1;
