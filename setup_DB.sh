docker exec -it mysql-server mysql -u root -p

CREATE DATABASE IF NOT EXISTS network_monitor;
CREATE DATABASE IF NOT EXISTS network_monitor_local;

DROP USER IF EXISTS 'myuser'@'%';

CREATE USER 'myuser'@'%' IDENTIFIED BY 'mypassword';

GRANT ALL PRIVILEGES ON network_monitor.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON network_monitor_local.* TO 'myuser'@'%';

FLUSH PRIVILEGES;

SHOW GRANTS FOR 'myuser'@'%';


-- DB network_monitor
CREATE TABLE IF NOT EXISTS network_monitor.iperf_results (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  bitrate FLOAT,
  jitter FLOAT,
  lost_percentage FLOAT
);

CREATE TABLE IF NOT EXISTS network_monitor.ping_results (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  latency FLOAT
);

CREATE TABLE IF NOT EXISTS network_monitor.interruptions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  interruption_time FLOAT
);

-- DB network_monitor_local
CREATE TABLE IF NOT EXISTS network_monitor_local.iperf_results (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  bitrate FLOAT,
  jitter FLOAT,
  lost_percentage FLOAT
);

CREATE TABLE IF NOT EXISTS network_monitor_local.ping_results (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  latency FLOAT
);

CREATE TABLE IF NOT EXISTS network_monitor_local.interruptions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  timestamp DATETIME(3),
  interruption_time FLOAT
);



