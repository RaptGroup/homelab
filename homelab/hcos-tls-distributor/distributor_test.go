package distributor

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDistributorHttpClient(t *testing.T) {
	endpoints := []Endpoint{
		Endpoint("https://hcos1.homelab.internal"),
		Endpoint("https://hcos2.homelab.internal"),
	}

	expectedUsername := "admin"
	expectedPassword := "password"

	mockServer := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			username, password, ok := r.BasicAuth()
			if !ok || username != expectedUsername || password != expectedPassword {
				w.WriteHeader(401)
				return
			}
			w.WriteHeader(200)
		}),
	)
	defer mockServer.Close()

	options := []Option{
		WithHypercoreCredentials(expectedUsername, expectedPassword),
		WithCertificates(
			"--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--",
			"--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--",
			"--BEGIN PRIVATE KEY--\n...\n--END PRIVATE---"),
	}

	distributor := New(endpoints, options...)
	response, err := distributor.httpClient.Get(mockServer.URL)
	if err != nil {
		t.Fatalf("Failed to make GET request: %v", err)
	}
	if response.StatusCode != 200 {
		t.Errorf("Expected status code 200, got %d", response.StatusCode)
	}
}

func TestPingEndpoint(t *testing.T) {
	mockServer := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(200)
		}),
	)
	defer mockServer.Close()

	endpoints := []Endpoint{
		Endpoint(mockServer.URL),
	}

	client := http.Client{Transport: &http.Transport{}}
	for _, endpoint := range endpoints {
		if err := endpoint.Ping(&client); err != nil {
			t.Errorf("Expected Ping to succeed for endpoint %s, but got error: %v", endpoint, err)
		}
	}
}

func TestPingAllEndpoints(t *testing.T) {
	options := []Option{
		WithCertificates(
			"--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--",
			"--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--",
			"--BEGIN PRIVATE KEY--\n...\n--END PRIVATE---"),
	}

	var count int

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/v1/ping", func(w http.ResponseWriter, r *http.Request) {
		count++
		w.WriteHeader(200)
	})

	mockServer := httptest.NewServer(mux)
	defer mockServer.Close()

	endpoints := make([]Endpoint, 5)
	for i := range endpoints {
		endpoints[i] = Endpoint(mockServer.URL)
	}

	d := New(endpoints, options...)
	if err := d.PingEndpoints(); err != nil {
		t.Fatal("Failed to ping endpoints")
	}

	expectedCount := 5
	if count != expectedCount {
		t.Fatalf("Expected count %d, got %d\n", expectedCount, count)
	}
}

func TestPostEndpoint(t *testing.T) {
	payload := DistributorPayload{
		Certificate: "--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--",
		PrivateKey:  "--BEGIN PRIVATE KEY--\n...\n--END PRIVATE---",
	}

	mockServer := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body := DistributorPayload{}
			err := json.NewDecoder(r.Body).Decode(&body)
			if err != nil {
				t.Fatal("Error unmarshalling json payload")
			}
			if body.Certificate != payload.Certificate {
				t.Fatalf("wanted %s, got %s", payload.Certificate, body.Certificate)
			}
			if body.Certificate != payload.Certificate {
				t.Fatalf("wanted %s, got %s", payload.Certificate, body.Certificate)
			}
			w.WriteHeader(200)
		}),
	)
	defer mockServer.Close()

	endpoints := []Endpoint{
		Endpoint(mockServer.URL),
	}

	client := http.Client{}

	for _, endpoint := range endpoints {
		if err := endpoint.PostCertificate(&client, payload); err != nil {
			t.Fatalf("Failed to post certificates: %s", err)
		}
	}
}

func TestPostAllCertificates(t *testing.T) {
	certificateData := "--BEGIN CERTIFICATE--\n...\n--END CERTIFICATE--"
	keyData := "--BEGIN PRIVATE KEY--\n...\n--END PRIVATE---"
	options := []Option{
		WithCertificates(
			certificateData,
			certificateData,
			keyData,
		),
	}

	var count int

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/v1/certificate", func(w http.ResponseWriter, r *http.Request) {
		body := DistributorPayload{}
		json.NewDecoder(r.Body).Decode(&body)

		if body.Certificate != certificateData {
			t.Fatalf("Certificate: wanted %s, got %s\n", certificateData, body.Certificate)
		}

		if body.PrivateKey != keyData {
			t.Fatalf("PrivateKey: wanted %s, got %s\n", keyData, body.PrivateKey)
		}
		count++
		w.WriteHeader(200)
	})

	mockServer := httptest.NewServer(mux)
	defer mockServer.Close()

	endpoints := make([]Endpoint, 5)
	for i := range endpoints {
		endpoints[i] = Endpoint(mockServer.URL)
	}

	d := New(endpoints, options...)

	if err := d.PostCertificates(); err != nil {
		t.Fatal("Failed to post certificates")
	}

	if count != len(endpoints) {
		t.Fatalf("wanted %d post calls, got %d\n", len(endpoints), count)
	}
}
