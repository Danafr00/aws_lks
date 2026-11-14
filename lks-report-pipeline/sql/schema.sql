CREATE TABLE IF NOT EXISTS reports (
    id INT AUTO_INCREMENT PRIMARY KEY,
    report_id VARCHAR(100) NOT NULL,
    filename VARCHAR(200) NOT NULL,
    record_count INT NOT NULL,
    total_amount DECIMAL(14,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_report_id (report_id)
);
