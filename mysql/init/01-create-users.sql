-- Create application-specific database users
-- This script runs automatically when MySQL container is first created

-- WARNING: Change these passwords before deployment!

-- Create database for kairoxbuild site
CREATE DATABASE IF NOT EXISTS kairoxbuild_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create user for kairoxbuild site
CREATE USER IF NOT EXISTS 'kairoxbuild_user'@'%' IDENTIFIED BY 'CHANGE_THIS_PASSWORD_123';

-- Grant privileges (only to specific database, not all databases)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
      CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW,
      SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, TRIGGER
ON kairoxbuild_db.* TO 'kairoxbuild_user'@'%';

-- Flush privileges to apply changes
FLUSH PRIVILEGES;

-- Display created users
SELECT User, Host FROM mysql.user WHERE User LIKE 'kairoxbuild%';
