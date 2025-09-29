package distributor

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
)

const (
	DEFAULT_CERTIFICATES_PATH = "/app/certificates/"
	HYPERCORE_API_BASE_PATH   = "/rest/v1/"
)

type basicAuthTransport struct {
	Username  string
	Password  string
	Transport http.RoundTripper
}

func (t *basicAuthTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.SetBasicAuth(t.Username, t.Password)
	return t.Transport.RoundTrip(req)
}

// Option defines a function type that modifies a Distributor instance.
// We're using the "functional options" pattern to configure the Distributor.
type Option func(*Distributor)

type Endpoint string
type Distributor struct {
	HypercoreEndpoints []Endpoint
	HypercoreUsername  string
	HypercorePassword  string
	CACert             string
	TLSCert            string
	TLSKey             string
	httpClient         *http.Client
}

type DistributorPayload struct {
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"privateKey"`
}

type DistributorResult struct {
	Endpoint Endpoint
	Ok       bool
}

// WithHypercoreCredentials sets the Hypercore username and password for authentication.
func WithHypercoreCredentials(username, password string) Option {
	return func(d *Distributor) {
		d.HypercoreUsername = username
		d.HypercorePassword = password
	}
}

// WithCertificates sets the CA certificate, TLS certificate, and TLS key for secure communication.
func WithCertificates(caCert, tlsCert, tlsKey string) Option {
	return func(d *Distributor) {
		d.CACert = caCert
		d.TLSCert = tlsCert
		d.TLSKey = tlsKey
	}
}

func WithCertificatePaths(capath, certpath, keypath string) Option {
	return func(d *Distributor) {
		d.CACert = certFromEnvPath("", capath)
		d.TLSCert = certFromEnvPath("", certpath)
		d.TLSKey = certFromEnvPath("", keypath)
	}
}

// New creates a new Distributor instance with the provided endpoints and options.
// It reads certificates from files if they are not provided via options.
func New(endpoints []Endpoint, options ...Option) *Distributor {

	distributor := &Distributor{
		HypercoreEndpoints: endpoints,
		HypercoreUsername:  "admin",
		HypercorePassword:  "admin",
	}

	for _, option := range options {
		option(distributor)
	}

	// Set distributor keys if not supplied via options
	if distributor.CACert == "" {
		distributor.CACert = certFromEnvPath("HYPERCORE_CA_DISTRIBUTOR_CA_PATH", "ca.crt")
	}

	if distributor.TLSCert == "" {
		distributor.TLSCert = certFromEnvPath("HYPERCORE_CA_DISTRIBUTOR_TLS_CERT_PATH", "tls.crt")
	}

	if distributor.TLSKey == "" {
		distributor.TLSKey = certFromEnvPath("HYPERCORE_CA_DISTRIBUTOR_TLS_KEY_PATH", "tls.key")
	}

	distributor.setupHttpClient()

	return distributor
}

// setupHttpClient initializes an HTTP client with TLS configuration using the provided CA certificate.
func (d *Distributor) setupHttpClient() {
	rootCAs, _ := x509.SystemCertPool()
	if rootCAs == nil {
		rootCAs = x509.NewCertPool()
	}

	if ok := rootCAs.AppendCertsFromPEM([]byte(d.CACert)); !ok {
		log.Println("No CA certs appended, using system certs only")
	}

	tlsConfig := &tls.Config{
		RootCAs: rootCAs,
	}

	baseTransport := &http.Transport{
		TLSClientConfig: tlsConfig,
	}

	transport := &basicAuthTransport{
		Username:  d.HypercoreUsername,
		Password:  d.HypercorePassword,
		Transport: baseTransport,
	}

	d.httpClient = &http.Client{
		Transport: transport,
	}
}

// PingEndpoints pings all endpoints to ensure connectivity
func (d *Distributor) PingEndpoints() error {
	pings := make(chan DistributorResult, len(d.HypercoreEndpoints))
	for _, endpoint := range d.HypercoreEndpoints {
		go func() {
			result := DistributorResult{
				Endpoint: endpoint,
			}
			if err := endpoint.Ping(d.httpClient); err != nil {
				result.Ok = false
				pings <- result
				return
			}
			result.Ok = true
			pings <- result
		}()
	}

	for range d.HypercoreEndpoints {
		if result := <-pings; result.Ok == false {
			return fmt.Errorf("Failed to ping %s\n", result.Endpoint)
		}
	}
	close(pings)

	return nil
}

// PostCertificates posts certificate payloads to all endpoints
func (d *Distributor) PostCertificates() error {
	payload := DistributorPayload{
		Certificate: d.TLSCert,
		PrivateKey:  d.TLSKey,
	}

	posts := make(chan DistributorResult, len(d.HypercoreEndpoints))
	for _, endpoint := range d.HypercoreEndpoints {
		go func() {
			result := DistributorResult{
				Endpoint: endpoint,
			}
			if err := endpoint.PostCertificate(d.httpClient, payload); err != nil {
				result.Ok = false
				posts <- result
				return
			}
			result.Ok = true
			posts <- result
		}()
	}

	for range d.HypercoreEndpoints {
		if result := <-posts; result.Ok == false {
			return fmt.Errorf("Failed to post certs to %s\n", result.Endpoint)
		}
	}
	close(posts)

	return nil
}

// Run checks the distributor
func (d *Distributor) Run() {
	if err := d.PingEndpoints(); err != nil {
		log.Fatalf("Fatal Error: %s\n", err)
	}

	if err := d.PostCertificates(); err != nil {
		log.Fatalf("Fatal error: %s\n", err)
	}
}

func (e Endpoint) PostCertificate(client *http.Client, payload DistributorPayload) error {
	certEndpoint := e + HYPERCORE_API_BASE_PATH + "certificate"
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("Failed to marshal payload: %v", err)
	}

	response, err := client.Post(string(certEndpoint), "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("Failed to post certificate to endpoint %s: %v", certEndpoint, err)
	}
	if response.StatusCode != 200 {
		return fmt.Errorf("Non-200 response from endpoint %s: %d", certEndpoint, response.StatusCode)
	}
	return nil
}

func (e Endpoint) Ping(client *http.Client) error {
	pingEndpoint := e + HYPERCORE_API_BASE_PATH + "ping"
	response, err := client.Get(string(pingEndpoint))
	if err != nil {
		log.Printf("Failed to reach endpoint %s: %v", pingEndpoint, err)
		return fmt.Errorf("Failed to reach endpoint %s: %v", pingEndpoint, err)
	}
	if response.StatusCode != 200 {
		log.Printf("Non-200 response from endpoint %s: %d", pingEndpoint, response.StatusCode)
		return fmt.Errorf("Non-200 response from endpoint %s: %d", pingEndpoint, response.StatusCode)
	}
	return nil
}

func certFromEnvPath(envvar string, filenameFallback string) string {
	path := os.Getenv(envvar)
	if path == "" {
		path = DEFAULT_CERTIFICATES_PATH + filenameFallback
	}
	file, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf("Failed to read 'filenameFallback' certificate file: %v", err)
	}
	return string(file)
}
