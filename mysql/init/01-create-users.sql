-- Create application-specific database users
-- This script runs automatically when MySQL container is first created

-- WARNING: Change these passwords before deployment!
-- Replace 'mysite' with your actual site name and set a strong password

-- Create database for your site
CREATE DATABASE IF NOT EXISTS mysite_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create user for your site
CREATE USER IF NOT EXISTS 'mysite_user'@'%' IDENTIFIED BY 'CHANGE_THIS_PASSWORD';

-- Grant privileges (only to specific database, not all databases)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
      CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW,
      SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, TRIGGER
ON mysite_db.* TO 'mysite_user'@'%';

-- Flush privileges to apply changes
FLUSH PRIVILEGES;
