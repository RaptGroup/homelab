package caserver

import (
	"flag"
	"net/http"
	"os"
)

const CA_CERT_DEFAULT_PATH = "/etc/homelab/certificates/ca-cert.pem"

func Run() {
	caCertPathInput := flag.String("ca-cert-path", CA_CERT_DEFAULT_PATH, "Path to the PEM-encoded CA certificate")
	flag.Parse()
	caCertPath := *caCertPathInput

	http.HandleFunc("/ca", func(w http.ResponseWriter, r *http.Request) {
		f, err := os.Open(caCertPath)
		if err != nil {
			http.Error(w, "Error reading CA certificate from filesystem: "+err.Error(), http.StatusInternalServerError)
			return
		}
		defer f.Close()
		stat, err := f.Stat()

		http.ServeContent(w, r, "ca-cert.pem", stat.ModTime(), f)
	})
	http.ListenAndServe(":8080", nil)
}
