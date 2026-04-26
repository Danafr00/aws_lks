package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

var db *sql.DB
var uploadDir string

type Note struct {
	ID        int       `json:"id"`
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
}

type FileInfo struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"url"`
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func connectDB() (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=require",
		env("DB_HOST", "localhost"),
		env("DB_PORT", "5432"),
		env("DB_NAME", "wallet_db"),
		env("DB_USER", "walletadmin"),
		env("DB_PASSWORD", ""),
	)
	return sql.Open("postgres", dsn)
}

func migrate() error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS notes (
			id         SERIAL    PRIMARY KEY,
			content    TEXT      NOT NULL,
			created_at TIMESTAMP NOT NULL DEFAULT NOW()
		)
	`)
	return err
}

func waitForDB() error {
	for i := 1; i <= 10; i++ {
		if err := db.Ping(); err == nil {
			return nil
		}
		log.Printf("DB not ready (%d/10), retrying in 3s…", i)
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("database unreachable after 10 attempts")
}

// ── Handlers ─────────────────────────────────────────────────────────────────

func handleLive(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintln(w, `{"status":"ok"}`)
}

func handleReady(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := db.Ping(); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintln(w, `{"status":"db unavailable"}`)
		return
	}
	fmt.Fprintln(w, `{"status":"ok"}`)
}

func handleNotes(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case http.MethodGet:
		rows, err := db.Query(
			`SELECT id, content, created_at FROM notes ORDER BY created_at DESC LIMIT 50`,
		)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintln(w, `{"error":"query failed"}`)
			return
		}
		defer rows.Close()

		notes := []Note{}
		for rows.Next() {
			var n Note
			if err := rows.Scan(&n.ID, &n.Content, &n.CreatedAt); err == nil {
				notes = append(notes, n)
			}
		}
		json.NewEncoder(w).Encode(notes)

	case http.MethodPost:
		var body struct {
			Content string `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
			strings.TrimSpace(body.Content) == "" {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintln(w, `{"error":"content is required"}`)
			return
		}

		var n Note
		err := db.QueryRow(
			`INSERT INTO notes (content) VALUES ($1) RETURNING id, content, created_at`,
			body.Content,
		).Scan(&n.ID, &n.Content, &n.CreatedAt)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintln(w, `{"error":"insert failed"}`)
			return
		}

		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(n)

	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	if err := r.ParseMultipartForm(10 << 20); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintln(w, `{"error":"file too large (max 10MB)"}`)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintln(w, `{"error":"file field is required"}`)
		return
	}
	defer file.Close()

	name := filepath.Base(header.Filename)
	dst, err := os.Create(filepath.Join(uploadDir, name))
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, `{"error":"could not save file"}`)
		return
	}
	defer dst.Close()
	io.Copy(dst, file)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, `{"name":%q,"size":%d}`+"\n", name, header.Size)
}

func handleFiles(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	entries, err := os.ReadDir(uploadDir)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, `{"error":"could not read uploads dir"}`)
		return
	}

	files := []FileInfo{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, _ := e.Info()
		files = append(files, FileInfo{
			Name: e.Name(),
			Size: info.Size(),
			URL:  "/uploads/" + e.Name(),
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(files)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main() {
	migrateOnly := len(os.Args) > 1 && os.Args[1] == "--migrate-only"
	uploadDir = env("UPLOAD_PATH", "/app/uploads")

	if err := os.MkdirAll(uploadDir, 0755); err != nil {
		log.Fatalf("Cannot create upload dir: %v", err)
	}

	var err error
	db, err = connectDB()
	if err != nil {
		log.Fatalf("DB open: %v", err)
	}
	defer db.Close()

	if err = waitForDB(); err != nil {
		log.Fatalf("DB wait: %v", err)
	}

	if err = migrate(); err != nil {
		log.Fatalf("Migration: %v", err)
	}
	log.Println("Migration complete")

	if migrateOnly {
		return
	}

	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.Dir("static")))
	mux.Handle("/uploads/", http.StripPrefix("/uploads/", http.FileServer(http.Dir(uploadDir))))
	mux.HandleFunc("/health/live", handleLive)
	mux.HandleFunc("/health/ready", handleReady)
	mux.HandleFunc("/api/notes", handleNotes)
	mux.HandleFunc("/api/upload", handleUpload)
	mux.HandleFunc("/api/files", handleFiles)

	port := env("APP_PORT", "8080")
	log.Printf("Listening on :%s  uploadDir=%s", port, uploadDir)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
