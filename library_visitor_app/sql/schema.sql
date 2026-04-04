CREATE TABLE visitors (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    class VARCHAR(20),
    purpose VARCHAR(255),
    visit_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_summary (
    id INT AUTO_INCREMENT PRIMARY KEY,
    date DATE,
    total_visitors INT
);
