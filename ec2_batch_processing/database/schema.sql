CREATE TABLE student_scores (
 id SERIAL PRIMARY KEY,
 student_name TEXT,
 subject TEXT,
 score INT,
 status TEXT,
 processed_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);